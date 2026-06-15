#!/usr/bin/env bash
#
# wmh_mars.sh - Deep-learning white-matter-hyperintensity (WMH) detection via MARS-WMH
#
# This module is a self-contained, sourceable add-on that wraps MARS-WMH, the
# deep-learning (nnU-Net / MD-GRU) WMH segmentation tool from the Medical Image
# Analysis Center (MIAC) described in:
#
#   Gesierich B, et al. "Technical and clinical validation of a novel deep
#   learning-based WMH segmentation tool." Cerebral Circulation - Cognition and
#   Behavior 2025;9:100393.  DOI: 10.1016/j.cccb.2025.100393
#   Code:    https://github.com/miac-research/MARS-WMH
#   Weights: Zenodo (downloaded by the container on first run)
#
# MARS-WMH is, at the time of writing, the best-validated WMH tool in the
# literature for scan-rescan reproducibility, inter-scanner robustness, and
# longitudinal stability.  It takes co-registered FLAIR + T1 and produces a
# whole-brain WMH probability map / binary mask.  This module additionally
# intersects that mask with the pipeline's brainstem mask to report a
# brainstem-restricted WMH burden separately.  When the optional MARS-brainstem
# tool (https://github.com/miac-research/dl-brainstem) container is available it
# is used preferentially to define the brainstem ROI; otherwise the module falls
# back to the existing pipeline brainstem mask (*brainstem*mask*.nii.gz).
#
# !! LICENSE !!  MARS-WMH (and MARS-brainstem) are distributed under a
# NON-COMMERCIAL license.  They are NOT part of the core pipeline dependency set
# and are NOT installed by `uv sync`.  Enabling this module and pulling the
# containers is the operator's responsibility and is subject to that license.
#
# Distribution: prebuilt Docker / Apptainer (Singularity) containers.  This
# module detects, in order: a Docker image, an Apptainer/Singularity image
# (.sif), or a native `mars-wmh` CLI on PATH.  Absence of all three is a
# graceful, non-fatal skip (WARNING + return 0) so it never aborts the pipeline.
#
# Entry point (wire from the analysis stage):
#   run_mars_wmh "<flair.nii.gz>" "<t1.nii.gz>" [<out_dir>]
#
# NOTE: This is a SOURCED module, not a standalone script.  Like the sibling WMH
# modules (wmh_bianca.sh, wmh_lst_samseg.sh) it does NOT enable
# `set -e -u -o pipefail` at the top, because those options would leak into the
# parent shell and turn every later command in pipeline.sh fatal.  The pipeline
# already runs under `set -e -u -o pipefail`; every function here tolerates those
# options and returns 0 on any tool-missing / disabled / failure path.
#

