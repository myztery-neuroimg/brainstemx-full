#!/usr/bin/env bash
#
# freesurfer_harvest.sh - harvest the FULL FreeSurfer output from one recon-all
#                         + fast FreeSurfer ML methods (SynthSeg+/SynthSR/sclimbic).
#
# Rationale: recon-all is paid for ONCE (hours). Once it has completed for the
# subject (aseg.mgz present), a long tail of additional outputs is essentially
# free or cheap to extract from the SAME recon:
#   - aseg subcortical seg  -> aseg.stats volumes + CSF/ventricle binary masks
#   - wmparc               -> wmparc.stats
#   - aparc (Desikan-Killiany) + aparc.a2009s (Destrieux) -> their .stats +
#     surface morphometry (thickness/area/curv)
#   - eTIV / brain volume   -> asegstats2table / mri_segstats
#   - segment_subregions thalamus / hippo-amygdala         (minutes..~1h each)
#   - mri_segment_hypothalamic_subunits                    (minutes)
# All of these run on the FINISHED recon (NO second recon-all).
#
# Fast ML methods (NO recon required — run directly on a clinical/2D T1):
#   - SynthSeg+  (mri_synthseg --robust)  : contrast/resolution-agnostic
#       whole-brain seg in ~1 min. Yields aseg-equivalent subcortical labels +
#       CSF/ventricle masks + per-structure volumes WITHOUT recon-all. Its
#       CSF/ventricle output is an ALTERNATE fast source for the FP-exclusion
#       CSF mask (so the posterior-fossa pseudolesion filter works even without
#       a recon).
#   - SynthSR    (mri_synthsr)            : synthesize a 1mm isotropic T1 from a
#       thick-slice / low-res clinical T1; usable as the recon-all input AND the
#       T1->MNI master. Optional pre-step (USE_SYNTHSR=false default).
#   - mri_sclimbic_seg                    : DL limbic subcortical seg; gated.
#
# Conventions: every tool is detected with `command -v`; absent => clear WARNING
# + non-fatal skip (never aborts the pipeline). All behaviour gated by config
# toggles. CSF/ventricle masks the FP-exclusion path can consume are written to
# a stable, discoverable location (RESULTS_DIR/freesurfer/harvest/csf_masks).
#
# This is a SOURCED module: it does NOT enable `set -e -u -o pipefail` at the
# top (that would leak into the parent shell). Every function tolerates the
# pipeline's `set -e -u -o pipefail` and returns 0 on tool-missing/disabled
# paths so a run never aborts on the harvest.
#

