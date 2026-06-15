#!/usr/bin/env bash
#
# wmh_synthseg.sh - Contrast-agnostic WMH + whole-brain segmentation via
#                   FreeSurfer's WMH-SynthSeg (mri_WMHsynthseg).
#
# WMH-SynthSeg (Laso et al., ISBI 2024; arXiv:2312.05119) is a
# domain-randomized SynthSeg variant that JOINTLY segments white-matter
# hyperintensities (WMH) plus ~36 brain regions on ANY contrast/resolution
# (T1, T2, FLAIR, low-field portable scanners) with NO retraining. It ships in
# FreeSurfer (>=7.4.x) as the `mri_WMHsynthseg` command and always returns a
# 1mm-isotropic SynthSeg-style label volume regardless of input resolution.
#
# ────────────────────────────────────────────────────────────────────────────
# CAVEAT — READ BEFORE TRUSTING THIS MASK
# ────────────────────────────────────────────────────────────────────────────
# Independent evaluations find WMH-SynthSeg the LEAST accurate of the modern WMH
# tools for boundary delineation, and it tends to OVER-FLAG any hyperintense
# pathology as WMH. That is especially dangerous near the brainstem, where
# CSF-flow / pulsation artifacts can masquerade as hyperintensity. Therefore
# this module is positioned as a ROBUSTNESS / PORTABILITY (any-contrast,
# low-field) + ANATOMY / NORMALIZATION option, NOT as the primary lesion mask.
# Always pair its output with the pipeline's false-positive (FP) filter and the
# primary detection path; do not report its raw mask as ground truth.
# ────────────────────────────────────────────────────────────────────────────
#
# What this module does:
#   - Detects `mri_WMHsynthseg` on PATH (FreeSurfer). Absent => graceful
#     WARNING + non-fatal `return 0` (never aborts the pipeline).
#   - Runs on the subject FLAIR (preferred) or T1 — contrast-agnostic, so either
#     works; a single input is sufficient.
#   - Extracts the WMH label (FreeSurfer LUT label 77, "WM-hypointensities") to
#     a binary mask.
#   - Reports WMH cluster count + volume (mm^3).
#   - Intersects the WMH mask with the pipeline's brainstem mask
#     (*brainstem*mask*.nii.gz) via safe_fslmaths to report a
#     brainstem-restricted WMH burden separately.
#   - Writes a small machine-readable summary.
#
# Entry point:
#   run_wmh_synthseg <input_image> [out_dir]
#       <input_image> : subject FLAIR (preferred) or T1, any contrast/resolution
#       [out_dir]     : optional; defaults under RESULTS_DIR/wmh_supervised
#
# Integration hook (for the coordinator to wire into the analysis stage):
#   run_wmh_synthseg "$orig_flair"        # or "$orig_t1" if no FLAIR
#
# NOTE: This is a SOURCED module, not a standalone script. Like the other
# sourced modules (segmentation.sh, wmh_lst_samseg.sh, ...) it does NOT enable
# `set -e -u -o pipefail` at the top, because those options would leak into the
# parent shell and turn every later command in pipeline.sh fatal. The pipeline
# already runs under `set -e -u -o pipefail` (pipeline.sh), and every function
# here is written to tolerate those options and to return 0 on any
# tool-missing/disabled/failure path so it never aborts the run.
#