# Include guard - prevent redundant re-sourcing by modules
if [ -n "${_WMH_MARS_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_WMH_MARS_LOADED=1

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

# Resolve a default output directory under RESULTS_DIR for MARS-WMH results.
# Honors the standard module-dir convention when available.
_mars_default_out_dir() {
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "wmh_mars")"
    else
        base="${RESULTS_DIR:-../mri_results}/wmh_mars"
        mkdir -p "$base"
    fi
    echo "$base"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_mars_fslmaths() {
    local description="$1"
    shift
    if declare -F safe_fslmaths >/dev/null 2>&1; then
        safe_fslmaths "$description" "$@"
    else
        log_message "$description (safe_fslmaths unavailable, using fslmaths): fslmaths $*"
        fslmaths "$@"
    fi
}

# Resolve the absolute directory CONTAINING a file, without aborting under set
# -e. Echoes the absolute dir on success, empty on failure; always returns 0.
# NB: this takes a FILE path and returns its parent dir (via dirname). To get a
# DIRECTORY's own absolute path, callers must pass "<dir>/." (the trailing "/."
# is load-bearing: dirname strips it, leaving the dir itself). See the docker
# branches, which mount "${out_dir}/." etc.
_mars_abs_dir() {
    local path="$1"
    ( cd "$(dirname "$path")" >/dev/null 2>&1 && pwd ) || true
}

# Report cluster count and total volume (mm^3) of a binary mask.
# Usage: _mars_report_wmh_stats <binary_mask.nii.gz> <label>
# Always returns 0 (reporting is non-fatal).
_mars_report_wmh_stats() {
    local mask="$1"
    local label="${2:-WMH}"

    if [ ! -f "$mask" ]; then
        log_formatted "WARNING" "MARS-WMH: report stats - mask not found: $mask"
        return 0
    fi

    # Total volume in voxels and mm^3. fslstats -V => "<nvoxels> <volume_mm3>".
    local vol_stats n_voxels volume_mm3
    vol_stats=$(fslstats "$mask" -V 2>/dev/null || echo "0 0")
    n_voxels=$(echo "$vol_stats" | awk '{print $1}')
    volume_mm3=$(echo "$vol_stats" | awk '{print $2}')

    # Cluster count via FSL 'cluster' (connected components). The table has a
    # header line plus one row per cluster, so cluster count = data rows.
    local n_clusters=0
    if command -v cluster >/dev/null 2>&1; then
        local cluster_report
        cluster_report=$(cluster --in="$mask" --thresh=0.5 --connectivity=26 2>/dev/null) || cluster_report=""
        if [ -n "$cluster_report" ]; then
            n_clusters=$(printf '%s\n' "$cluster_report" | tail -n +2 | grep -c . || true)
            [ -z "$n_clusters" ] && n_clusters=0
        fi
    fi

    log_formatted "INFO" "MARS-WMH ${label}: clusters=${n_clusters}, voxels=${n_voxels}, volume=${volume_mm3} mm^3"
    return 0
}

# Locate the pipeline's brainstem / posterior-fossa mask in the results tree.
# Echoes the path to the first match (stdout); returns 0 if found, 1 otherwise.
# All diagnostic output goes via the logging helpers (stderr) so the caller can
# safely capture stdout.
_mars_find_brainstem_mask() {
    local results_dir="${RESULTS_DIR:-.}"

    # Search the conventional segmentation locations first, then fall back to a
    # broad search. Prefer explicit *_mask files over intensity maps.
    local search_dirs=(
        "${results_dir}/segmentation/brainstem"
        "${results_dir}/segmentation/detailed_brainstem"
        "${results_dir}/segmentation"
        "${results_dir}/comprehensive_analysis/original_space"
        "${results_dir}"
    )

    local dir found
    for dir in "${search_dirs[@]}"; do
        [ -d "$dir" ] || continue
        # '|| true' guards against SIGPIPE/pipefail from 'find | head' under
        # set -e: on a large tree 'head -1' closes the pipe early, find dies
        # with exit 141, and pipefail would otherwise abort this function.
        found=$(find "$dir" -name "*brainstem*mask*.nii.gz" -type f 2>/dev/null | head -1 || true)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    done

    # Broader fallback: any *brainstem*.nii.gz (a labelled/intensity volume can
    # still be binarised downstream).
    for dir in "${search_dirs[@]}"; do
        [ -d "$dir" ] || continue
        found=$(find "$dir" -name "*brainstem*.nii.gz" -type f 2>/dev/null | head -1 || true)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    done

    return 1
}

# ----------------------------------------------------------------------------
# Back-end detection
# ----------------------------------------------------------------------------

# Detect an available MARS-WMH back-end.
# Echoes one of: "docker" | "apptainer" | "cli" | "" (none). Always returns 0.
# Honors MARS_WMH_BACKEND when set to force a specific back-end.
_mars_detect_wmh() {
    local forced="${MARS_WMH_BACKEND:-auto}"

    if [ "$forced" = "docker" ] || [ "$forced" = "auto" ]; then
        if command -v docker >/dev/null 2>&1 && \
           docker image inspect "${MARS_WMH_DOCKER_IMAGE:-miac/mars-wmh:latest}" >/dev/null 2>&1; then
            echo "docker"; return 0
        fi
        [ "$forced" = "docker" ] && { echo ""; return 0; }
    fi

    if [ "$forced" = "apptainer" ] || [ "$forced" = "auto" ]; then
        # An Apptainer/Singularity .sif image plus a runner on PATH.
        if [ -n "${MARS_WMH_SIF:-}" ] && [ -f "${MARS_WMH_SIF}" ] && \
           { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
            echo "apptainer"; return 0
        fi
        [ "$forced" = "apptainer" ] && { echo ""; return 0; }
    fi

    if [ "$forced" = "cli" ] || [ "$forced" = "auto" ]; then
        if command -v "${MARS_WMH_CLI:-mars-wmh}" >/dev/null 2>&1; then
            echo "cli"; return 0
        fi
        [ "$forced" = "cli" ] && { echo ""; return 0; }
    fi

    echo ""
    return 0
}

# Detect an available MARS-brainstem back-end (optional ROI helper).
# Echoes one of: "docker" | "apptainer" | "cli" | "" (none). Always returns 0.
_mars_detect_brainstem() {
    if command -v docker >/dev/null 2>&1 && \
       docker image inspect "${MARS_BRAINSTEM_DOCKER_IMAGE:-miac/dl-brainstem:latest}" >/dev/null 2>&1; then
        echo "docker"; return 0
    fi
    if [ -n "${MARS_BRAINSTEM_SIF:-}" ] && [ -f "${MARS_BRAINSTEM_SIF}" ] && \
       { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
        echo "apptainer"; return 0
    fi
    if command -v "${MARS_BRAINSTEM_CLI:-mars-brainstem}" >/dev/null 2>&1; then
        echo "cli"; return 0
    fi
    echo ""
    return 0
}

# Locate the raw WMH segmentation/probability file produced by MARS-WMH in a
# directory. MARS-WMH naming may vary by version; search robustly. Echoes the
# path on success (empty otherwise); always returns 0.
#
# IMPORTANT: this module writes its OWN derived products into the same out_dir
# (mars_wmh_thr*_bin.nii.gz, mars_wmh_brainstem.nii.gz, mars_brainstem_*.nii.gz).
# On a re-run/resume those would match the globs below and, sorting before the
# real tool output, be mistaken for it - silently feeding a brainstem-restricted
# mask back in as the whole-brain input. We therefore SKIP any basename starting
# with our "mars_" prefix so only genuine tool outputs are considered.
_mars_find_output() {
    local out_dir="$1"
    local cand f base
    for cand in \
        "${out_dir}/"*"wmh"*"mask"*".nii.gz" \
        "${out_dir}/"*"wmh"*"seg"*".nii.gz" \
        "${out_dir}/"*"wmh"*".nii.gz" \
        "${out_dir}/"*"lesion"*".nii.gz" \
        "${out_dir}/"*"seg"*".nii.gz" \
        "${out_dir}/"*"prob"*".nii.gz"; do
        for f in $cand; do
            [ -f "$f" ] || continue
            base="$(basename "$f")"
            # Skip this module's own derived outputs (mars_* prefix).
            case "$base" in
                mars_*) continue ;;
            esac
            echo "$f"
            return 0
        done
    done
    echo ""
    return 0
}

# ----------------------------------------------------------------------------
# Optional MARS-brainstem ROI
# ----------------------------------------------------------------------------

# Try to produce a brainstem ROI mask for the given T1 using MARS-brainstem.
# Args: <t1> <out_dir>
# Echoes the path to a binarised brainstem ROI on success (empty otherwise);
# always returns 0. Honors an explicit pre-existing MARS_BRAINSTEM_ROI.
_mars_make_brainstem_roi() {
    local t1_file="$1"
    local out_dir="$2"

    # Operator-supplied ROI takes precedence.
    if [ -n "${MARS_BRAINSTEM_ROI:-}" ] && [ -f "${MARS_BRAINSTEM_ROI}" ]; then
        log_message "MARS-brainstem: using operator-supplied ROI: ${MARS_BRAINSTEM_ROI}"
        local roi_bin="${out_dir}/mars_brainstem_roi_bin.nii.gz"
        if _mars_fslmaths "MARS-brainstem ROI binarise" "${MARS_BRAINSTEM_ROI}" -bin "$roi_bin"; then
            echo "$roi_bin"; return 0
        fi
        echo "${MARS_BRAINSTEM_ROI}"; return 0
    fi

    if [ "${MARS_BRAINSTEM_ENABLED:-false}" != "true" ]; then
        log_message "MARS-brainstem ROI generation disabled (MARS_BRAINSTEM_ENABLED=${MARS_BRAINSTEM_ENABLED:-false})"
        echo ""; return 0
    fi

    if [ -z "$t1_file" ] || [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "MARS-brainstem: T1 not available; cannot generate ROI"
        echo ""; return 0
    fi

    local backend
    backend="$(_mars_detect_brainstem)"
    if [ -z "$backend" ]; then
        log_formatted "WARNING" "MARS-brainstem container/CLI not found; will fall back to pipeline brainstem mask (non-fatal)"
        echo ""; return 0
    fi
    log_formatted "INFO" "MARS-brainstem back-end detected: $backend"

    local bs_dir="${out_dir}/brainstem"
    mkdir -p "$bs_dir"

    local rc=0
    case "$backend" in
        docker)
            local image="${MARS_BRAINSTEM_DOCKER_IMAGE:-miac/dl-brainstem:latest}"
            local t1_dir bs_abs
            t1_dir="$(_mars_abs_dir "$t1_file")"
            bs_abs="$(_mars_abs_dir "${bs_dir}/.")"
            if [ -z "$t1_dir" ] || [ -z "$bs_abs" ]; then
                log_formatted "WARNING" "MARS-brainstem (docker): could not resolve directories; skipping ROI"
                echo ""; return 0
            fi
            # shellcheck disable=SC2086  # MARS_BRAINSTEM_DOCKER_OPTS is intentionally word-split
            docker run --rm ${MARS_BRAINSTEM_DOCKER_OPTS:-} \
                -v "${t1_dir}:/input:ro" \
                -v "${bs_abs}:/output" \
                "$image" \
                --t1 "/input/$(basename "$t1_file")" \
                --output /output || rc=$?
            ;;
        apptainer)
            local runner="apptainer"
            command -v apptainer >/dev/null 2>&1 || runner="singularity"
            # shellcheck disable=SC2086  # MARS_BRAINSTEM_APPTAINER_OPTS is intentionally word-split
            "$runner" run ${MARS_BRAINSTEM_APPTAINER_OPTS:-} \
                "${MARS_BRAINSTEM_SIF}" \
                --t1 "$t1_file" \
                --output "$bs_dir" || rc=$?
            ;;
        cli)
            "${MARS_BRAINSTEM_CLI:-mars-brainstem}" \
                --t1 "$t1_file" \
                --output "$bs_dir" || rc=$?
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "MARS-brainstem exited with status $rc; falling back to pipeline brainstem mask (non-fatal)"
        echo ""; return 0
    fi

    # Locate a brainstem mask in the output. We deliberately do NOT fall back to
    # an unconstrained "${bs_dir}/*.nii.gz" glob: MARS-brainstem may also emit
    # intermediates (skull-stripped/resampled T1, probability maps) and picking a
    # non-mask volume would binarise to a near-whole-brain ROI, silently
    # inflating the "brainstem-restricted" WMH burden. Require a brainstem/mask
    # name; if none matches we fall back to the pipeline brainstem mask instead.
    local roi cand f
    for cand in \
        "${bs_dir}/"*"brainstem"*"mask"*".nii.gz" \
        "${bs_dir}/"*"brainstem"*".nii.gz" \
        "${bs_dir}/"*"mask"*".nii.gz"; do
        for f in $cand; do
            if [ -f "$f" ]; then roi="$f"; break 2; fi
        done
    done

    if [ -z "${roi:-}" ]; then
        log_formatted "WARNING" "MARS-brainstem completed but no ROI mask found in $bs_dir; falling back to pipeline brainstem mask"
        echo ""; return 0
    fi

    local roi_bin="${out_dir}/mars_brainstem_roi_bin.nii.gz"
    if _mars_fslmaths "MARS-brainstem ROI binarise" "$roi" -bin "$roi_bin"; then
        log_formatted "SUCCESS" "MARS-brainstem ROI: $roi_bin"
        echo "$roi_bin"; return 0
    fi
    echo "$roi"; return 0
}

