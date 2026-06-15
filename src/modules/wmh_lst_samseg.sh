#!/usr/bin/env bash
#
# wmh_lst_samseg.sh - Supervised / learned white-matter-hyperintensity (WMH)
#                     detection using pretrained, training-data-free tools.
#
# This module is a self-contained, sourceable add-on that provides two modern
# WMH / lesion segmentation back-ends, neither of which requires the user to
# supply training data (both ship pretrained models):
#
#   1) LST-AI  -- deep-learning successor to SPM-LST. Python/Docker, no MATLAB.
#                 Needs co-registered FLAIR + T1. https://github.com/CompImg/LST-AI
#   2) FreeSurfer SAMSEG lesion segmentation
#                 -- run_samseg --lesion --lesion-mask-pattern ... -i FLAIR -i T1
#                 Needs FreeSurfer (>=7.x) + $FREESURFER_HOME.
#
# Both produce a whole-brain WMH/lesion mask which this module additionally
# intersects with the pipeline's brainstem / posterior-fossa mask to report a
# brainstem-restricted WMH burden separately.
#
# Entry points:
#   run_lstai_wmh   <flair> <t1> [out_dir]
#   run_samseg_wmh  <flair> <t1> [out_dir]
#   run_supervised_wmh_lst_samseg <flair> <t1> [out_dir]   # dispatcher
#
# Integration hook (for the coordinator to wire into the analysis stage):
#   run_supervised_wmh_lst_samseg "$orig_flair" "$orig_t1"
#
# Both entry functions degrade gracefully (non-fatal WARNING + return 0) when
# their tool is disabled via config or not installed, so they never crash the
# pipeline.
#
# NOTE: This is a SOURCED module, not a standalone script. Like the other
# sourced modules (segmentation.sh, hierarchical_joint_fusion.sh, ...) it does
# NOT enable `set -e -u -o pipefail` at the top, because those options would
# leak into the parent shell and turn every later command in pipeline.sh fatal.
# The pipeline already runs under `set -e -u -o pipefail` (pipeline.sh), and
# every function here is written to tolerate those options and to return 0 on
# any tool-missing/disabled/failure path so it never aborts the run.
#