# Include guard
if [ -n "${_WMH_SYNTHSEG_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_WMH_SYNTHSEG_LOADED=1

# Lightweight environment guard (fast no-op during pipeline execution)
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

# Resolve a default output directory under RESULTS_DIR for the WMH-SynthSeg
# results. Honors the standard module-dir convention when available.
_wmh_synthseg_default_out_dir() {
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "wmh_supervised")"
    else
        base="${RESULTS_DIR:-../mri_results}/wmh_supervised"
        mkdir -p "$base"
    fi
    local dir="${base}/synthseg"
    mkdir -p "$dir"
    echo "$dir"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_wmh_synthseg_fslmaths() {
    local description="$1"
    shift
    if declare -F safe_fslmaths >/dev/null 2>&1; then
        safe_fslmaths "$description" "$@"
    else
        log_message "$description (safe_fslmaths unavailable, using fslmaths): fslmaths $*"
        fslmaths "$@"
    fi
}

# Echo the WMH volume (mm^3) of a binary mask, or fail (return 1) if it cannot
# be computed. fslstats -V prints "<nvoxels> <volume_mm3>"; field 2 is the
# volume. A successful run that yields a non-numeric/empty field 2 is treated as
# a failure so the caller does not record a blank value as a real measurement.
_wmh_synthseg_mask_volume_mm3() {
    local mask="$1"
    local stats vol
    if ! stats=$(fslstats "$mask" -V 2>/dev/null); then
        return 1
    fi
    vol=$(echo "$stats" | awk '{print $2}')
    if [[ "$vol" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$vol"
        return 0
    fi
    return 1
}

# Echo the connected-component cluster count of a binary mask (0 on failure).
# Uses FSL 'cluster' (26-connectivity); the table has a header line plus one
# row per cluster, so cluster count = data rows. Always returns 0.
_wmh_synthseg_cluster_count() {
    local mask="$1"
    local n_clusters=0
    if command -v cluster >/dev/null 2>&1; then
        local cluster_report
        cluster_report=$(cluster --in="$mask" --thresh=0.5 --connectivity=26 2>/dev/null) || cluster_report=""
        if [ -n "$cluster_report" ]; then
            n_clusters=$(printf '%s\n' "$cluster_report" | tail -n +2 | grep -c . || true)
            [ -z "$n_clusters" ] && n_clusters=0
        fi
    fi
    echo "$n_clusters"
    return 0
}

# Locate the pipeline's brainstem mask on disk. Searches the standard
# segmentation output locations and returns the first plausible match.
# Echoes the path on success (empty on failure); always returns 0.
_wmh_synthseg_find_brainstem_mask() {
    local results="${RESULTS_DIR:-../mri_results}"
    local candidate
    # Ordered search patterns, most specific/authoritative first. We prefer the
    # explicit binary brainstem mask. We intentionally do NOT fall back to a
    # single hemi-pons file — that would silently restrict WMH to one sub-region
    # and grossly under-report.
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

# Report total + brainstem-restricted WMH (cluster count, volume) and write a
# machine-readable summary for a binary WMH mask.
# Args: <wmh_binary_mask> <out_dir>
# Writes a brainstem-restricted mask (wmh_synthseg_brainstem_wmh.nii.gz) when a
# brainstem mask is found. Always returns 0 (reporting is non-fatal).
_wmh_synthseg_report() {
    local wmh_mask="$1"
    local out_dir="$2"
    local tool_label="wmh_synthseg"

    if [ ! -f "$wmh_mask" ]; then
        log_formatted "WARNING" "${tool_label}: WMH mask not found for reporting: $wmh_mask"
        return 0
    fi

    # Whole-brain WMH cluster count + volume.
    local total_clusters
    total_clusters="$(_wmh_synthseg_cluster_count "$wmh_mask")"
    local total_vol="N/A"
    if total_vol=$(_wmh_synthseg_mask_volume_mm3 "$wmh_mask"); then
        log_formatted "INFO" "${tool_label}: whole-brain WMH clusters=${total_clusters}, volume=${total_vol} mm^3"
    else
        log_formatted "WARNING" "${tool_label}: could not compute whole-brain WMH volume"
        total_vol="N/A"
    fi

    # Brainstem-restricted WMH.
    local brainstem_mask
    brainstem_mask="$(_wmh_synthseg_find_brainstem_mask)"
    local brainstem_vol="N/A"
    local brainstem_clusters=0
    local brainstem_wmh="${out_dir}/${tool_label}_brainstem_wmh.nii.gz"

    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        log_message "${tool_label}: intersecting WMH mask with brainstem mask: $brainstem_mask"
        if _wmh_synthseg_fslmaths "${tool_label}: brainstem WMH intersection" \
            "$wmh_mask" -mas "$brainstem_mask" -bin "$brainstem_wmh"; then
            brainstem_clusters="$(_wmh_synthseg_cluster_count "$brainstem_wmh")"
            if brainstem_vol=$(_wmh_synthseg_mask_volume_mm3 "$brainstem_wmh"); then
                log_formatted "INFO" "${tool_label}: brainstem-restricted WMH clusters=${brainstem_clusters}, volume=${brainstem_vol} mm^3"
            else
                log_formatted "WARNING" "${tool_label}: could not compute brainstem WMH volume"
                brainstem_vol="N/A"
            fi
        else
            log_formatted "WARNING" "${tool_label}: brainstem intersection failed"
        fi
    else
        log_formatted "WARNING" "${tool_label}: no brainstem mask found; skipping brainstem-restricted WMH (run segmentation stage first)"
    fi

    # Persist a small machine-readable summary, restating the caveat in-band so
    # downstream consumers cannot mistake this for a primary lesion mask.
    local summary="${out_dir}/${tool_label}_wmh_summary.txt"
    {
        echo "tool=${tool_label}"
        echo "wmh_mask=${wmh_mask}"
        echo "wmh_label=${WMH_SYNTHSEG_LABEL:-77}"
        echo "whole_brain_wmh_clusters=${total_clusters}"
        echo "whole_brain_wmh_mm3=${total_vol}"
        echo "brainstem_mask=${brainstem_mask:-none}"
        echo "brainstem_wmh_mask=${brainstem_wmh}"
        echo "brainstem_wmh_clusters=${brainstem_clusters}"
        echo "brainstem_wmh_mm3=${brainstem_vol}"
        echo "caveat=contrast-agnostic robustness/anatomy option; over-flags hyperintensity as WMH; NOT primary, pair with FP-filter"
    } > "$summary" 2>/dev/null || true
    log_message "${tool_label}: summary written to $summary"

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Detection
# ──────────────────────────────────────────────────────────────────────────────

# Detect FreeSurfer's mri_WMHsynthseg. Returns 0 if available, 1 otherwise.
_wmh_synthseg_detect() {
    if ! command -v mri_WMHsynthseg &>/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Main entry point
# ──────────────────────────────────────────────────────────────────────────────

# run_wmh_synthseg <input_image> [out_dir]
# Runs FreeSurfer WMH-SynthSeg on a single (any-contrast) subject image,
# extracts the WMH label to a binary mask, reports cluster count + volume,
# intersects with the brainstem mask, and writes a summary.
# Graceful non-fatal skip if disabled, inputs missing, or the tool is absent.
run_wmh_synthseg() {
    log_message "=== run_wmh_synthseg (contrast-agnostic WMH-SynthSeg) ==="
    # Caveat restated at runtime so it lands in every pipeline log.
    log_formatted "WARNING" "WMH-SynthSeg over-flags hyperintense pathology as WMH and is least accurate at boundaries (esp. near brainstem CSF-flow artifacts). This is a robustness/portability + anatomy/normalization option, NOT the primary lesion mask — pair its output with the FP-filter."

    local input_file="${1:-}"
    local out_dir="${2:-}"

    if [ "${WMH_SYNTHSEG_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "WMH-SynthSeg disabled (WMH_SYNTHSEG_ENABLED=${WMH_SYNTHSEG_ENABLED:-false}); skipping"
        return 0
    fi

    if [ -z "$input_file" ]; then
        log_formatted "WARNING" "WMH-SynthSeg: an input image (FLAIR preferred, or T1) is required; skipping"
        return 0
    fi
    if [ ! -f "$input_file" ]; then
        log_formatted "WARNING" "WMH-SynthSeg: input image not found: $input_file; skipping"
        return 0
    fi

    if ! _wmh_synthseg_detect; then
        log_formatted "WARNING" "FreeSurfer mri_WMHsynthseg not found on PATH. Install FreeSurfer (>=7.4.x) and the WMH-SynthSeg model (\$FREESURFER_HOME/models/WMH-SynthSeg_v10_231110.pth); skipping WMH-SynthSeg (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "FreeSurfer mri_WMHsynthseg detected"

    [ -z "$out_dir" ] && out_dir="$(_wmh_synthseg_default_out_dir)"
    mkdir -p "$out_dir"

    local seg_out="${out_dir}/wmh_synthseg_seg.nii.gz"
    local vols_csv="${out_dir}/wmh_synthseg_vols.csv"
    local device="${WMH_SYNTHSEG_DEVICE:-cpu}"
    local threads="${MAX_CPU_INTENSIVE_JOBS:-1}"

    log_message "WMH-SynthSeg input: $input_file"
    log_message "WMH-SynthSeg output dir: $out_dir (device=$device, threads=$threads)"

    # mri_WMHsynthseg --i <input> --o <output> [--csv_vols <csv>] [--device <dev>]
    #   [--threads <n>] [--crop] [--save_lesion_probabilities]
    # Output is always 1mm-isotropic SynthSeg-style labels regardless of input.
    local rc=0
    mri_WMHsynthseg \
        --i "$input_file" \
        --o "$seg_out" \
        --csv_vols "$vols_csv" \
        --device "$device" \
        --threads "$threads" || rc=$?

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "mri_WMHsynthseg exited with status $rc; skipping downstream WMH-SynthSeg reporting (non-fatal)"
        return 0
    fi

    if [ ! -f "$seg_out" ]; then
        log_formatted "WARNING" "WMH-SynthSeg completed but segmentation output not found: $seg_out; skipping reporting"
        return 0
    fi
    log_formatted "SUCCESS" "WMH-SynthSeg segmentation: $seg_out"

    # Extract the WMH label (FreeSurfer LUT 77, "WM-hypointensities") to a binary
    # mask. The seg volume is integer-valued labels, so a discrete
    # thr==uthr==label selection isolates WMH exactly.
    local wmh_label="${WMH_SYNTHSEG_LABEL:-77}"
    local wmh_bin="${out_dir}/wmh_synthseg_wmh_bin.nii.gz"
    if ! _wmh_synthseg_fslmaths "WMH-SynthSeg: extract WMH label $wmh_label" \
        "$seg_out" -thr "$wmh_label" -uthr "$wmh_label" -bin "$wmh_bin"; then
        log_formatted "WARNING" "WMH-SynthSeg: failed to extract WMH label $wmh_label; skipping reporting"
        return 0
    fi
    log_formatted "SUCCESS" "WMH-SynthSeg WMH mask: $wmh_bin"

    _wmh_synthseg_report "$wmh_bin" "$out_dir"

    log_formatted "SUCCESS" "WMH-SynthSeg complete (robustness/anatomy option — NOT primary; pair with FP-filter)"
    return 0
}