# ----------------------------------------------------------------------------
# Main entry point
# ----------------------------------------------------------------------------

# run_mars_wmh - Deep-learning WMH segmentation for one subject (FLAIR + T1).
#
# Usage:
#   run_mars_wmh <flair.nii.gz> <t1.nii.gz> [<out_dir>]
#
# Arguments:
#   $1  FLAIR image (co-registered with T1)
#   $2  T1 image
#   $3  (optional) output directory; defaults to RESULTS_DIR/wmh_mars
#
# Behaviour:
#   - Non-fatal graceful skip (return 0, never 'exit') when:
#       * WMH_MARS_ENABLED is not "true"
#       * required inputs (FLAIR, T1) are missing
#       * no MARS-WMH Docker/Apptainer image or CLI is available
#       * the tool itself fails or produces no output
#   - On success: writes a binary whole-brain WMH mask, a brainstem-restricted
#     WMH mask (using a MARS-brainstem ROI if available, else the pipeline
#     brainstem mask), reports cluster count + volume for both, and writes a
#     machine-readable summary.
#
# LICENSE: MARS-WMH is NON-COMMERCIAL. See module header.
run_mars_wmh() {
    log_message "=== run_mars_wmh (MARS-WMH deep-learning WMH detection) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    log_message "FLAIR: ${flair_file:-<none>}"
    log_message "T1:    ${t1_file:-<none>}"

    # --- Feature flag --------------------------------------------------------
    if [ "${WMH_MARS_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "WMH_MARS_ENABLED is not 'true' - skipping MARS-WMH (set WMH_MARS_ENABLED=true to enable)"
        return 0
    fi

    # --- Argument validation -------------------------------------------------
    if [ -z "$flair_file" ] || [ -z "$t1_file" ]; then
        log_formatted "WARNING" "MARS-WMH: FLAIR and T1 are both required - skipping (non-fatal)"
        return 0
    fi
    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "MARS-WMH: FLAIR file not found: $flair_file - skipping (non-fatal)"
        return 0
    fi
    if [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "MARS-WMH: T1 file not found: $t1_file - skipping (non-fatal)"
        return 0
    fi

    # --- Tool availability (graceful skip) -----------------------------------
    local backend
    backend="$(_mars_detect_wmh)"
    if [ -z "$backend" ]; then
        log_formatted "WARNING" "MARS-WMH not found (no Docker image '${MARS_WMH_DOCKER_IMAGE:-miac/mars-wmh:latest}', no Apptainer .sif via MARS_WMH_SIF, no '${MARS_WMH_CLI:-mars-wmh}' CLI)."
        log_formatted "WARNING" "  Obtain the prebuilt container from https://github.com/miac-research/MARS-WMH (NON-COMMERCIAL license); skipping MARS-WMH (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "MARS-WMH back-end detected: $backend"
    log_formatted "INFO" "MARS-WMH is distributed under a NON-COMMERCIAL license (Gesierich et al., 2025)."

    # --- Workspace -----------------------------------------------------------
    [ -z "$out_dir" ] && out_dir="$(_mars_default_out_dir)"
    mkdir -p "$out_dir" || {
        log_formatted "WARNING" "MARS-WMH: could not create output directory: $out_dir - skipping (non-fatal)"
        return 0
    }

    local threshold="${MARS_WMH_THRESHOLD:-0.5}"
    # Validate the threshold is numeric (integer or decimal) before use.
    if ! [[ "$threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_formatted "WARNING" "MARS_WMH_THRESHOLD='$threshold' is not numeric - falling back to 0.5"
        threshold=0.5
    fi

    log_message "MARS-WMH output dir: $out_dir (threshold=$threshold, backend=$backend)"

    # --- Run MARS-WMH --------------------------------------------------------
    local rc=0
    case "$backend" in
        docker)
            local image="${MARS_WMH_DOCKER_IMAGE:-miac/mars-wmh:latest}"
            local flair_dir t1_dir out_abs
            flair_dir="$(_mars_abs_dir "$flair_file")"
            t1_dir="$(_mars_abs_dir "$t1_file")"
            out_abs="$(_mars_abs_dir "${out_dir}/.")"
            if [ -z "$flair_dir" ] || [ -z "$t1_dir" ] || [ -z "$out_abs" ]; then
                log_formatted "WARNING" "MARS-WMH (docker): could not resolve input/output directories; skipping (non-fatal)"
                return 0
            fi
            # shellcheck disable=SC2086  # MARS_WMH_DOCKER_OPTS is intentionally word-split
            docker run --rm ${MARS_WMH_DOCKER_OPTS:-} \
                -v "${flair_dir}:/flair_in:ro" \
                -v "${t1_dir}:/t1_in:ro" \
                -v "${out_abs}:/output" \
                "$image" \
                --flair "/flair_in/$(basename "$flair_file")" \
                --t1 "/t1_in/$(basename "$t1_file")" \
                --output /output || rc=$?
            ;;
        apptainer)
            local runner="apptainer"
            command -v apptainer >/dev/null 2>&1 || runner="singularity"
            # shellcheck disable=SC2086  # MARS_WMH_APPTAINER_OPTS is intentionally word-split
            "$runner" run ${MARS_WMH_APPTAINER_OPTS:-} \
                "${MARS_WMH_SIF}" \
                --flair "$flair_file" \
                --t1 "$t1_file" \
                --output "$out_dir" || rc=$?
            ;;
        cli)
            "${MARS_WMH_CLI:-mars-wmh}" \
                --flair "$flair_file" \
                --t1 "$t1_file" \
                --output "$out_dir" || rc=$?
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "MARS-WMH ($backend) exited with status $rc; skipping downstream reporting (non-fatal)"
        return 0
    fi

    # --- Locate output -------------------------------------------------------
    local wmh_out
    wmh_out="$(_mars_find_output "$out_dir")"
    if [ -z "$wmh_out" ]; then
        log_formatted "WARNING" "MARS-WMH completed but no WMH segmentation found in $out_dir; skipping reporting (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "MARS-WMH segmentation: $wmh_out"

    # --- Threshold / binarise -----------------------------------------------
    # MARS-WMH may output a probability map or an already-binary mask. Threshold
    # then binarise so volumetry and the brainstem intersection use a clean
    # binary mask regardless. If thresholding fails we skip reporting rather than
    # risk counting probability voxels as lesions.
    local wmh_bin="${out_dir}/mars_wmh_thr${threshold}_bin.nii.gz"
    if ! _mars_fslmaths "MARS-WMH threshold+binarise" "$wmh_out" -thr "$threshold" -bin "$wmh_bin"; then
        log_formatted "WARNING" "MARS-WMH: failed to threshold/binarise output ($wmh_out); skipping reporting (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "MARS-WMH whole-brain WMH mask: $wmh_bin"
    _mars_report_wmh_stats "$wmh_bin" "Whole-brain WMH"

    # --- Brainstem ROI: prefer operator/MARS-brainstem ROI, else pipeline ----
    local brainstem_mask=""
    brainstem_mask="$(_mars_make_brainstem_roi "$t1_file" "$out_dir")"
    # Label provenance accurately: an explicit operator-supplied ROI takes
    # precedence inside _mars_make_brainstem_roi, so attribute it correctly
    # rather than blanket-labelling every generated ROI "MARS-brainstem".
    local roi_source="MARS-brainstem"
    if [ -n "${MARS_BRAINSTEM_ROI:-}" ] && [ -f "${MARS_BRAINSTEM_ROI}" ]; then
        roi_source="operator-supplied"
    fi
    if [ -z "$brainstem_mask" ] || [ ! -f "$brainstem_mask" ]; then
        roi_source="pipeline"
        if brainstem_mask="$(_mars_find_brainstem_mask)"; then
            log_message "Using pipeline brainstem mask: $brainstem_mask"
        else
            brainstem_mask=""
        fi
    fi

    # --- Brainstem-restricted WMH --------------------------------------------
    local brainstem_wmh="${out_dir}/mars_wmh_brainstem.nii.gz"
    local brainstem_reported="no"
    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        log_message "MARS-WMH: intersecting WMH with brainstem ROI ($roi_source): $brainstem_mask"

        # Binarise the brainstem mask (it may be a labelled/intensity volume) and
        # ensure it shares the WMH grid; resample to the WMH mask if needed.
        local bs_bin="${out_dir}/mars_brainstem_bin.nii.gz"
        _mars_fslmaths "Brainstem binarise" "$brainstem_mask" -bin "$bs_bin" || bs_bin="$brainstem_mask"

        local wmh_dims bs_dims
        wmh_dims=$(fslinfo "$wmh_bin" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        bs_dims=$(fslinfo "$bs_bin" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        # Only resample when BOTH dim strings parsed and genuinely differ; an
        # empty bs_dims (fslinfo failed) must not force a spurious reslice.
        if [ -n "$wmh_dims" ] && [ -n "$bs_dims" ] && [ "$wmh_dims" != "$bs_dims" ] && command -v flirt >/dev/null 2>&1; then
            local bs_resampled="${out_dir}/mars_brainstem_resampled.nii.gz"
            if flirt -in "$bs_bin" -ref "$wmh_bin" -out "$bs_resampled" \
                     -applyxfm -usesqform -interp nearestneighbour >/dev/null 2>&1; then
                _mars_fslmaths "Brainstem resample bin" "$bs_resampled" -bin "$bs_bin" || true
            fi
        fi

        if _mars_fslmaths "MARS-WMH brainstem-restricted WMH" "$wmh_bin" -mas "$bs_bin" -bin "$brainstem_wmh"; then
            log_formatted "SUCCESS" "MARS-WMH brainstem-restricted WMH mask: $brainstem_wmh"
            _mars_report_wmh_stats "$brainstem_wmh" "Brainstem WMH"
            brainstem_reported="yes"
        else
            log_formatted "WARNING" "MARS-WMH: failed to intersect WMH with brainstem ROI"
            brainstem_wmh=""
        fi
    else
        log_formatted "WARNING" "MARS-WMH: no brainstem ROI available (neither MARS-brainstem nor a pipeline *brainstem*mask*.nii.gz)."
        log_formatted "WARNING" "  Run the segmentation stage first (or enable MARS_BRAINSTEM_ENABLED) for brainstem-restricted WMH. Reporting whole-brain only."
        brainstem_wmh=""
    fi

    # --- Persist a machine-readable summary ----------------------------------
    local total_vol bs_vol summary
    total_vol=$(fslstats "$wmh_bin" -V 2>/dev/null | awk '{print $2}' || echo "N/A")
    [ -z "$total_vol" ] && total_vol="N/A"
    if [ "$brainstem_reported" = "yes" ] && [ -n "$brainstem_wmh" ] && [ -f "$brainstem_wmh" ]; then
        bs_vol=$(fslstats "$brainstem_wmh" -V 2>/dev/null | awk '{print $2}' || echo "N/A")
        [ -z "$bs_vol" ] && bs_vol="N/A"
    else
        bs_vol="N/A"
    fi
    summary="${out_dir}/mars_wmh_summary.txt"
    {
        echo "tool=MARS-WMH"
        echo "reference=Gesierich et al. 2025, DOI 10.1016/j.cccb.2025.100393"
        echo "license=non-commercial"
        echo "backend=${backend}"
        echo "threshold=${threshold}"
        echo "flair=${flair_file}"
        echo "t1=${t1_file}"
        echo "wmh_mask=${wmh_bin}"
        echo "whole_brain_wmh_mm3=${total_vol}"
        echo "brainstem_roi_source=${roi_source}"
        echo "brainstem_mask=${brainstem_mask:-none}"
        echo "brainstem_wmh_mask=${brainstem_wmh:-none}"
        echo "brainstem_wmh_mm3=${bs_vol}"
    } > "$summary" 2>/dev/null || true
    log_message "MARS-WMH summary written to $summary"

    log_formatted "SUCCESS" "MARS-WMH deep-learning WMH detection completed"
    return 0
}

# ----------------------------------------------------------------------------
# Exports
# ----------------------------------------------------------------------------
export -f run_mars_wmh

log_message "WMH MARS module loaded"
