#!/usr/bin/env bash
#
# wmh_segcsvd.sh - Deep-learning white-matter-hyperintensity (WMH) detection via
#                  segcsvdWMH (AICONSlab).
#
# This module is a self-contained, sourceable add-on that wraps segcsvdWMH, a
# two-stage CNN tool for quantifying WMH in heterogeneous patient cohorts:
#   Gibson et al., "segcsvdWMH: A CNN-Based Tool for Quantifying WMH in
#   Heterogeneous Patient Cohorts," Human Brain Mapping 2024;45(18):e70104
#   (DOI 10.1002/hbm.70104).  Repo: https://github.com/AICONSlab/segcsvd
#
# segcsvdWMH is FLAIR-ONLY for the lesion CNN (T1 is used only for upstream
# preprocessing / ICV / SynthSeg).  It is distributed as code + pretrained
# weights, most conveniently as the AICONSlab container (Apptainer/Singularity
# .sif, or Docker).  The container entrypoint is 'segment_wmh', which consumes:
#     1) the subject FLAIR
#     2) a SynthSeg v2.0 (with CSF) parcellation of that subject
#     3) an output path
#   followed by fixed/tunable positional parameters:
#     1  "96,128"  <threshold>  1  <skip_mask_and_bias>  <cleanup>
# and writes:
#     seg_wmh.nii.gz       (WMH probability map, range [0,1])
#     thr_seg_wmh.nii.gz   (thresholded binary WMH mask, {0,1})
#
# The required SynthSeg parcellation is produced (when absent) with FreeSurfer's
# 'mri_synthseg --i <FLAIR|T1> --o <synthseg.nii.gz>'.  T1 is preferred as the
# SynthSeg input when available (better cortical/CSF parcellation for ICV), with
# graceful fallback to the FLAIR.
#
# Entry point:
#   run_segcsvd_wmh <flair> [t1] [out_dir]
#
# Integration hook (for the coordinator to wire into the analysis stage):
#   run_segcsvd_wmh "$orig_flair" "$orig_t1"
#
# The entry function degrades gracefully (non-fatal WARNING + return 0) whenever
# segcsvdWMH is disabled via config or unavailable (no container image / no
# importable module), and never crashes the pipeline.
#
# NOTE: This is a SOURCED module, not a standalone script.  Like the sibling
# WMH modules (wmh_bianca.sh, wmh_lst_samseg.sh) it does NOT enable
# `set -e -u -o pipefail` at the top, because those options would leak into the
# parent shell and turn every later command in pipeline.sh fatal.  The pipeline
# already runs under `set -e -u -o pipefail`; every function here tolerates those
# options and returns 0 on any tool-missing/disabled/failure path.
#