# Include guard
if [ -n "${_FREESURFER_HARVEST_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_FREESURFER_HARVEST_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ---------------------------------------------------------------------------
# aseg / SynthSeg CSF + ventricle label values (FreeSurferColorLUT.txt). Both
# aseg.mgz and SynthSeg output share the same label scheme, so one list serves
# both.  4/43 = lateral ventricles, 5/44 = inferior-lateral ventricles,
# 14 = 3rd ventricle, 15 = 4th ventricle (the posterior-fossa one that matters
# most for brainstem pseudolesions), 24 = CSF, 72 = 5th ventricle.
# ---------------------------------------------------------------------------
export FS_VENTRICLE_LABELS="${FS_VENTRICLE_LABELS:-4 5 14 15 43 44 72}"
export FS_CSF_LABEL="${FS_CSF_LABEL:-24}"
export FS_FOURTH_VENTRICLE_LABEL="${FS_FOURTH_VENTRICLE_LABEL:-15}"

# ---------------------------------------------------------------------------
# Small wrapper around safe_fslmaths with a bare-fslmaths fallback (mirrors the
# wmh_synthseg.sh helper) so the module also works in standalone debugging.
# ---------------------------------------------------------------------------
_fsh_fslmaths() {
    local description="$1"
    shift
    if declare -F safe_fslmaths >/dev/null 2>&1; then
        safe_fslmaths "$description" "$@"
    else
        log_message "$description (safe_fslmaths unavailable, using fslmaths): fslmaths $*"
        fslmaths "$@"
    fi
}

# Resolve the harvest output root for a subject (stable + discoverable).
_fsh_harvest_dir() {
    local dir="${RESULTS_DIR:-../mri_results}/freesurfer/harvest"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# Voxel count of a binary mask (0 on any failure). Never aborts.
_fsh_voxels() {
    local mask="$1"
    local v
    v=$(fslstats "$mask" -V 2>/dev/null | awk '{print $1}')
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    echo "$v"
}

# ===========================================================================
# A. Harvest existing recon-all outputs (NO second recon)
# ===========================================================================

# ---------------------------------------------------------------------------
# fs_harvest_extract_csf_masks - split aseg.mgz CSF/ventricle labels into binary
# masks, resampled into the pipeline geometry. The 4th-ventricle / whole-CSF
# masks are the real accuracy win for the posterior-fossa pseudolesion problem
# (better than the FAST CSF PVE there). Written to a stable location the
# FP-exclusion path discovers (fs_harvest_find_csf_mask).
#
# Args: <seg_volume(.mgz|.nii.gz)> <geometry_reference(.nii.gz)> <out_dir> <tag>
#   <seg_volume>  aseg.mgz OR a SynthSeg label volume (same label scheme).
#   <tag>         provenance tag baked into filenames ("aseg" | "synthseg").
# Writes:
#   <out_dir>/<tag>_csf.nii.gz             (LUT 24 only)
#   <out_dir>/<tag>_fourth_ventricle.nii.gz (LUT 15)
#   <out_dir>/<tag>_ventricles.nii.gz       (all ventricle labels)
#   <out_dir>/<tag>_csf_all.nii.gz          (CSF + all ventricles; FP source)
# Returns 0 if csf_all produced any voxels, 1 otherwise. Never aborts.
# ---------------------------------------------------------------------------
fs_harvest_extract_csf_masks() {
    local seg_volume="$1"
    local geom_ref="$2"
    local out_dir="$3"
    local tag="${4:-aseg}"

    log_message "Harvesting ${tag} CSF/ventricle masks from: $seg_volume"

    if [ ! -f "$seg_volume" ]; then
        log_formatted "WARNING" "fs_harvest_extract_csf_masks: seg volume missing: $seg_volume"
        return 1
    fi
    if ! command -v mri_convert >/dev/null 2>&1; then
        log_formatted "WARNING" "fs_harvest_extract_csf_masks: mri_convert not found; cannot harvest CSF masks"
        return 1
    fi

    mkdir -p "$out_dir"

    local work_dir
    work_dir=$(mktemp -d)

    # Bring the label volume onto the pipeline geometry (nearest-neighbour keeps
    # the discrete labels). When a geometry reference is supplied, resample to it;
    # otherwise just convert to NIfTI on its own grid. `-odt int` is REQUIRED:
    # without it mri_convert defaults to a scaled float output that corrupts the
    # integer label values (observed range overflow), zeroing every extracted mask.
    local seg_nii="${work_dir}/seg_geom.nii.gz"
    if [ -n "$geom_ref" ] && [ -f "$geom_ref" ]; then
        if ! mri_convert -rl "$geom_ref" -rt nearest -odt int "$seg_volume" "$seg_nii" >/dev/null 2>&1; then
            log_formatted "WARNING" "fs_harvest_extract_csf_masks: resample to geometry reference failed; using native grid"
            mri_convert -odt int "$seg_volume" "$seg_nii" >/dev/null 2>&1 || { rm -rf "$work_dir"; return 1; }
        fi
    else
        mri_convert -odt int "$seg_volume" "$seg_nii" >/dev/null 2>&1 || { rm -rf "$work_dir"; return 1; }
    fi

    local csf_mask="${out_dir}/${tag}_csf.nii.gz"
    local fourth_mask="${out_dir}/${tag}_fourth_ventricle.nii.gz"
    local vent_mask="${out_dir}/${tag}_ventricles.nii.gz"
    local csf_all="${out_dir}/${tag}_csf_all.nii.gz"

    # Whole-CSF label (24).
    _fsh_fslmaths "${tag} CSF (LUT ${FS_CSF_LABEL})" \
        "$seg_nii" -thr "$FS_CSF_LABEL" -uthr "$FS_CSF_LABEL" -bin "$csf_mask" || true

    # 4th ventricle (15) — the posterior-fossa one most relevant to brainstem.
    _fsh_fslmaths "${tag} 4th ventricle (LUT ${FS_FOURTH_VENTRICLE_LABEL})" \
        "$seg_nii" -thr "$FS_FOURTH_VENTRICLE_LABEL" -uthr "$FS_FOURTH_VENTRICLE_LABEL" -bin "$fourth_mask" || true

    # All ventricles (union of FS_VENTRICLE_LABELS).
    _fsh_fslmaths "${tag} ventricles init" "$seg_nii" -mul 0 "$vent_mask" || true
    local lbl
    for lbl in $FS_VENTRICLE_LABELS; do
        local one="${work_dir}/.vent_${lbl}.nii.gz"
        if _fsh_fslmaths "${tag} ventricle label $lbl" \
                "$seg_nii" -thr "$lbl" -uthr "$lbl" -bin "$one"; then
            _fsh_fslmaths "${tag} ventricle accumulate $lbl" \
                "$vent_mask" -add "$one" -bin "$vent_mask" || true
        fi
        rm -f "$one" 2>/dev/null || true
    done

    # csf_all = CSF (24) + all ventricles — the FP-exclusion source mask.
    _fsh_fslmaths "${tag} CSF+ventricles union" \
        "$csf_mask" -add "$vent_mask" -bin "$csf_all" || true

    rm -rf "$work_dir"

    local csf_vox vent_vox fourth_vox all_vox
    csf_vox=$(_fsh_voxels "$csf_mask")
    vent_vox=$(_fsh_voxels "$vent_mask")
    fourth_vox=$(_fsh_voxels "$fourth_mask")
    all_vox=$(_fsh_voxels "$csf_all")
    log_message "  ${tag} CSF=${csf_vox}  4th-vent=${fourth_vox}  ventricles=${vent_vox}  csf_all=${all_vox} voxels"

    if [ "$all_vox" -gt 0 ]; then
        log_formatted "SUCCESS" "${tag} CSF/ventricle masks harvested: $out_dir"
        return 0
    fi
    log_formatted "WARNING" "${tag} CSF/ventricle harvest produced 0 voxels"
    return 1
}

# ---------------------------------------------------------------------------
# fs_harvest_find_csf_mask - locate the best FreeSurfer/SynthSeg CSF mask for
# the FP-exclusion path. Preference order (best posterior-fossa fidelity first):
#   1. aseg csf_all   (recon-derived; most accurate)
#   2. synthseg csf_all (fast ML; available without recon)
# Echoes the path (empty if none); always returns 0. The FP path falls back to
# the FAST CSF PVE when this returns empty.
# ---------------------------------------------------------------------------
fs_harvest_find_csf_mask() {
    local harvest_dir
    harvest_dir="$(_fsh_harvest_dir)/csf_masks"
    local candidate
    for candidate in \
        "${harvest_dir}/aseg_csf_all.nii.gz" \
        "${harvest_dir}/synthseg_csf_all.nii.gz" \
        "${harvest_dir}/aseg_csf.nii.gz" \
        "${harvest_dir}/synthseg_csf.nii.gz"; do
        if [ -f "$candidate" ]; then
            local vox
            vox=$(_fsh_voxels "$candidate")
            if [ "$vox" -gt 0 ]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# fs_harvest_stats - dump volumetric stats tables (aseg/wmparc/aparc) + eTIV via
# asegstats2table / aparcstats2table. Each table is independent and gated by its
# .stats file existing in the recon. Never aborts.
#
# Args: <subjects_dir> <subject_id> <out_dir>
# ---------------------------------------------------------------------------
fs_harvest_stats() {
    local subjects_dir="$1"
    local subject_id="$2"
    local out_dir="$3"

    log_message "Harvesting FreeSurfer stats tables (aseg/wmparc/aparc/eTIV)..."

    local stats_src="${subjects_dir}/${subject_id}/stats"
    if [ ! -d "$stats_src" ]; then
        log_formatted "WARNING" "fs_harvest_stats: stats dir missing (recon incomplete?): $stats_src"
        return 1
    fi
    mkdir -p "$out_dir"

    # Copy the raw .stats files verbatim (cheap, authoritative provenance).
    local f
    for f in aseg.stats wmparc.stats lh.aparc.stats rh.aparc.stats \
             lh.aparc.a2009s.stats rh.aparc.a2009s.stats brainvol.stats; do
        if [ -f "${stats_src}/${f}" ]; then
            cp "${stats_src}/${f}" "${out_dir}/${f}" 2>/dev/null || true
        fi
    done

    # asegstats2table: per-structure volumes (includes eTIV / brain-vol rows).
    if command -v asegstats2table >/dev/null 2>&1 && [ -f "${stats_src}/aseg.stats" ]; then
        SUBJECTS_DIR="$subjects_dir" asegstats2table --subjects "$subject_id" \
            --meas volume --tablefile "${out_dir}/aseg_volumes.tsv" >/dev/null 2>&1 \
            && log_message "  ✓ aseg_volumes.tsv" \
            || log_formatted "WARNING" "asegstats2table (aseg volumes) failed"
    fi
    if command -v asegstats2table >/dev/null 2>&1 && [ -f "${stats_src}/wmparc.stats" ]; then
        SUBJECTS_DIR="$subjects_dir" asegstats2table --subjects "$subject_id" \
            --stats wmparc.stats --meas volume --tablefile "${out_dir}/wmparc_volumes.tsv" >/dev/null 2>&1 \
            && log_message "  ✓ wmparc_volumes.tsv" \
            || log_formatted "WARNING" "asegstats2table (wmparc volumes) failed"
    fi

    # aparcstats2table: cortical morphometry (thickness + area) for both atlases.
    if command -v aparcstats2table >/dev/null 2>&1; then
        local parc meas
        for parc in aparc aparc.a2009s; do
            for meas in thickness area; do
                if [ -f "${stats_src}/lh.${parc}.stats" ]; then
                    SUBJECTS_DIR="$subjects_dir" aparcstats2table --subjects "$subject_id" \
                        --hemi lh --parc "$parc" --meas "$meas" \
                        --tablefile "${out_dir}/lh_${parc}_${meas}.tsv" >/dev/null 2>&1 \
                        && log_message "  ✓ lh_${parc}_${meas}.tsv" || true
                fi
                if [ -f "${stats_src}/rh.${parc}.stats" ]; then
                    SUBJECTS_DIR="$subjects_dir" aparcstats2table --subjects "$subject_id" \
                        --hemi rh --parc "$parc" --meas "$meas" \
                        --tablefile "${out_dir}/rh_${parc}_${meas}.tsv" >/dev/null 2>&1 \
                        && log_message "  ✓ rh_${parc}_${meas}.tsv" || true
                fi
            done
        done
    fi

    log_formatted "SUCCESS" "FreeSurfer stats harvested: $out_dir"
    return 0
}

# ---------------------------------------------------------------------------
# fs_harvest_subregions - run segment_subregions (thalamus, hippo-amygdala) and
# mri_segment_hypothalamic_subunits on the FINISHED recon (NO extra recon).
# Each is independently gated; each adds minutes..~1h, so each is opt-IN.
#
# Args: <subjects_dir> <subject_id> <geometry_reference> <out_dir>
# ---------------------------------------------------------------------------
fs_harvest_subregions() {
    local subjects_dir="$1"
    local subject_id="$2"
    local geom_ref="$3"
    local out_dir="$4"

    log_message "Harvesting FreeSurfer subregion segmentations (gated, on finished recon)..."

    local mri_dir="${subjects_dir}/${subject_id}/mri"
    if [ ! -d "$mri_dir" ]; then
        log_formatted "WARNING" "fs_harvest_subregions: recon mri dir missing: $mri_dir"
        return 1
    fi
    mkdir -p "$out_dir"

    local threads="${ANTS_THREADS:-4}"

    # --- Thalamic nuclei (segment_subregions thalamus) -----------------------
    if [ "${FS_HARVEST_THALAMUS:-false}" = "true" ] && command -v segment_subregions >/dev/null 2>&1; then
        log_message "  segment_subregions thalamus (this adds time)..."
        if SUBJECTS_DIR="$subjects_dir" segment_subregions thalamus \
                --cross "$subject_id" --sd "$subjects_dir" --threads "$threads" >/dev/null 2>&1; then
            _fsh_copy_subregion "$mri_dir" "ThalamicNuclei" "$geom_ref" "$out_dir" "thalamus"
        else
            log_formatted "WARNING" "segment_subregions thalamus failed (non-fatal)"
        fi
    else
        log_message "  thalamus: skipped (FS_HARVEST_THALAMUS=${FS_HARVEST_THALAMUS:-false})"
    fi

    # --- Hippocampus + amygdala subfields ------------------------------------
    if [ "${FS_HARVEST_HIPPO_AMYGDALA:-false}" = "true" ] && command -v segment_subregions >/dev/null 2>&1; then
        log_message "  segment_subregions hippo-amygdala (this adds time)..."
        if SUBJECTS_DIR="$subjects_dir" segment_subregions hippo-amygdala \
                --cross "$subject_id" --sd "$subjects_dir" --threads "$threads" >/dev/null 2>&1; then
            _fsh_copy_subregion "$mri_dir" "lh.hippoAmygLabels" "$geom_ref" "$out_dir" "hippo_amygdala_lh"
            _fsh_copy_subregion "$mri_dir" "rh.hippoAmygLabels" "$geom_ref" "$out_dir" "hippo_amygdala_rh"
        else
            log_formatted "WARNING" "segment_subregions hippo-amygdala failed (non-fatal)"
        fi
    else
        log_message "  hippo-amygdala: skipped (FS_HARVEST_HIPPO_AMYGDALA=${FS_HARVEST_HIPPO_AMYGDALA:-false})"
    fi

    # --- Hypothalamic subunits (mri_segment_hypothalamic_subunits) -----------
    if [ "${FS_HARVEST_HYPOTHALAMUS:-false}" = "true" ] && command -v mri_segment_hypothalamic_subunits >/dev/null 2>&1; then
        log_message "  mri_segment_hypothalamic_subunits (subject mode)..."
        if SUBJECTS_DIR="$subjects_dir" mri_segment_hypothalamic_subunits \
                --s "$subject_id" --sd "$subjects_dir" --threads "$threads" >/dev/null 2>&1; then
            _fsh_copy_subregion "$mri_dir" "hypothalamic_subunits_seg" "$geom_ref" "$out_dir" "hypothalamus"
        else
            log_formatted "WARNING" "mri_segment_hypothalamic_subunits failed (non-fatal)"
        fi
    else
        log_message "  hypothalamus: skipped (FS_HARVEST_HYPOTHALAMUS=${FS_HARVEST_HYPOTHALAMUS:-false})"
    fi

    return 0
}

# Copy the first matching subregion label volume from the recon mri dir into the
# harvest dir, resampled to the pipeline geometry. Helper for fs_harvest_subregions.
# Args: <mri_dir> <name_glob_stem> <geometry_reference> <out_dir> <out_tag>
_fsh_copy_subregion() {
    local mri_dir="$1"
    local stem="$2"
    local geom_ref="$3"
    local out_dir="$4"
    local tag="$5"

    # FreeSurfer suffixes vary by version (e.g. ThalamicNuclei.v13.T1.mgz,
    # ThalamicNuclei.mgz). `-print -quit` returns the first hit SIGPIPE-safely.
    local src
    src=$(find "$mri_dir" -maxdepth 1 -iname "${stem}*.mgz" -print -quit 2>/dev/null)
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        log_formatted "WARNING" "  ${tag}: no ${stem}*.mgz produced in $mri_dir"
        return 1
    fi

    # `-odt int` keeps the discrete label values intact across the resample (a
    # scaled-float output would corrupt them — see fs_harvest_extract_csf_masks).
    local out_nii="${out_dir}/${tag}_labels.nii.gz"
    if [ -n "$geom_ref" ] && [ -f "$geom_ref" ] && command -v mri_convert >/dev/null 2>&1; then
        mri_convert -rl "$geom_ref" -rt nearest -odt int "$src" "$out_nii" >/dev/null 2>&1 \
            || mri_convert -odt int "$src" "$out_nii" >/dev/null 2>&1 || return 1
    elif command -v mri_convert >/dev/null 2>&1; then
        mri_convert -odt int "$src" "$out_nii" >/dev/null 2>&1 || return 1
    else
        return 1
    fi
    log_message "  ✓ ${tag}: $out_nii"
    return 0
}

# ---------------------------------------------------------------------------
# fs_harvest_recon - top-level harvest of a COMPLETED recon-all (NO new recon).
# Caller invokes this only after run_recon_all has produced aseg.mgz. Each piece
# is individually gated/graceful.
#
# Args: <subjects_dir> <subject_id> <geometry_reference>
#   <geometry_reference> the pipeline-space image label volumes are resampled to.
# Always returns 0 (harvest is value-add, never fatal).
# ---------------------------------------------------------------------------
fs_harvest_recon() {
    local subjects_dir="$1"
    local subject_id="$2"
    local geom_ref="$3"

    log_formatted "INFO" "=== HARVESTING FULL FREESURFER RECON OUTPUTS (no second recon) ==="

    local mri_dir="${subjects_dir}/${subject_id}/mri"
    local aseg="${mri_dir}/aseg.mgz"
    if [ ! -f "$aseg" ]; then
        log_formatted "WARNING" "fs_harvest_recon: aseg.mgz not found (recon not complete?): $aseg; skipping harvest"
        return 0
    fi

    local harvest_dir
    harvest_dir="$(_fsh_harvest_dir)"
    local csf_dir="${harvest_dir}/csf_masks"
    local stats_dir="${harvest_dir}/stats"
    local subregions_dir="${harvest_dir}/subregions"

    # A1. aseg CSF/ventricle masks (cheap; default ON). The real FP-exclusion win.
    if [ "${FS_HARVEST_ASEG_CSF:-true}" = "true" ]; then
        fs_harvest_extract_csf_masks "$aseg" "$geom_ref" "$csf_dir" "aseg" || \
            log_formatted "WARNING" "aseg CSF/ventricle harvest unavailable (non-fatal)"
    else
        log_message "aseg CSF harvest skipped (FS_HARVEST_ASEG_CSF=${FS_HARVEST_ASEG_CSF:-true})"
    fi

    # A2. Stats tables (cheap; default ON).
    if [ "${FS_HARVEST_STATS:-true}" = "true" ]; then
        fs_harvest_stats "$subjects_dir" "$subject_id" "$stats_dir" || \
            log_formatted "WARNING" "FreeSurfer stats harvest unavailable (non-fatal)"
    else
        log_message "stats harvest skipped (FS_HARVEST_STATS=${FS_HARVEST_STATS:-true})"
    fi

    # A3. Subregion segmentations (each adds time; each default OFF).
    fs_harvest_subregions "$subjects_dir" "$subject_id" "$geom_ref" "$subregions_dir" || true

    # Provenance note for the whole harvest.
    {
        echo "FreeSurfer recon harvest"
        echo "========================"
        echo "Date: $(date)"
        echo "Subject: $subject_id"
        echo "Subjects dir: $subjects_dir"
        echo "aseg: $aseg"
        echo "Harvested: aseg_csf=${FS_HARVEST_ASEG_CSF:-true} stats=${FS_HARVEST_STATS:-true}"
        echo "           thalamus=${FS_HARVEST_THALAMUS:-false} hippo_amygdala=${FS_HARVEST_HIPPO_AMYGDALA:-false} hypothalamus=${FS_HARVEST_HYPOTHALAMUS:-false}"
    } > "${harvest_dir}/harvest_provenance.txt" 2>/dev/null || true

    log_formatted "SUCCESS" "FreeSurfer recon harvest complete: $harvest_dir"
    return 0
}

# ===========================================================================
# C. FreeSurfer ML methods (fast; no recon required)
# ===========================================================================

# ---------------------------------------------------------------------------
# run_synthseg - SynthSeg+ contrast/resolution-agnostic whole-brain seg in
# ~1 min, NO recon. Works on the 2D/thick-slice clinical T1. Yields aseg-
# equivalent subcortical labels + per-structure volumes + QC, and CSF/ventricle
# masks the FP-exclusion path can consume WITHOUT a recon (alternate fast source
# for task B).
#
# Args: <input_t1> [<geometry_reference>] [<out_dir>]
#   <geometry_reference> the pipeline-space image the CSF masks are resampled to
#       (defaults to the input image).
# Gated by SEG_RUN_SYNTHSEG (default true). Graceful skip if absent/disabled.
# Always returns 0.
# ---------------------------------------------------------------------------
run_synthseg() {
    local input_t1="${1:-}"
    local geom_ref="${2:-$input_t1}"
    local out_dir="${3:-}"

    log_message "=== run_synthseg (SynthSeg+ contrast-agnostic whole-brain seg, no recon) ==="

    if [ "${SEG_RUN_SYNTHSEG:-true}" != "true" ]; then
        log_formatted "INFO" "SynthSeg disabled (SEG_RUN_SYNTHSEG=${SEG_RUN_SYNTHSEG:-true}); skipping"
        return 0
    fi
    if [ -z "$input_t1" ] || [ ! -f "$input_t1" ]; then
        log_formatted "WARNING" "SynthSeg: input T1 missing ($input_t1); skipping"
        return 0
    fi
    if ! command -v mri_synthseg >/dev/null 2>&1; then
        log_formatted "WARNING" "mri_synthseg not found on PATH (install FreeSurfer >=7.x); skipping SynthSeg (non-fatal)"
        return 0
    fi

    [ -z "$out_dir" ] && out_dir="$(_fsh_harvest_dir)/synthseg"
    mkdir -p "$out_dir"

    local seg_out="${out_dir}/synthseg_seg.nii.gz"
    local vol_csv="${out_dir}/synthseg_vols.csv"
    local qc_csv="${out_dir}/synthseg_qc.csv"
    local threads="${ANTS_THREADS:-4}"

    # --robust => SynthSeg+ (slower but contrast/resolution robust; the right
    # choice for 2D/thick-slice clinical T1). --vol/--qc emit volumes + QC.
    # --parc adds cortical parcellation when SEG_SYNTHSEG_PARC=true.
    local -a cmd=( mri_synthseg --i "$input_t1" --o "$seg_out"
                   --vol "$vol_csv" --qc "$qc_csv" --threads "$threads" --cpu )
    if [ "${SEG_SYNTHSEG_ROBUST:-true}" = "true" ]; then
        cmd+=( --robust )
    fi
    if [ "${SEG_SYNTHSEG_PARC:-false}" = "true" ]; then
        cmd+=( --parc )
    fi

    log_message "SynthSeg input: $input_t1"
    log_message "SynthSeg command: ${cmd[*]}"

    local rc=0
    "${cmd[@]}" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$seg_out" ]; then
        log_formatted "WARNING" "mri_synthseg exited $rc / no output; skipping SynthSeg downstream (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "SynthSeg segmentation: $seg_out"

    # Harvest CSF/ventricle masks from the SynthSeg labels into the shared
    # FP-exclusion source location (tag=synthseg). Same label scheme as aseg.
    local csf_dir
    csf_dir="$(_fsh_harvest_dir)/csf_masks"
    fs_harvest_extract_csf_masks "$seg_out" "$geom_ref" "$csf_dir" "synthseg" || \
        log_formatted "WARNING" "SynthSeg CSF/ventricle harvest produced nothing (non-fatal)"

    log_formatted "SUCCESS" "SynthSeg complete (subcortical seg + volumes + CSF masks): $out_dir"
    return 0
}

# ---------------------------------------------------------------------------
# run_synthsr - synthesize a 1mm isotropic T1 from a low-res / 2D clinical T1.
# Optional pre-step (USE_SYNTHSR=false default). The synthesized 1mm T1 can be
# used as the recon-all input AND the T1->MNI master, improving both on thick-
# slice T1. Echoes the synthesized image path on success (for the caller to
# adopt as FREESURFER_T1_INPUT / the registration master).
#
# Args: <input_t1> [<out_dir>]
# Returns 0 + echoes path on success; returns 1 (echoes nothing) on
# skip/absent/failure so the caller keeps the original T1. Diagnostic logging
# goes to stderr so it never pollutes the echoed path.
# ---------------------------------------------------------------------------
run_synthsr() {
    local input_t1="${1:-}"
    local out_dir="${2:-}"

    log_message "=== run_synthsr (synthesize 1mm T1 from low-res/2D clinical T1) ===" >&2

    if [ "${USE_SYNTHSR:-false}" != "true" ]; then
        log_formatted "INFO" "SynthSR disabled (USE_SYNTHSR=${USE_SYNTHSR:-false}); using original T1" >&2
        return 1
    fi
    if [ -z "$input_t1" ] || [ ! -f "$input_t1" ]; then
        log_formatted "WARNING" "SynthSR: input T1 missing ($input_t1); skipping" >&2
        return 1
    fi
    if ! command -v mri_synthsr >/dev/null 2>&1; then
        log_formatted "WARNING" "mri_synthsr not found on PATH; skipping SynthSR (non-fatal)" >&2
        return 1
    fi

    [ -z "$out_dir" ] && out_dir="$(_fsh_harvest_dir)/synthsr"
    mkdir -p "$out_dir"

    local sr_out="${out_dir}/$(basename "$input_t1" .nii.gz)_synthsr_1mm.nii.gz"
    local threads="${ANTS_THREADS:-4}"

    log_message "SynthSR input: $input_t1 -> $sr_out" >&2
    local rc=0
    mri_synthsr --i "$input_t1" --o "$sr_out" --threads "$threads" --cpu >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$sr_out" ]; then
        log_formatted "WARNING" "mri_synthsr exited $rc / no output; using original T1 (non-fatal)" >&2
        return 1
    fi
    log_formatted "SUCCESS" "SynthSR 1mm T1: $sr_out" >&2
    echo "$sr_out"
    return 0
}

# ---------------------------------------------------------------------------
# run_sclimbic - DL limbic subcortical segmentation (mri_sclimbic_seg). Gated
# harvest (FS_HARVEST_SCLIMBIC, default false). Works on a T1 directly (no recon
# required). Always returns 0.
#
# Args: <input_t1> [<out_dir>]
# ---------------------------------------------------------------------------
run_sclimbic() {
    local input_t1="${1:-}"
    local out_dir="${2:-}"

    log_message "=== run_sclimbic (DL limbic subcortical seg) ==="

    if [ "${FS_HARVEST_SCLIMBIC:-false}" != "true" ]; then
        log_formatted "INFO" "sclimbic disabled (FS_HARVEST_SCLIMBIC=${FS_HARVEST_SCLIMBIC:-false}); skipping"
        return 0
    fi
    if [ -z "$input_t1" ] || [ ! -f "$input_t1" ]; then
        log_formatted "WARNING" "sclimbic: input T1 missing ($input_t1); skipping"
        return 0
    fi
    if ! command -v mri_sclimbic_seg >/dev/null 2>&1; then
        log_formatted "WARNING" "mri_sclimbic_seg not found on PATH; skipping sclimbic (non-fatal)"
        return 0
    fi

    [ -z "$out_dir" ] && out_dir="$(_fsh_harvest_dir)/sclimbic"
    mkdir -p "$out_dir"

    local seg_out="${out_dir}/sclimbic_seg.nii.gz"
    local threads="${ANTS_THREADS:-4}"

    local rc=0
    mri_sclimbic_seg --i "$input_t1" --o "$seg_out" --write_volumes --threads "$threads" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$seg_out" ]; then
        log_formatted "WARNING" "mri_sclimbic_seg exited $rc / no output; skipping sclimbic downstream (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "sclimbic segmentation: $seg_out"
    return 0
}

export -f _fsh_fslmaths
export -f _fsh_harvest_dir
export -f _fsh_voxels
export -f fs_harvest_extract_csf_masks
export -f fs_harvest_find_csf_mask
export -f fs_harvest_stats
export -f fs_harvest_subregions
export -f _fsh_copy_subregion
export -f fs_harvest_recon
export -f run_synthseg
export -f run_synthsr
export -f run_sclimbic

log_message "FreeSurfer harvest module loaded (recon harvest + SynthSeg+/SynthSR/sclimbic)"