# Include guard
if [ -n "${_WMH_LST_SAMSEG_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_WMH_LST_SAMSEG_LOADED=1

# Lightweight environment guard (fast no-op during pipeline execution)
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

# Resolve a default output directory under RESULTS_DIR for the supervised WMH
# results. Honors the standard module-dir convention when available.
_wmh_default_out_dir() {
    local sub_dir="$1"   # e.g. "lst_ai" or "samseg"
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "wmh_supervised")"
    else
        base="${RESULTS_DIR:-../mri_results}/wmh_supervised"
        mkdir -p "$base"
    fi
    local dir="${base}/${sub_dir}"
    mkdir -p "$dir"
    echo "$dir"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_wmh_fslmaths() {
    local description="$1"
    shift
    if declare -F safe_fslmaths >/dev/null 2>&1; then
        safe_fslmaths "$description" "$@"
    else
        log_message "$description (safe_fslmaths unavailable, using fslmaths): fslmaths $*"
        fslmaths "$@"
    fi
}

# Echo the WMH volume (mm^3) of a binary mask, or empty on failure.
# fslstats -V prints "<nvoxels> <volume_mm3>"; field 2 is the volume. We treat
# a successful run that yields a non-numeric/empty field 2 as a failure so the
# caller does not record a blank value as if it were a real measurement.
_wmh_mask_volume_mm3() {
    local mask="$1"
    local stats vol
    if ! stats=$(fslstats "$mask" -V 2>/dev/null); then
        return 1
    fi
    vol=$(echo "$stats" | awk '{print $2}')
    # Require a numeric (integer or decimal) value.
    if [[ "$vol" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$vol"
        return 0
    fi
    return 1
}

# Locate the pipeline's brainstem mask on disk. Searches the standard
# segmentation output locations and returns the first plausible match.
# Echoes the path on success (empty on failure); always returns 0.
_wmh_find_brainstem_mask() {
    local results="${RESULTS_DIR:-../mri_results}"
    local candidate
    # Ordered search patterns, most specific/authoritative first. The pipeline's
    # segmentation stage (segmentation.sh / hierarchical_joint_fusion.sh) writes
    # the binary mask as "<subject>_brainstem_mask.nii.gz" and the
    # intensity-named whole-brainstem volume as "<subject>_brainstem.nii.gz"; we
    # prefer the explicit binary mask. We intentionally do NOT fall back to a
    # single hemi-pons file (detailed_brainstem/*pons*) — that would silently
    # restrict WMH to one sub-region and grossly under-report.
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

# Report total and brainstem-restricted WMH volume for a binary lesion mask.
# Args: <tool_label> <binary_lesion_mask> <out_dir>
# Writes a brainstem-restricted mask (<tool>_brainstem_wmh.nii.gz) when a
# brainstem mask is found. Always returns 0 (reporting is non-fatal).
_wmh_report_volumes() {
    local tool_label="$1"
    local lesion_mask="$2"
    local out_dir="$3"

    if [ ! -f "$lesion_mask" ]; then
        log_formatted "WARNING" "${tool_label}: lesion mask not found for volume reporting: $lesion_mask"
        return 0
    fi

    # Whole-brain WMH volume (mm^3).
    local total_vol="N/A"
    if total_vol=$(_wmh_mask_volume_mm3 "$lesion_mask"); then
        log_formatted "INFO" "${tool_label}: whole-brain WMH volume = ${total_vol} mm^3"
    else
        log_formatted "WARNING" "${tool_label}: could not compute whole-brain WMH volume"
        total_vol="N/A"
    fi

    # Brainstem-restricted WMH.
    local brainstem_mask
    brainstem_mask="$(_wmh_find_brainstem_mask)"
    local brainstem_vol="N/A"
    local brainstem_wmh="${out_dir}/${tool_label}_brainstem_wmh.nii.gz"

    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        log_message "${tool_label}: intersecting lesion mask with brainstem mask: $brainstem_mask"

        # Binarise the brainstem mask (it may be a labelled/intensity volume) and
        # ensure it shares the WMH grid; resample to the WMH mask if needed.
        local bs_bin="${out_dir}/${tool_label}_brainstem_bin.nii.gz"
        if ! _wmh_fslmaths "${tool_label}: binarise brainstem mask" "$brainstem_mask" -bin "$bs_bin"; then
            bs_bin="$brainstem_mask"
        fi

        # Resample brainstem mask to WMH space if dimensions differ. The lesion
        # mask and brainstem mask routinely live on different grids, so a bare
        # fslmaths -mas would either fail on a dimension mismatch (silent drop)
        # or corrupt the geometry when dims match but sform differs. Mirror the
        # BIANCA/MARS modules' flirt resample (nearest-neighbour, sform-based).
        # '|| true' guards the pipes against pipefail/set -e on fslinfo failure.
        local wmh_dims bs_dims
        wmh_dims=$(fslinfo "$lesion_mask" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        bs_dims=$(fslinfo "$bs_bin" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        if [ -n "$wmh_dims" ] && [ -n "$bs_dims" ] && [ "$wmh_dims" != "$bs_dims" ] && command -v flirt >/dev/null 2>&1; then
            log_message "${tool_label}: brainstem mask grid ($bs_dims) != WMH grid ($wmh_dims); resampling to WMH space"
            local bs_resampled="${out_dir}/${tool_label}_brainstem_resampled.nii.gz"
            if flirt -in "$bs_bin" -ref "$lesion_mask" -out "$bs_resampled" \
                     -applyxfm -usesqform -interp nearestneighbour >/dev/null 2>&1; then
                _wmh_fslmaths "${tool_label}: resampled brainstem bin" "$bs_resampled" -bin "$bs_bin" || true
            else
                log_formatted "WARNING" "${tool_label}: failed to resample brainstem mask to WMH grid; intersection may fail"
            fi
        fi

        if _wmh_fslmaths "${tool_label}: brainstem WMH intersection" \
            "$lesion_mask" -mas "$bs_bin" -bin "$brainstem_wmh"; then
            if brainstem_vol=$(_wmh_mask_volume_mm3 "$brainstem_wmh"); then
                log_formatted "INFO" "${tool_label}: brainstem-restricted WMH volume = ${brainstem_vol} mm^3"
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

    # Persist a small machine-readable summary.
    local summary="${out_dir}/${tool_label}_wmh_summary.txt"
    {
        echo "tool=${tool_label}"
        echo "lesion_mask=${lesion_mask}"
        echo "whole_brain_wmh_mm3=${total_vol}"
        echo "brainstem_mask=${brainstem_mask:-none}"
        echo "brainstem_wmh_mask=${brainstem_wmh}"
        echo "brainstem_wmh_mm3=${brainstem_vol}"
    } > "$summary" 2>/dev/null || true
    log_message "${tool_label}: summary written to $summary"

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# LST-AI
# ──────────────────────────────────────────────────────────────────────────────

# Detect an available LST-AI back-end.
# Echoes one of: "cli" | "module" | "docker" | "" (none). Always returns 0.
_wmh_detect_lstai() {
    if command -v lst &>/dev/null; then
        echo "cli"
        return 0
    fi
    # Python module check via uv (Python 3.12.8) — never bare python. Use
    # --no-sync so a mere availability probe does not trigger a (potentially
    # slow / network-bound) environment resolve+sync just to test importability.
    if command -v uv &>/dev/null && uv run --no-sync python -c "import lst_ai" &>/dev/null; then
        echo "module"
        return 0
    fi
    if command -v docker &>/dev/null && \
       docker image inspect "${LSTAI_DOCKER_IMAGE:-jqmcginnis/lst-ai:latest}" &>/dev/null; then
        echo "docker"
        return 0
    fi
    echo ""
    return 0
}

# run_lstai_wmh <flair> <t1> [out_dir]
# Runs LST-AI to produce a lesion segmentation + probability mask + volume.
# Graceful non-fatal skip if disabled or LST-AI is not installed.
run_lstai_wmh() {
    log_message "=== run_lstai_wmh (LST-AI supervised WMH) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    if [ "${WMH_LSTAI_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "LST-AI WMH detection disabled (WMH_LSTAI_ENABLED=${WMH_LSTAI_ENABLED:-false}); skipping"
        return 0
    fi

    if [ -z "$flair_file" ] || [ -z "$t1_file" ]; then
        log_formatted "WARNING" "LST-AI: FLAIR and T1 are both required; skipping"
        return 0
    fi
    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "LST-AI: FLAIR file not found: $flair_file; skipping"
        return 0
    fi
    if [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "LST-AI: T1 file not found: $t1_file; skipping"
        return 0
    fi

    local backend
    backend="$(_wmh_detect_lstai)"
    if [ -z "$backend" ]; then
        log_formatted "WARNING" "LST-AI not found (no 'lst' CLI, no importable lst_ai module, no Docker image). Install via 'pip install lst-ai' or pull the Docker image; skipping LST-AI WMH detection (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "LST-AI back-end detected: $backend"

    [ -z "$out_dir" ] && out_dir="$(_wmh_default_out_dir "lst_ai")"
    mkdir -p "$out_dir"
    local temp_dir="${out_dir}/temp"
    mkdir -p "$temp_dir"

    local threshold="${LSTAI_THRESHOLD:-0.5}"
    local device="${LSTAI_DEVICE:-cpu}"

    log_message "LST-AI inputs: FLAIR=$flair_file T1=$t1_file"
    log_message "LST-AI output dir: $out_dir (threshold=$threshold, device=$device)"

    local rc=0
    case "$backend" in
        cli)
            lst --t1 "$t1_file" --flair "$flair_file" \
                --output "$out_dir" --temp "$temp_dir" \
                --device "$device" --threshold "$threshold" \
                --probability_map || rc=$?
            ;;
        module)
            # Invoke the module CLI through uv (Python 3.12.8), never bare python.
            uv run --no-sync python -m lst_ai --t1 "$t1_file" --flair "$flair_file" \
                --output "$out_dir" --temp "$temp_dir" \
                --device "$device" --threshold "$threshold" \
                --probability_map || rc=$?
            ;;
        docker)
            local image="${LSTAI_DOCKER_IMAGE:-jqmcginnis/lst-ai:latest}"
            # Mount input/output dirs; reference files by basename inside container.
            # Resolve absolute dirs without letting a failed cd abort the run
            # under the pipeline's set -e (|| true keeps the subshell non-fatal;
            # the emptiness check below converts failure into a graceful skip).
            local flair_dir t1_dir out_abs
            flair_dir="$( (cd "$(dirname "$flair_file")" && pwd) || true )"
            t1_dir="$( (cd "$(dirname "$t1_file")" && pwd) || true )"
            out_abs="$( (cd "$out_dir" && pwd) || true )"
            if [ -z "$flair_dir" ] || [ -z "$t1_dir" ] || [ -z "$out_abs" ]; then
                log_formatted "WARNING" "LST-AI (docker): could not resolve input/output directories; skipping"
                return 0
            fi
            docker run --rm \
                -v "${flair_dir}:/flair_in:ro" \
                -v "${t1_dir}:/t1_in:ro" \
                -v "${out_abs}:/out" \
                "$image" \
                --t1 "/t1_in/$(basename "$t1_file")" \
                --flair "/flair_in/$(basename "$flair_file")" \
                --output /out --temp /out/temp \
                --device "$device" --threshold "$threshold" \
                --probability_map || rc=$?
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "LST-AI exited with status $rc; skipping downstream LST-AI reporting (non-fatal)"
        return 0
    fi

    # Locate the produced lesion segmentation mask. LST-AI names vary by version
    # ("space-flair_seg-lst.nii.gz", "*lesion*", "*seg*"); search robustly.
    local lesion_mask=""
    local cand f
    for cand in \
        "${out_dir}/"*"seg-lst.nii.gz" \
        "${out_dir}/"*"lesion"*".nii.gz" \
        "${out_dir}/"*"seg"*".nii.gz"; do
        for f in $cand; do
            if [ -f "$f" ]; then
                lesion_mask="$f"
                break 2
            fi
        done
    done

    if [ -z "$lesion_mask" ]; then
        log_formatted "WARNING" "LST-AI completed but no lesion segmentation mask was found in $out_dir; skipping reporting"
        return 0
    fi
    log_formatted "SUCCESS" "LST-AI lesion segmentation: $lesion_mask"

    # Ensure a clean binary mask for volumetry and brainstem intersection.
    # If binarization fails we do NOT fall back to the raw mask: the matched
    # file could be a probability map, and counting every nonzero probability
    # voxel would massively overestimate WMH volume. Skip reporting instead.
    local lesion_bin="${out_dir}/lstai_lesion_bin.nii.gz"
    if ! _wmh_fslmaths "LST-AI: binarize lesion mask" "$lesion_mask" -bin "$lesion_bin"; then
        log_formatted "WARNING" "LST-AI: failed to binarize lesion mask ($lesion_mask); skipping reporting"
        return 0
    fi

    _wmh_report_volumes "lstai" "$lesion_bin" "$out_dir"

    log_formatted "SUCCESS" "LST-AI WMH detection complete"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# FreeSurfer SAMSEG lesion segmentation
# ──────────────────────────────────────────────────────────────────────────────

# Detect FreeSurfer SAMSEG availability. Returns 0 if available, 1 otherwise.
_wmh_detect_samseg() {
    if ! command -v run_samseg &>/dev/null; then
        return 1
    fi
    if [ -z "${FREESURFER_HOME:-}" ]; then
        return 1
    fi
    return 0
}

# run_samseg_wmh <flair> <t1> [out_dir]
# Runs FreeSurfer SAMSEG lesion segmentation (run_samseg --lesion ...), then
# thresholds the lesion posterior to a binary mask and reports volume.
# Graceful non-fatal skip if disabled or SAMSEG is not installed.
run_samseg_wmh() {
    log_message "=== run_samseg_wmh (FreeSurfer SAMSEG lesion segmentation) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    if [ "${WMH_SAMSEG_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "SAMSEG WMH detection disabled (WMH_SAMSEG_ENABLED=${WMH_SAMSEG_ENABLED:-false}); skipping"
        return 0
    fi

    if [ -z "$flair_file" ] || [ -z "$t1_file" ]; then
        log_formatted "WARNING" "SAMSEG: FLAIR and T1 are both required; skipping"
        return 0
    fi
    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "SAMSEG: FLAIR file not found: $flair_file; skipping"
        return 0
    fi
    if [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "SAMSEG: T1 file not found: $t1_file; skipping"
        return 0
    fi

    if ! _wmh_detect_samseg; then
        log_formatted "WARNING" "FreeSurfer SAMSEG not available (need 'run_samseg' on PATH and \$FREESURFER_HOME set). Install FreeSurfer >=7.x; skipping SAMSEG WMH detection (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "FreeSurfer SAMSEG detected (FREESURFER_HOME=$FREESURFER_HOME)"

    [ -z "$out_dir" ] && out_dir="$(_wmh_default_out_dir "samseg")"
    mkdir -p "$out_dir"

    local threshold="${SAMSEG_LESION_THRESHOLD:-0.3}"
    # Input order is T1 then FLAIR; lesion-mask-pattern "0 1" => no constraint on
    # T1, brighter-than-GM on FLAIR (lesions are bright on FLAIR).
    local mask_pattern="${SAMSEG_LESION_MASK_PATTERN:-0 1}"
    local threads="${MAX_CPU_INTENSIVE_JOBS:-1}"
    local extra_opts="${SAMSEG_EXTRA_OPTS:---pallidum-separate}"

    log_message "SAMSEG inputs: T1=$t1_file FLAIR=$flair_file"
    log_message "SAMSEG output dir: $out_dir (threshold=$threshold, mask-pattern='$mask_pattern', threads=$threads)"

    local rc=0
    # shellcheck disable=SC2086  # mask_pattern and extra_opts are intentionally word-split
    run_samseg \
        --input "$t1_file" "$flair_file" \
        --lesion \
        --lesion-mask-pattern $mask_pattern \
        --threshold "$threshold" \
        --threads "$threads" \
        $extra_opts \
        --output "$out_dir" || rc=$?

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "SAMSEG (run_samseg) exited with status $rc; skipping downstream SAMSEG reporting (non-fatal)"
        return 0
    fi

    # SAMSEG assigns lesion label 99 in seg.mgz. Extract a binary lesion mask.
    local seg_mgz="${out_dir}/seg.mgz"
    if [ ! -f "$seg_mgz" ]; then
        log_formatted "WARNING" "SAMSEG completed but seg.mgz not found in $out_dir; skipping reporting"
        return 0
    fi

    local lesion_bin="${out_dir}/samseg_lesion_bin.nii.gz"
    local lesion_label="${SAMSEG_LESION_LABEL:-99}"
    if command -v mri_binarize &>/dev/null; then
        # mri_binarize handles .mgz input directly and writes .nii.gz output.
        if ! mri_binarize --i "$seg_mgz" --match "$lesion_label" --o "$lesion_bin"; then
            log_formatted "WARNING" "SAMSEG: mri_binarize failed to extract lesion label $lesion_label; skipping reporting"
            return 0
        fi
    else
        # Fall back to converting to NIfTI then thresholding with fslmaths.
        # Use nearest-neighbour resampling and an integer datatype so the
        # discrete label values (incl. 99) are preserved exactly and not
        # rescaled/interpolated by mri_convert.
        local seg_nii="${out_dir}/seg.nii.gz"
        if command -v mri_convert &>/dev/null && mri_convert -rt nearest -odt int "$seg_mgz" "$seg_nii" &>/dev/null; then
            if ! _wmh_fslmaths "SAMSEG: extract lesion label $lesion_label" \
                "$seg_nii" -thr "$lesion_label" -uthr "$lesion_label" -bin "$lesion_bin"; then
                log_formatted "WARNING" "SAMSEG: failed to extract lesion mask via fslmaths; skipping reporting"
                return 0
            fi
        else
            log_formatted "WARNING" "SAMSEG: neither mri_binarize nor mri_convert available to extract lesion mask; skipping reporting"
            return 0
        fi
    fi

    log_formatted "SUCCESS" "SAMSEG lesion mask: $lesion_bin"
    _wmh_report_volumes "samseg" "$lesion_bin" "$out_dir"

    log_formatted "SUCCESS" "SAMSEG WMH detection complete"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Dispatcher
# ──────────────────────────────────────────────────────────────────────────────

# run_supervised_wmh_lst_samseg <flair> <t1> [out_dir]
# Runs whichever supervised WMH tools are enabled + available. Each back-end
# skips itself gracefully; this dispatcher never fails the pipeline.
run_supervised_wmh_lst_samseg() {
    log_message "=== run_supervised_wmh_lst_samseg (supervised WMH dispatcher) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    if [ "${WMH_LSTAI_ENABLED:-false}" != "true" ] && [ "${WMH_SAMSEG_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "No supervised WMH tools enabled (WMH_LSTAI_ENABLED / WMH_SAMSEG_ENABLED both false); skipping"
        return 0
    fi

    # The back-ends always return 0; the `|| log_formatted ...` is a defensive
    # guard so that even a future regression returning nonzero cannot abort the
    # pipeline under the inherited `set -e`, and is surfaced as a WARNING.
    run_lstai_wmh "$flair_file" "$t1_file" "$out_dir" || \
        log_formatted "WARNING" "LST-AI WMH stage reported a non-fatal failure"

    run_samseg_wmh "$flair_file" "$t1_file" "$out_dir" || \
        log_formatted "WARNING" "SAMSEG WMH stage reported a non-fatal failure"

    log_formatted "SUCCESS" "Supervised WMH (LST-AI + SAMSEG) dispatcher complete"
    return 0
}
