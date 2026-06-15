#!/usr/bin/env bash
#
# brainstem_aanseg.sh - EXPLORATORY brainstem arousal-network nuclei segmentation
#                       via FreeSurfer's AANSegment (SegmentAAN.sh).
#
# ############################################################################
# # EXPLORATORY / RESEARCH-ONLY MODULE - READ BEFORE ENABLING                #
# ############################################################################
#
# This module is a thin, self-contained wrapper that *calls* FreeSurfer's
# AANSegment tool (Olchanyi et al., "Automated MRI Segmentation of Brainstem
# Nuclei Critical to Consciousness," Human Brain Mapping 2025;46(14):e70357,
# DOI 10.1002/hbm.70357; https://surfer.nmr.mgh.harvard.edu/fswiki/AANSegment).
# AANSegment is a contrast- and resolution-agnostic Bayesian segmenter that
# labels ~10 brainstem ascending-arousal-network nuclei (DR, MnR, LC, LDTg,
# PTg, parabrachial, PnO, midbrain reticular formation, VTA, PAG).
#
# IT IS DEFAULT-OFF AND EXPLORATORY. Three hard caveats are honored here and
# must be honored by anyone consuming its outputs:
#
#   1. RESOLUTION <= 1 mm ONLY. The authors warn against input resolution
#      COARSER than 1 mm. On typical clinical FLAIR slice thickness (often
#      3-5 mm) the volumetrics are UNRELIABLE. This module checks the input
#      voxel size and logs a clear WARNING (and, by default, SKIPS) when any
#      dimension exceeds AANSEG_MAX_VOXEL_MM (default 1.0 mm).
#
#   2. LICENSE: CC BY-NC-ND 4.0 (NON-COMMERCIAL, NO DERIVATIVES). We only
#      *invoke* the FreeSurfer-shipped tool. We never modify, vendor, or
#      redistribute it. Commercial use is NOT permitted by that license.
#
#   3. LARGE BRAINSTEM LESIONS DEGRADE the segmentation. For a pipeline whose
#      raison d'etre is brainstem/pons hyperintensity, treat any nucleus that
#      overlaps a sizeable lesion with extreme caution.
#
# Pipeline relevance: BrainStemX works in the subject's structural (T1) native
# space, which is exactly AANSegment's input space - so no warping is required
# to run it; an OPTIONAL resample brings the labels onto the pipeline's working
# grid for reporting.
#
# Integration hook (NOT wired here - the analysis/segmentation stage owner wires
# it). One line, from the analysis stage, after the subject T1 is available:
#   run_aanseg "$t1_native" "$subject_id"
# Optionally pass a brainstem mask + an output dir:
#   run_aanseg "$t1_native" "$subject_id" "$brainstem_mask" "$out_dir"
#
# Dependencies (all detected at runtime; absence is a graceful, non-fatal skip):
#   - FreeSurfer (FREESURFER_HOME set) with SegmentAAN.sh on PATH, plus a
#     FreeSurfer license.
#   - A completed recon-all for the subject (AANSegment requires the FS stream's
#     T1.mgz + aseg). recon-all is hours long; this module NEVER runs it - it
#     detects the recon and skips gracefully if absent.
#   - FSL safe_fslmaths / fslstats / mri_convert for the optional resample +
#     per-nucleus volume reporting.
#
# NOTE: This is a SOURCED module, not a standalone script. Like the WMH modules
# (wmh_bianca.sh / wmh_lst_samseg.sh) it does NOT enable `set -e -u -o pipefail`
# at the top, because those options would leak into the parent shell. The
# pipeline already runs under `set -e -u -o pipefail`; every function here
# tolerates those options and returns 0 on any tool-missing / disabled /
# unreliable-input path so it never aborts the run.
#