# Include guard
if [ -n "${_WMH_SEGCSVD_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_WMH_SEGCSVD_LOADED=1

# Lightweight environment guard (fast no-op during pipeline execution)
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"
# Load defaults if not already loaded. Resolve relative to this file so the
# module is sourceable from any CWD (the include guard makes this a no-op when
# config is already loaded by the pipeline).
if [ -z "${_DEFAULT_CONFIG_LOADED:-}" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../../config/default_config.sh"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

# Resolve a default output directory under RESULTS_DIR for the segcsvd results.
# Honors the standard module-dir convention when available.
_segcsvd_default_out_dir() {
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "wmh_supervised")"
    else
        base="${RESULTS_DIR:-../mri_results}/wmh_supervised"
        mkdir -p "$base"
    fi
    local dir="${base}/segcsvd"
    mkdir -p "$dir"
    echo "$dir"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_segcsvd_fslmaths() {
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
# fslstats -V prints "<nvoxels> <volume_mm3>"; field 2 is the volume. A
# successful run that yields a non-numeric/empty field 2 is treated as a failure
# so the caller does not record a blank value as if it were a real measurement.
_segcsvd_mask_volume_mm3() {
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

# Echo the cluster (connected-component) count of a binary mask, or 0 on
# failure. Uses FSL 'cluster' with 26-connectivity; the report has a header line
# plus one row per cluster, so cluster count = data rows. Never aborts.
_segcsvd_cluster_count() {
    local mask="$1"
    local n=0
    if command -v cluster >/dev/null 2>&1; then
        local report
        report=$(cluster --in="$mask" --thresh=0.5 --connectivity=26 2>/dev/null) || report=""
        if [ -n "$report" ]; then
            n=$(printf '%s\n' "$report" | tail -n +2 | grep -c . || true)
            [ -z "$n" ] && n=0
        fi
    fi
    echo "$n"
}

# Locate the pipeline's brainstem mask on disk. Searches the standard
# segmentation output locations and returns the first plausible match.
# Echoes the path on success (empty on failure); always returns 0.
#
# We prefer the explicit binary mask "<subject>_brainstem_mask.nii.gz" written
# by the segmentation stage, then the intensity-named whole-brainstem volume.
# We intentionally do NOT fall back to a single hemi-pons sub-region file — that
# would silently restrict WMH to one sub-region and grossly under-report.
_segcsvd_find_brainstem_mask() {
    local results="${RESULTS_DIR:-../mri_results}"
    local candidate
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

# Report total and brainstem-restricted WMH (cluster count + volume) for a
# binary lesion mask, and write a machine-readable summary.
# Args: <binary_lesion_mask> <out_dir> <probability_map> <threshold>
# Writes a brainstem-restricted mask (segcsvd_brainstem_wmh.nii.gz) when a
# brainstem mask is found. Always returns 0 (reporting is non-fatal).
_segcsvd_report() {
    local lesion_mask="$1"
    local out_dir="$2"
    local prob_map="${3:-}"
    local threshold="${4:-}"

    if [ ! -f "$lesion_mask" ]; then
        log_formatted "WARNING" "segcsvd: lesion mask not found for reporting: $lesion_mask"
        return 0
    fi

    # Whole-brain WMH.
    local total_vol="N/A"
    if total_vol=$(_segcsvd_mask_volume_mm3 "$lesion_mask"); then
        log_formatted "INFO" "segcsvd: whole-brain WMH volume = ${total_vol} mm^3"
    else
        log_formatted "WARNING" "segcsvd: could not compute whole-brain WMH volume"
        total_vol="N/A"
    fi
    local total_clusters
    total_clusters=$(_segcsvd_cluster_count "$lesion_mask")
    log_formatted "INFO" "segcsvd: whole-brain WMH clusters = ${total_clusters}"

    # Brainstem-restricted WMH.
    local brainstem_mask
    brainstem_mask="$(_segcsvd_find_brainstem_mask)"
    local brainstem_vol="N/A"
    local brainstem_clusters="N/A"
    local brainstem_wmh="${out_dir}/segcsvd_brainstem_wmh.nii.gz"

    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        log_message "segcsvd: intersecting lesion mask with brainstem mask: $brainstem_mask"
        # Binarise the brainstem mask first (it may be a labelled/intensity
        # volume) so the intersection is a clean AND of two binary masks.
        local bs_bin="${out_dir}/segcsvd_brainstem_bin.nii.gz"
        if ! _segcsvd_fslmaths "segcsvd: binarize brainstem mask" "$brainstem_mask" -bin "$bs_bin"; then
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
            log_message "segcsvd: brainstem mask grid ($bs_dims) != WMH grid ($wmh_dims); resampling to WMH space"
            local bs_resampled="${out_dir}/segcsvd_brainstem_resampled.nii.gz"
            if flirt -in "$bs_bin" -ref "$lesion_mask" -out "$bs_resampled" \
                     -applyxfm -usesqform -interp nearestneighbour >/dev/null 2>&1; then
                _segcsvd_fslmaths "segcsvd: resampled brainstem bin" "$bs_resampled" -bin "$bs_bin" || true
            else
                log_formatted "WARNING" "segcsvd: failed to resample brainstem mask to WMH grid; intersection may fail"
            fi
        fi

        if _segcsvd_fslmaths "segcsvd: brainstem WMH intersection" \
            "$lesion_mask" -mas "$bs_bin" -bin "$brainstem_wmh"; then
            if brainstem_vol=$(_segcsvd_mask_volume_mm3 "$brainstem_wmh"); then
                log_formatted "INFO" "segcsvd: brainstem-restricted WMH volume = ${brainstem_vol} mm^3"
            else
                log_formatted "WARNING" "segcsvd: could not compute brainstem WMH volume"
                brainstem_vol="N/A"
            fi
            brainstem_clusters=$(_segcsvd_cluster_count "$brainstem_wmh")
            log_formatted "INFO" "segcsvd: brainstem-restricted WMH clusters = ${brainstem_clusters}"
        else
            log_formatted "WARNING" "segcsvd: brainstem intersection failed"
        fi
    else
        log_formatted "WARNING" "segcsvd: no brainstem mask found; skipping brainstem-restricted WMH (run segmentation stage first)"
    fi

    # Persist a small machine-readable summary.
    local summary="${out_dir}/segcsvd_wmh_summary.txt"
    {
        echo "tool=segcsvd"
        echo "probability_map=${prob_map:-N/A}"
        echo "threshold=${threshold:-N/A}"
        echo "lesion_mask=${lesion_mask}"
        echo "whole_brain_wmh_mm3=${total_vol}"
        echo "whole_brain_wmh_clusters=${total_clusters}"
        echo "brainstem_mask=${brainstem_mask:-none}"
        echo "brainstem_wmh_mask=${brainstem_wmh}"
        echo "brainstem_wmh_mm3=${brainstem_vol}"
        echo "brainstem_wmh_clusters=${brainstem_clusters}"
    } > "$summary" 2>/dev/null || true
    log_message "segcsvd: summary written to $summary"

    return 0
}

# Detect an available segcsvd back-end.
# Echoes one of: "apptainer" | "singularity" | "docker" | "module" | "" (none).
# Always returns 0. Apptainer/Singularity are preferred (the AICONSlab tool is
# primarily distributed as a .sif image); Docker next; an importable Python
# module last.
_segcsvd_detect_backend() {
    local image="${SEGCSVD_CONTAINER_IMAGE:-}"

    # Apptainer / Singularity: need a runner AND a .sif image path that exists.
    if [ -n "$image" ] && [ -f "$image" ]; then
        if command -v apptainer &>/dev/null; then
            echo "apptainer"
            return 0
        fi
        if command -v singularity &>/dev/null; then
            echo "singularity"
            return 0
        fi
    fi

    # Docker: need the daemon/CLI AND the image to be present locally.
    if command -v docker &>/dev/null; then
        local docker_image="${SEGCSVD_DOCKER_IMAGE:-segcsvd_rc03}"
        if docker image inspect "$docker_image" &>/dev/null; then
            echo "docker"
            return 0
        fi
    fi

    # Native Python module check via uv (Python 3.12.8) — never bare python.
    # --no-sync so a mere availability probe does not trigger a slow env resolve.
    if [ -n "${SEGCSVD_PY_MODULE:-}" ] && command -v uv &>/dev/null && \
       uv run --no-sync python -c "import ${SEGCSVD_PY_MODULE}" &>/dev/null; then
        echo "module"
        return 0
    fi

    echo ""
    return 0
}

# Detect FreeSurfer's mri_synthseg, required to build the SynthSeg parcellation
# segcsvdWMH consumes. Returns 0 if available, 1 otherwise.
_segcsvd_detect_synthseg() {
    command -v mri_synthseg &>/dev/null
}

# Generate (or reuse) a SynthSeg parcellation for segcsvdWMH.
# Args: <synthseg_input_image> <synthseg_out.nii.gz>
# Echoes nothing; returns 0 on success (output exists), non-zero otherwise.
_segcsvd_make_synthseg() {
    local in_image="$1"
    local synth_out="$2"

    # Reuse a user-supplied / previously-computed SynthSeg if configured.
    if [ -n "${SEGCSVD_SYNTHSEG_FILE:-}" ] && [ -f "${SEGCSVD_SYNTHSEG_FILE}" ]; then
        log_message "segcsvd: using preexisting SynthSeg parcellation: ${SEGCSVD_SYNTHSEG_FILE}"
        cp -f "${SEGCSVD_SYNTHSEG_FILE}" "$synth_out" 2>/dev/null && return 0
        # If the copy fails, fall through to (re)generation.
    fi
    if [ -f "$synth_out" ]; then
        log_message "segcsvd: reusing existing SynthSeg parcellation: $synth_out"
        return 0
    fi

    if ! _segcsvd_detect_synthseg; then
        log_formatted "WARNING" "segcsvd: FreeSurfer 'mri_synthseg' not found; cannot build the required SynthSeg parcellation. Set SEGCSVD_SYNTHSEG_FILE to a precomputed parcellation, or install FreeSurfer >=7.x; skipping (non-fatal)."
        return 1
    fi

    log_message "segcsvd: generating SynthSeg parcellation from: $in_image"
    local rc=0
    # SynthSeg v2 emits CSF parcellation by default; --robust/--parc are optional.
    # shellcheck disable=SC2086  # SEGCSVD_SYNTHSEG_EXTRA_OPTS is intentionally word-split
    mri_synthseg --i "$in_image" --o "$synth_out" ${SEGCSVD_SYNTHSEG_EXTRA_OPTS:-} || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$synth_out" ]; then
        log_formatted "WARNING" "segcsvd: mri_synthseg failed (status $rc) or produced no output; skipping (non-fatal)"
        return 1
    fi
    return 0
}

# Resolve an absolute directory path without letting a failed cd abort the run
# under the pipeline's set -e. Echoes the abs dir (empty on failure).
_segcsvd_abs_dir() {
    ( cd "$(dirname "$1")" && pwd ) 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Main entry point
# ──────────────────────────────────────────────────────────────────────────────

# run_segcsvd_wmh <flair> [t1] [out_dir]
#
# Arguments:
#   $1  FLAIR image for the subject (segcsvdWMH is FLAIR-only for the CNN)
#   $2  (optional) T1 image — used only as the preferred SynthSeg input (ICV)
#   $3  (optional) output directory (default: RESULTS_DIR/wmh_supervised/segcsvd)
#
# Behaviour:
#   - Non-fatal graceful skip (return 0, never 'exit') when:
#       * WMH_SEGCSVD_ENABLED is not "true"
#       * required FLAIR input is missing
#       * no segcsvd back-end (container image / module) is available
#       * the SynthSeg parcellation cannot be produced
#       * segcsvd execution fails
#   - On success: writes a WMH probability map + thresholded binary mask, reports
#     whole-brain cluster count + volume, intersects with the pipeline's
#     brainstem mask to report brainstem-restricted WMH separately, and writes a
#     machine-readable summary (segcsvd_wmh_summary.txt).
run_segcsvd_wmh() {
    log_message "=== run_segcsvd_wmh (segcsvdWMH deep-learning WMH) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    # --- Feature flag --------------------------------------------------------
    if [ "${WMH_SEGCSVD_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "segcsvdWMH detection disabled (WMH_SEGCSVD_ENABLED=${WMH_SEGCSVD_ENABLED:-false}); skipping"
        return 0
    fi

    # --- Argument validation -------------------------------------------------
    if [ -z "$flair_file" ]; then
        log_formatted "WARNING" "segcsvd: FLAIR is required; skipping"
        return 0
    fi
    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "segcsvd: FLAIR file not found: $flair_file; skipping"
        return 0
    fi
    if [ -n "$t1_file" ] && [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "segcsvd: T1 supplied but not found ($t1_file); will use FLAIR for SynthSeg"
        t1_file=""
    fi

    # --- Back-end availability (graceful skip) -------------------------------
    local backend
    backend="$(_segcsvd_detect_backend)"
    if [ -z "$backend" ]; then
        log_formatted "WARNING" "segcsvdWMH not found. Provide the AICONSlab container and point SEGCSVD_CONTAINER_IMAGE at the .sif (Apptainer/Singularity) or pull the Docker image (SEGCSVD_DOCKER_IMAGE, default 'segcsvd_rc03'); see https://github.com/AICONSlab/segcsvd . Skipping segcsvd WMH detection (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "segcsvd back-end detected: $backend"

    # --- Workspace -----------------------------------------------------------
    [ -z "$out_dir" ] && out_dir="$(_segcsvd_default_out_dir)"
    mkdir -p "$out_dir" || {
        log_formatted "WARNING" "segcsvd: could not create output directory: $out_dir; skipping"
        return 0
    }

    local threshold="${SEGCSVD_THRESHOLD:-0.35}"
    if ! [[ "$threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_formatted "WARNING" "segcsvd: SEGCSVD_THRESHOLD='$threshold' is not numeric; falling back to 0.35"
        threshold=0.35
    fi
    local patch_size="${SEGCSVD_PATCH_SIZE:-96,128}"
    local skip_mask_and_bias="${SEGCSVD_SKIP_MASK_AND_BIAS:-false}"
    local cleanup="${SEGCSVD_CLEANUP:-true}"

    # --- SynthSeg parcellation (required input) ------------------------------
    # Prefer T1 as the SynthSeg input (better cortical/CSF parcellation / ICV);
    # fall back to the FLAIR when T1 is unavailable.
    local synth_input="$flair_file"
    if [ -n "$t1_file" ]; then
        synth_input="$t1_file"
        log_message "segcsvd: using T1 as SynthSeg input: $t1_file"
    else
        log_message "segcsvd: no T1 available; using FLAIR as SynthSeg input"
    fi
    local synth_out="${out_dir}/segcsvd_synthseg.nii.gz"
    if ! _segcsvd_make_synthseg "$synth_input" "$synth_out"; then
        log_formatted "WARNING" "segcsvd: SynthSeg parcellation unavailable; skipping segcsvd WMH detection (non-fatal)"
        return 0
    fi

    # --- Resolve absolute dirs for container bind mounts ---------------------
    # The container references files by basename inside fixed mount points, so
    # FLAIR and SynthSeg must be reachable from a single input bind. Stage both
    # into a dedicated input dir to guarantee a single, writable, absolute path.
    local in_dir="${out_dir}/segcsvd_inputs"
    mkdir -p "$in_dir" || {
        log_formatted "WARNING" "segcsvd: could not create input staging dir: $in_dir; skipping"
        return 0
    }
    local flair_bn="flair.nii.gz"
    local synth_bn="synthseg.nii.gz"
    cp -f "$flair_file" "${in_dir}/${flair_bn}" 2>/dev/null || {
        log_formatted "WARNING" "segcsvd: failed to stage FLAIR into $in_dir; skipping"
        return 0
    }
    cp -f "$synth_out" "${in_dir}/${synth_bn}" 2>/dev/null || {
        log_formatted "WARNING" "segcsvd: failed to stage SynthSeg into $in_dir; skipping"
        return 0
    }

    local in_abs out_abs
    in_abs="$(_segcsvd_abs_dir "${in_dir}/.")"
    out_abs="$(_segcsvd_abs_dir "${out_dir}/.")"
    if [ -z "$in_abs" ] || [ -z "$out_abs" ]; then
        log_formatted "WARNING" "segcsvd: could not resolve absolute input/output directories; skipping"
        return 0
    fi

    # segcsvd writes seg_wmh.nii.gz / thr_seg_wmh.nii.gz derived from this base.
    local out_bn="seg_wmh.nii.gz"

    log_message "segcsvd inputs: FLAIR=$flair_file SynthSeg=$synth_out"
    log_message "segcsvd output dir: $out_dir (threshold=$threshold, patch=$patch_size, skip_mask_and_bias=$skip_mask_and_bias, cleanup=$cleanup)"

    # --- Run segcsvdWMH ------------------------------------------------------
    local rc=0
    case "$backend" in
        apptainer|singularity)
            local runner="apptainer"
            [ "$backend" = "singularity" ] && runner="singularity"
            local sif="${SEGCSVD_CONTAINER_IMAGE}"
            log_message "Running ($runner): $sif segment_wmh ..."
            "$runner" run \
                --bind "${in_abs}:/indir,${out_abs}:/outdir" --pwd / \
                "$sif" segment_wmh \
                "/indir/${flair_bn}" \
                "/indir/${synth_bn}" \
                "/outdir/${out_bn}" \
                1 \
                "$patch_size" \
                "$threshold" \
                1 \
                "$skip_mask_and_bias" \
                "$cleanup" || rc=$?
            ;;
        docker)
            local docker_image="${SEGCSVD_DOCKER_IMAGE:-segcsvd_rc03}"
            log_message "Running (docker): $docker_image segment_wmh ..."
            docker run --rm \
                -v "${in_abs}:/indir" \
                -v "${out_abs}:/outdir" \
                -w / \
                "$docker_image" \
                segment_wmh \
                "/indir/${flair_bn}" \
                "/indir/${synth_bn}" \
                "/outdir/${out_bn}" \
                1 \
                "$patch_size" \
                "$threshold" \
                1 \
                "$skip_mask_and_bias" \
                "$cleanup" || rc=$?
            ;;
        module)
            # Native Python entrypoint via uv (Python 3.12.8), never bare python.
            log_message "Running (module): uv run python -m ${SEGCSVD_PY_MODULE} ..."
            # shellcheck disable=SC2086  # SEGCSVD_MODULE_EXTRA_OPTS is intentionally word-split
            uv run --no-sync python -m "${SEGCSVD_PY_MODULE}" \
                "$flair_file" \
                "$synth_out" \
                "${out_dir}/${out_bn}" \
                1 \
                "$patch_size" \
                "$threshold" \
                1 \
                "$skip_mask_and_bias" \
                "$cleanup" ${SEGCSVD_MODULE_EXTRA_OPTS:-} || rc=$?
            ;;
    esac

    # Remove the input staging copies (full-size NIfTI duplicates of the FLAIR +
    # SynthSeg) now that the container has consumed them; the originals and the
    # outputs are preserved elsewhere. Gated on SEGCSVD_CLEANUP so users can keep
    # them for debugging. Failure to clean up is never fatal.
    if [ "${SEGCSVD_CLEANUP:-true}" = "true" ] && [ -n "$in_dir" ] && [ -d "$in_dir" ]; then
        rm -rf "$in_dir" 2>/dev/null || log_formatted "WARNING" "segcsvd: could not remove input staging dir: $in_dir"
    fi

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "segcsvd (segment_wmh) exited with status $rc; skipping downstream reporting (non-fatal)"
        return 0
    fi

    # --- Locate outputs ------------------------------------------------------
    # segcsvd writes seg_wmh.nii.gz (probability) and thr_seg_wmh.nii.gz (binary)
    # into the output dir. Names can vary slightly by release; search robustly.
    local prob_map=""
    local cand f
    for cand in \
        "${out_dir}/seg_wmh.nii.gz" \
        "${out_dir}/"*"seg_wmh.nii.gz"; do
        for f in $cand; do
            # Skip the thresholded file when matching the probability map.
            case "$(basename "$f")" in thr_*) continue ;; esac
            if [ -f "$f" ]; then
                prob_map="$f"
                break 2
            fi
        done
    done

    local thr_mask=""
    for cand in \
        "${out_dir}/thr_seg_wmh.nii.gz" \
        "${out_dir}/"*"thr_seg_wmh.nii.gz" \
        "${out_dir}/thr_"*".nii.gz"; do
        for f in $cand; do
            if [ -f "$f" ]; then
                thr_mask="$f"
                break 2
            fi
        done
    done

    if [ -z "$prob_map" ] && [ -z "$thr_mask" ]; then
        log_formatted "WARNING" "segcsvd completed but no probability map or thresholded mask was found in $out_dir; skipping reporting"
        return 0
    fi
    [ -n "$prob_map" ] && log_formatted "SUCCESS" "segcsvd WMH probability map: $prob_map"

    # --- Derive a clean binary WMH mask --------------------------------------
    # Prefer the container's thresholded mask. If it is missing, threshold the
    # probability map ourselves. Always binarise so volumetry/clustering count
    # voxels, not probabilities.
    local lesion_bin="${out_dir}/segcsvd_wmh_bin.nii.gz"
    if [ -n "$thr_mask" ]; then
        if ! _segcsvd_fslmaths "segcsvd: binarize thresholded mask" "$thr_mask" -bin "$lesion_bin"; then
            log_formatted "WARNING" "segcsvd: failed to binarize thresholded mask ($thr_mask); skipping reporting"
            return 0
        fi
    elif [ -n "$prob_map" ]; then
        log_message "segcsvd: no thresholded mask found; thresholding probability map at $threshold"
        if ! _segcsvd_fslmaths "segcsvd: threshold probability map" "$prob_map" -thr "$threshold" -bin "$lesion_bin"; then
            log_formatted "WARNING" "segcsvd: failed to threshold probability map ($prob_map); skipping reporting"
            return 0
        fi
    fi
    log_formatted "SUCCESS" "segcsvd binary WMH mask: $lesion_bin"

    _segcsvd_report "$lesion_bin" "$out_dir" "${prob_map:-N/A}" "$threshold"

    log_formatted "SUCCESS" "segcsvdWMH detection complete"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Exports
# ──────────────────────────────────────────────────────────────────────────────
export -f _segcsvd_default_out_dir
export -f _segcsvd_fslmaths
export -f _segcsvd_mask_volume_mm3
export -f _segcsvd_cluster_count
export -f _segcsvd_find_brainstem_mask
export -f _segcsvd_report
export -f _segcsvd_detect_backend
export -f _segcsvd_detect_synthseg
export -f _segcsvd_make_synthseg
export -f _segcsvd_abs_dir
export -f run_segcsvd_wmh

log_message "WMH segcsvd module loaded"