# Include guard - prevent redundant re-sourcing by modules.
if [ -n "${_BRAINSTEM_AANSEG_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_BRAINSTEM_AANSEG_LOADED=1

# Require the pipeline environment (logging, error codes, safe_fslmaths, etc.).
# Fast no-op when the environment is already loaded.
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# Load defaults if not already loaded. Resolve relative to this file so the
# module is sourceable from any CWD (the include guard makes this a no-op when
# config is already loaded by the pipeline).
if [ -z "${_DEFAULT_CONFIG_LOADED:-}" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../../config/default_config.sh"
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Resolve a default output directory under RESULTS_DIR for AANSegment results.
# Honors the standard module-dir convention when available.
_aanseg_default_out_dir() {
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "brainstem_aanseg")"
    else
        base="${RESULTS_DIR:-../mri_results}/brainstem_aanseg"
        mkdir -p "$base"
    fi
    echo "$base"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_aanseg_fslmaths() {
    local description="$1"
    shift
    if declare -F safe_fslmaths >/dev/null 2>&1; then
        safe_fslmaths "$description" "$@"
    else
        log_message "$description (safe_fslmaths unavailable, using fslmaths): fslmaths $*"
        fslmaths "$@"
    fi
}

# Detect FreeSurfer + the AANSegment command + a FreeSurfer license. The verified
# invocation name is 'SegmentAAN.sh'
# (https://surfer.nmr.mgh.harvard.edu/fswiki/AANSegment),
# usage: SegmentAAN.sh <SUBJECT_ID> <SUBJECT_DIR>.
# Echoes the resolved command path on success (stdout); returns 0 if available,
# 1 otherwise. All diagnostics go to the logger (stderr) so stdout is clean.
_aanseg_detect_command() {
    if [ -z "${FREESURFER_HOME:-}" ]; then
        log_formatted "WARNING" "FREESURFER_HOME is not set - cannot run AANSegment (FreeSurfer required); skipping (non-fatal)"
        return 1
    fi

    # Primary, verified command name.
    local cmd=""
    if command -v SegmentAAN.sh >/dev/null 2>&1; then
        cmd="$(command -v SegmentAAN.sh)"
    elif [ -x "${FREESURFER_HOME}/bin/SegmentAAN.sh" ]; then
        cmd="${FREESURFER_HOME}/bin/SegmentAAN.sh"
    fi

    if [ -z "$cmd" ]; then
        log_formatted "WARNING" "FreeSurfer AANSegment command 'SegmentAAN.sh' not found on PATH or in \$FREESURFER_HOME/bin."
        log_formatted "WARNING" "  AANSegment ships with recent FreeSurfer (see https://surfer.nmr.mgh.harvard.edu/fswiki/AANSegment)."
        log_formatted "WARNING" "  Brainstem arousal-network (AAN) segmentation skipped (non-fatal)."
        return 1
    fi

    # FreeSurfer license: $FS_LICENSE, $FREESURFER_HOME/license.txt or .license
    local license_file="${FS_LICENSE:-}"
    if [ -z "$license_file" ]; then
        if [ -f "${FREESURFER_HOME}/license.txt" ]; then
            license_file="${FREESURFER_HOME}/license.txt"
        elif [ -f "${FREESURFER_HOME}/.license" ]; then
            license_file="${FREESURFER_HOME}/.license"
        fi
    fi
    if [ -z "$license_file" ] || [ ! -f "$license_file" ]; then
        log_formatted "WARNING" "FreeSurfer license not found (set FS_LICENSE or place license.txt in FREESURFER_HOME) - skipping AANSegment (non-fatal)"
        return 1
    fi
    # Export the resolved license so SegmentAAN.sh uses the SAME file we validated.
    export FS_LICENSE="$license_file"

    log_message "FreeSurfer AANSegment command detected: $cmd (license=$license_file)"
    echo "$cmd"
    return 0
}

# Locate the pipeline's brainstem mask on disk (used to restrict the per-nucleus
# volume report to within the brainstem). Searches the standard segmentation
# output locations and returns the first plausible match. Echoes the path on
# success (empty on failure); always returns 0 so it is safe under set -e.
_aanseg_find_brainstem_mask() {
    local results="${RESULTS_DIR:-../mri_results}"
    local candidate
    # Ordered, most-specific-first. Prefer an explicit binary brainstem mask.
    local patterns=(
        "${results}/segmentation/brainstem/"*"_brainstem_mask.nii.gz"
        "${results}/segmentation/"*"brainstem"*"mask"*".nii.gz"
        "${results}/segmentation/brainstem/"*"_brainstem.nii.gz"
        "${results}/segmentation/"*"_brainstem.nii.gz"
        "${results}/"*"brainstem"*"mask"*".nii.gz"
    )
    local pattern
    for pattern in "${patterns[@]}"; do
        for candidate in $pattern; do
            if [ -f "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
    done
    echo ""
    return 0
}

# Check that every spatial dimension of a NIfTI is <= AANSEG_MAX_VOXEL_MM.
# Returns 0 when the input is fine enough (all dims <= limit), 1 when any
# dimension is COARSER than the limit (the unreliable regime). Always logs.
# fslval reports pixdim as a possibly space/zero-padded float; we compare with
# awk so no `bc` dependency is required.
_aanseg_voxel_size_ok() {
    local img="$1"
    local limit="${AANSEG_MAX_VOXEL_MM:-1.0}"

    if ! command -v fslval >/dev/null 2>&1; then
        log_formatted "WARNING" "fslval not available - cannot verify AANSegment input voxel size (need <= ${limit} mm). Proceeding without the resolution guard."
        return 0
    fi

    local p1 p2 p3
    p1=$(fslval "$img" pixdim1 2>/dev/null | tr -d '[:space:]')
    p2=$(fslval "$img" pixdim2 2>/dev/null | tr -d '[:space:]')
    p3=$(fslval "$img" pixdim3 2>/dev/null | tr -d '[:space:]')

    # Validate we got numbers; if not, do not block (log and continue).
    local v
    for v in "$p1" "$p2" "$p3"; do
        if ! [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_formatted "WARNING" "Could not read a numeric voxel dimension from '$img' (got '$p1' x '$p2' x '$p3') - cannot enforce the <= ${limit} mm AANSegment resolution guard. Proceeding."
            return 0
        fi
    done

    log_message "AANSegment input voxel size: ${p1} x ${p2} x ${p3} mm (limit ${limit} mm)"

    # any dimension > limit => too coarse.
    local too_coarse
    too_coarse=$(awk -v a="$p1" -v b="$p2" -v c="$p3" -v lim="$limit" \
        'BEGIN { print ((a>lim)||(b>lim)||(c>lim)) ? 1 : 0 }')

    if [ "$too_coarse" = "1" ]; then
        log_formatted "WARNING" "AANSegment input voxel size (${p1} x ${p2} x ${p3} mm) is COARSER than ${limit} mm."
        log_formatted "WARNING" "  The AANSegment authors warn against resolution coarser than 1 mm; per-nucleus volumetrics will be UNRELIABLE."
        log_formatted "WARNING" "  (This is the expected regime for clinical FLAIR slice thickness.)"
        return 1
    fi

    log_message "AANSegment resolution guard passed (all dims <= ${limit} mm)"
    return 0
}

# Find the AANSegment label volume produced in a recon's mri/ dir. Prefers the
# native (FSvoxelSpace) variant, then any other. The version suffix (e.g.
# atlas_v10) varies by FreeSurfer release, so we glob. Echoes the first match on
# stdout (empty if none); always returns 0 (safe under set -e). A non-matching
# glob stays literal and is rejected by the `[ -f ]` guard.
_aanseg_find_label_mgz() {
    local recon_dir="$1"
    local cand
    for cand in "${recon_dir}/mri/"arousalNetworkLabels.*.FSvoxelSpace.mgz \
                "${recon_dir}/mri/"arousalNetworkLabels.*.mgz; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    echo ""
    return 0
}

# Convert an FS label volume (.mgz) to a NIfTI of integer labels, optionally
# resampled onto a reference grid (nearest-neighbour preserves discrete labels).
# Usage: _aanseg_convert_labels <in.mgz> <out.nii.gz> [<ref_for_-rl>]
# Returns mri_convert's status. Single source of truth for the conversion flags.
_aanseg_convert_labels() {
    local in_mgz="$1"
    local out_nii="$2"
    local ref="${3:-}"
    local -a rl=()
    [ -n "$ref" ] && rl=(-rl "$ref")
    mri_convert "${rl[@]}" -rt nearest -odt int "$in_mgz" "$out_nii" >/dev/null 2>&1
}

# Report per-nucleus volumes from a labelled AAN volume, restricted to within a
# brainstem mask when one is available. Args:
#   $1 labelled AAN volume in the working grid (.nii.gz, integer labels)
#   $2 output directory (a summary file is written here)
#   $3 (optional) brainstem mask in the SAME grid as $1
# Always returns 0 (reporting is non-fatal). Uses fslstats only.
_aanseg_report_volumes() {
    local labels="$1"
    local out_dir="$2"
    local brainstem_mask="${3:-}"

    if [ ! -f "$labels" ]; then
        log_formatted "WARNING" "AANSegment: labelled volume not found for volume reporting: $labels"
        return 0
    fi

    # Restrict to the brainstem if a co-gridded mask was supplied.
    local report_src="$labels"
    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        local restricted="${out_dir}/aanseg_labels_in_brainstem.nii.gz"
        if _aanseg_fslmaths "AANSegment: restrict nuclei to brainstem" \
            "$labels" -mas "$brainstem_mask" "$restricted"; then
            report_src="$restricted"
            log_message "AANSegment: per-nucleus volumes restricted to brainstem mask: $brainstem_mask"
        else
            log_formatted "WARNING" "AANSegment: failed to restrict labels to brainstem mask; reporting over the full labelled volume"
        fi
    else
        log_message "AANSegment: no brainstem mask supplied/found; reporting per-nucleus volumes over the full labelled volume"
    fi

    # Determine the maximum label value so we can probe each integer label.
    # '|| true' keeps the pipe non-fatal under set -o pipefail; ceil($2) (not
    # truncation) so a near-integer robust-max like 9.9998 still yields 10 and
    # the top nucleus label is probed.
    local maxval
    maxval=$( { fslstats "$report_src" -R 2>/dev/null || true; } | awk '{v=$2; printf "%d", (v==int(v)?v:int(v)+1)}')
    [[ "$maxval" =~ ^[0-9]+$ ]] || maxval=0

    local summary="${out_dir}/aanseg_nucleus_volumes.txt"
    {
        echo "# EXPLORATORY brainstem arousal-network (AAN) per-label volumes"
        echo "# source=${report_src}"
        echo "# brainstem_restricted=$([ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ] && echo yes || echo no)"
        echo "# CAVEAT: reliable only for <= 1 mm input; degraded by large brainstem lesions; CC BY-NC-ND."
        echo "# label  n_voxels  volume_mm3"
    } > "$summary" 2>/dev/null || true

    local label n_vox vol_mm3 stats
    local reported=0
    for ((label = 1; label <= maxval; label++)); do
        # Voxels with exactly this label value (fslstats -l/-u are exclusive).
        stats=$(fslstats "$report_src" -l "$((label - 1))" -u "$((label + 1))" -V 2>/dev/null) || stats="0 0"
        n_vox=$(echo "$stats" | awk '{print $1}')
        vol_mm3=$(echo "$stats" | awk '{print $2}')
        [ -z "$n_vox" ] && n_vox=0
        if [ "$n_vox" != "0" ]; then
            printf '%d  %s  %s\n' "$label" "$n_vox" "$vol_mm3" >> "$summary" 2>/dev/null || true
            log_formatted "INFO" "AANSegment nucleus label ${label}: voxels=${n_vox}, volume=${vol_mm3} mm^3"
            reported=$((reported + 1))
        fi
    done

    if [ "$reported" -eq 0 ]; then
        log_formatted "WARNING" "AANSegment: no non-zero nucleus labels found in $report_src"
    fi
    log_message "AANSegment per-nucleus volume summary: $summary"
    return 0
}

# ----------------------------------------------------------------------------
# Main entry point
# ----------------------------------------------------------------------------

# run_aanseg - EXPLORATORY brainstem arousal-network nuclei segmentation.
#
# Usage:
#   run_aanseg <t1_native.nii.gz> <subject_id> [<brainstem_mask>] [<out_dir>]
#
# Arguments:
#   $1  Subject T1 in NATIVE space (the AANSegment / FreeSurfer input space).
#   $2  Subject id - used to locate the FreeSurfer recon (SUBJECTS_DIR/<id>).
#   $3  (optional) brainstem mask for restricting the per-nucleus volume report.
#       If omitted, the module attempts to locate one under RESULTS_DIR.
#   $4  (optional) output directory (default: RESULTS_DIR/brainstem_aanseg).
#
# Behaviour (always graceful / non-fatal - returns 0 on every skip path):
#   - Skips when BRAINSTEM_AANSEG_ENABLED != "true".
#   - Skips when FreeSurfer / SegmentAAN.sh / FS license is unavailable.
#   - Skips when no completed FreeSurfer recon exists for the subject.
#   - WARNS and (by default) SKIPS when input voxel size > AANSEG_MAX_VOXEL_MM.
#   - On success: copies the native-space AAN label/volume outputs into out_dir,
#     resamples the labels onto the pipeline working grid (when a brainstem mask
#     defines that grid), and reports per-nucleus volumes within the brainstem.
run_aanseg() {
    local t1_native="${1:-}"
    local subject_id="${2:-}"
    local brainstem_mask="${3:-}"
    local out_dir="${4:-}"

    log_formatted "INFO" "=== EXPLORATORY BRAINSTEM AROUSAL-NETWORK SEGMENTATION (FreeSurfer AANSegment) ==="
    log_formatted "INFO" "EXPLORATORY/RESEARCH-ONLY: reliable only for <= ${AANSEG_MAX_VOXEL_MM:-1.0} mm input; degraded by large brainstem lesions; tool is CC BY-NC-ND 4.0 (non-commercial, no-derivatives - we only invoke it)."
    log_message "T1 (native): ${t1_native:-<none>}"
    log_message "Subject id: ${subject_id:-<none>}"
    [ -n "$brainstem_mask" ] && log_message "Brainstem mask (for reporting): $brainstem_mask"

    # --- Feature flag (default OFF) -----------------------------------------
    if [ "${BRAINSTEM_AANSEG_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "BRAINSTEM_AANSEG_ENABLED is not 'true' - skipping AANSegment (set BRAINSTEM_AANSEG_ENABLED=true to enable this EXPLORATORY module)"
        return 0
    fi

    # --- Argument validation -------------------------------------------------
    if [ -z "$t1_native" ] || [ -z "$subject_id" ]; then
        log_formatted "WARNING" "run_aanseg: missing required arguments (T1 and subject_id) - skipping (non-fatal)"
        return 0
    fi
    if [ ! -f "$t1_native" ]; then
        log_formatted "WARNING" "run_aanseg: T1 file not found: $t1_native - skipping (non-fatal)"
        return 0
    fi

    # --- Tool availability (graceful skip) -----------------------------------
    local aanseg_cmd
    if ! aanseg_cmd="$(_aanseg_detect_command)"; then
        log_formatted "WARNING" "FreeSurfer AANSegment unavailable - brainstem arousal-network segmentation skipped (non-fatal)"
        return 0
    fi

    # --- Resolution guard (>1 mm => unreliable) ------------------------------
    if ! _aanseg_voxel_size_ok "$t1_native"; then
        if [ "${AANSEG_SKIP_IF_COARSE:-true}" = "true" ]; then
            log_formatted "WARNING" "Skipping AANSegment because the input is coarser than ${AANSEG_MAX_VOXEL_MM:-1.0} mm (set AANSEG_SKIP_IF_COARSE=false to run anyway, but treat volumes as UNRELIABLE)."
            return 0
        fi
        log_formatted "WARNING" "AANSEG_SKIP_IF_COARSE=false - running AANSegment on coarse input anyway; per-nucleus volumes are UNRELIABLE."
    fi

    # --- Locate the FreeSurfer recon for this subject ------------------------
    # AANSegment requires a completed recon-all (T1.mgz + aseg) for the subject.
    # recon-all is hours long; this module NEVER runs it - it requires a prior
    # recon and skips gracefully otherwise (cached/resumable by construction).
    # Search the pipeline-local FreeSurfer subjects dir first (where the sibling
    # brainstem_freesurfer.sh writes recons), then SUBJECTS_DIR / FS subjects.
    local -a subjects_dir_candidates=(
        "${AANSEG_SUBJECTS_DIR:-}"
        "${SUBJECTS_DIR:-}"
        "${RESULTS_DIR:-../mri_results}/freesurfer"
        "${FREESURFER_HOME:-}/subjects"
    )
    local subjects_dir=""
    local recon_dir=""
    local cand_sd
    for cand_sd in "${subjects_dir_candidates[@]}"; do
        [ -n "$cand_sd" ] || continue
        if [ -f "${cand_sd}/${subject_id}/mri/T1.mgz" ] && [ -f "${cand_sd}/${subject_id}/mri/aseg.mgz" ]; then
            subjects_dir="$cand_sd"
            recon_dir="${cand_sd}/${subject_id}"
            break
        fi
    done

    if [ -z "$recon_dir" ]; then
        log_formatted "WARNING" "No completed FreeSurfer recon (T1.mgz + aseg.mgz) found for subject '${subject_id}' in: ${subjects_dir_candidates[*]}"
        log_formatted "WARNING" "  AANSegment requires a prior 'recon-all -all -s ${subject_id}'. This module does NOT run the hours-long recon-all."
        log_formatted "WARNING" "  Run recon-all first (or point SUBJECTS_DIR at an existing recon), then re-run. Skipping AANSegment (non-fatal)."
        return 0
    fi
    log_message "FreeSurfer recon for subject '${subject_id}': $recon_dir (SUBJECTS_DIR=$subjects_dir)"

    # --- Workspace -----------------------------------------------------------
    [ -z "$out_dir" ] && out_dir="${AANSEG_OUTPUT_DIR:-}"
    [ -z "$out_dir" ] && out_dir="$(_aanseg_default_out_dir)"
    mkdir -p "$out_dir" || {
        log_formatted "WARNING" "Could not create AANSegment output directory: $out_dir - skipping (non-fatal)"
        return 0
    }

    # --- Run / reuse AANSegment ---------------------------------------------
    # Outputs land in the recon's mri/ dir as arousalNetworkLabels.*.mgz and
    # arousalNetworkVolumes.*.txt (the version suffix, e.g. atlas_v10, varies by
    # FreeSurfer release - match with a glob). Reuse a cached result if present.
    local existing_label_mgz
    existing_label_mgz="$(_aanseg_find_label_mgz "$recon_dir")"

    if [ -n "$existing_label_mgz" ]; then
        log_formatted "INFO" "Reusing cached AANSegment output: $existing_label_mgz (delete it to force re-run)"
    else
        log_message "Running: $aanseg_cmd $subject_id $subjects_dir"
        local rc=0
        # AANSegment reads SUBJECTS_DIR from the environment and/or argv.
        SUBJECTS_DIR="$subjects_dir" "$aanseg_cmd" "$subject_id" "$subjects_dir" || rc=$?
        if [ "$rc" -ne 0 ]; then
            log_formatted "WARNING" "AANSegment (SegmentAAN.sh) exited with status $rc - brainstem arousal-network segmentation skipped (non-fatal)"
            return 0
        fi
        existing_label_mgz="$(_aanseg_find_label_mgz "$recon_dir")"
    fi

    if [ -z "$existing_label_mgz" ]; then
        log_formatted "WARNING" "AANSegment produced no arousalNetworkLabels.*.mgz in ${recon_dir}/mri - skipping reporting (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "AANSegment label volume: $existing_label_mgz"

    # Copy the native-space volume table alongside our outputs (provenance).
    local vol_txt
    for vol_txt in "${recon_dir}/mri/"arousalNetworkVolumes.*.txt; do
        if [ -f "$vol_txt" ]; then
            cp -f "$vol_txt" "${out_dir}/$(basename "$vol_txt")" 2>/dev/null || true
            log_message "AANSegment native volume table: ${out_dir}/$(basename "$vol_txt")"
            break
        fi
    done

    # --- Bring labels into NIfTI (native FS grid) ----------------------------
    # The FS labels are in FS space. Convert to NIfTI in the NATIVE grid first.
    # IMPORTANT: per-nucleus volumes are reported from the native (fine) grid,
    # NOT a working-grid resample - the AAN nuclei are tiny (a few mm), so
    # nearest-neighbour resampling them onto a coarse clinical working grid would
    # silently collapse/drop nuclei, exactly the unreliable regime the resolution
    # guard exists to prevent. The optional working-grid copy below is a
    # convenience artifact for overlay/visualization only.
    if ! command -v mri_convert >/dev/null 2>&1; then
        log_formatted "WARNING" "AANSegment: mri_convert not available to convert FS labels to NIfTI - skipping resample/reporting (non-fatal)"
        return 0
    fi

    local labels_native="${out_dir}/aanseg_labels_native.nii.gz"
    if ! _aanseg_convert_labels "$existing_label_mgz" "$labels_native"; then
        log_formatted "WARNING" "AANSegment: mri_convert failed to convert labels to NIfTI - skipping reporting (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "AANSegment labels (NIfTI, native FS grid): $labels_native"

    # --- Locate a brainstem mask if not supplied -----------------------------
    if [ -z "$brainstem_mask" ]; then
        brainstem_mask="$(_aanseg_find_brainstem_mask)"
        [ -n "$brainstem_mask" ] && log_message "Auto-located brainstem mask: $brainstem_mask"
    fi

    # --- Optional convenience copy on the pipeline working grid --------------
    # Resampling onto a coarse working grid is LOSSY for these tiny nuclei, so it
    # is produced only when explicitly requested, with a clear warning, and is
    # NEVER used for the volume report.
    local labels_working=""
    if [ "${AANSEG_WRITE_REGION_MASKS:-false}" = "true" ] && [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        labels_working="${out_dir}/aanseg_labels_working.nii.gz"
        if _aanseg_convert_labels "$existing_label_mgz" "$labels_working" "$brainstem_mask"; then
            log_formatted "WARNING" "AANSegment: wrote a working-grid label copy ($labels_working) by NN-resampling onto $brainstem_mask. This is LOSSY for tiny nuclei - use for overlay only, NOT volumetry."
            # Stage where find_all_atlas_regions COULD pick it up later. We do
            # NOT wire this into analysis.sh (owned elsewhere).
            local region_dir="${RESULTS_DIR:-../mri_results}/segmentation/brainstem_aan_nuclei"
            mkdir -p "$region_dir" 2>/dev/null || true
            cp -f "$labels_working" "${region_dir}/aanseg_nuclei_labels.nii.gz" 2>/dev/null || true
            log_message "AANSegment: staged working-grid nuclei labels for potential downstream use: ${region_dir}/aanseg_nuclei_labels.nii.gz (NOT wired into analysis)"
        else
            log_formatted "WARNING" "AANSegment: failed to produce the optional working-grid label copy (continuing with native-grid report)"
            labels_working=""
        fi
    fi

    # --- Per-nucleus volume report (native grid) -----------------------------
    # Restrict to the brainstem only when the mask already shares the native grid
    # (i.e. it WAS the native reference). To avoid grid-mismatch corruption we
    # resample the brainstem mask onto the native label grid before masking.
    local bs_for_report=""
    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        bs_for_report="${out_dir}/aanseg_brainstem_bin.nii.gz"
        local bs_on_grid="${out_dir}/aanseg_brainstem_on_native_grid.nii.gz"
        # Resample the mask onto the native label grid (NN), then binarise.
        if _aanseg_convert_labels "$brainstem_mask" "$bs_on_grid" "$labels_native" \
            && _aanseg_fslmaths "AANSegment: binarise brainstem mask" "$bs_on_grid" -bin "$bs_for_report"; then
            log_message "AANSegment: brainstem mask resampled onto native label grid for restricted reporting"
        else
            log_formatted "WARNING" "AANSegment: could not align brainstem mask to the native label grid - reporting over the full labelled volume"
            bs_for_report=""
        fi
    fi

    _aanseg_report_volumes "$labels_native" "$out_dir" "$bs_for_report"

    log_formatted "SUCCESS" "EXPLORATORY brainstem arousal-network (AANSegment) analysis complete"
    log_formatted "INFO" "Reminder: AANSegment is EXPLORATORY (<= 1 mm only, lesion-sensitive, CC BY-NC-ND); interpret per-nucleus volumes with caution."
    return 0
}

# ----------------------------------------------------------------------------
# Exports
# ----------------------------------------------------------------------------
export -f _aanseg_default_out_dir
export -f _aanseg_fslmaths
export -f _aanseg_detect_command
export -f _aanseg_find_brainstem_mask
export -f _aanseg_find_label_mgz
export -f _aanseg_convert_labels
export -f _aanseg_voxel_size_ok
export -f _aanseg_report_volumes
export -f run_aanseg

log_message "Brainstem AANSegment module loaded (EXPLORATORY, default-OFF)"
