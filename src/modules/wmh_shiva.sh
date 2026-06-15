#!/usr/bin/env bash
#
# wmh_shiva.sh - Small-lesion white-matter-hyperintensity (WMH) detection via
#                the SHIVA-WMH deep-learning detector.
#
# This module is a self-contained, sourceable add-on that wraps the SHIVA-WMH
# detector (Tran et al., "Early detection of white matter hyperintensities using
# SHIVA-WMH detector," Human Brain Mapping 2024;45(1):e26548, DOI
# 10.1002/hbm.26548). SHIVA-WMH is a 3D U-Net trained specifically for SMALL /
# PUNCTATE WMH: it has HIGH SENSITIVITY but LOWER SPECIFICITY than tools tuned
# for confluent lesions. It takes co-registered T1 + FLAIR and produces a WMH
# probability map in T1 space.
#
# SPECIFICITY PAIRING: because SHIVA-WMH deliberately over-detects small lesions
# to maximise sensitivity, its raw output should be paired with a downstream
# false-positive (FP) filter for specificity. The pipeline's CSF / partial-volume
# exclusion and cortical-ribbon exclusion in analysis.sh, plus the
# brainstem-mask intersection performed here, serve that role for
# brainstem/pons WMH: SHIVA finds the candidate lesions, the brainstem mask +
# FP filter remove the spurious ones.
#
# Two back-ends are supported, preferring the simpler antspynet path:
#   1) antspynet  -- `antspynet.shiva_wmh_segmentation(flair, t1=...)` (Python).
#                    Ships the pretrained SHIVA weights; downloads on first use.
#                    https://github.com/ANTsX/ANTsPyNet
#   2) SHiVAi     -- the SHIVA framework container (Docker/Apptainer).
#                    https://github.com/pboutinaud/SHiVAi
#
# Entry point:
#   run_shiva_wmh <flair> <t1> [out_dir]
#
# Integration hook (for the coordinator to wire into the analysis stage):
#   run_shiva_wmh "$orig_flair" "$orig_t1"
#
# The entry function degrades gracefully (non-fatal WARNING + return 0) when it
# is disabled via config or when neither back-end is installed, so it never
# crashes the pipeline.
#
# NOTE: This is a SOURCED module, not a standalone script. Like the other sourced
# modules (segmentation.sh, wmh_lst_samseg.sh, ...) it does NOT enable
# `set -e -u -o pipefail` at the top, because those options would leak into the
# parent shell and turn every later command in pipeline.sh fatal. The pipeline
# already runs under `set -e -u -o pipefail` (pipeline.sh), and every function
# here is written to tolerate those options and to return 0 on any
# tool-missing/disabled/failure path so it never aborts the run.
#

# Include guard
if [ -n "${_WMH_SHIVA_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_WMH_SHIVA_LOADED=1

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

# Resolve a default output directory under RESULTS_DIR for the SHIVA WMH
# results. Honors the standard module-dir convention when available.
_shiva_default_out_dir() {
    local base
    if declare -F create_module_dir >/dev/null 2>&1; then
        base="$(create_module_dir "wmh_supervised")"
    else
        base="${RESULTS_DIR:-../mri_results}/wmh_supervised"
        mkdir -p "$base"
    fi
    local dir="${base}/shiva"
    mkdir -p "$dir"
    echo "$dir"
}

# Wrapper around safe_fslmaths that falls back to bare fslmaths only if the
# pipeline helper is unavailable (e.g. standalone debugging). On macOS the
# pipeline always provides safe_fslmaths.
_shiva_fslmaths() {
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
# so the caller does not record a blank value as a real measurement.
_shiva_mask_volume_mm3() {
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

# Echo the connected-component (cluster) count of a binary mask, or 0 on
# failure. Uses FSL 'cluster' (26-connectivity); the table has a header line
# plus one row per cluster, so cluster count = data rows. Always returns 0.
_shiva_cluster_count() {
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
_shiva_find_brainstem_mask() {
    local results="${RESULTS_DIR:-../mri_results}"
    local candidate
    # Ordered search patterns, most specific/authoritative first. Prefer the
    # explicit binary "*brainstem*mask*.nii.gz" over an intensity/labelled
    # whole-brainstem volume. We intentionally do NOT fall back to a single
    # hemi-pons sub-region file — that would silently restrict WMH to one
    # sub-region and grossly under-report.
    local patterns=(
        "${results}/segmentation/brainstem/"*"_brainstem_mask.nii.gz"
        "${results}/segmentation/"*"brainstem"*"mask"*".nii.gz"
        "${results}/segmentation/detailed_brainstem/"*"brainstem"*"mask"*".nii.gz"
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

# Report whole-brain and brainstem-restricted WMH (cluster count + volume) for a
# binary lesion mask, intersect with the brainstem mask, and write a small
# machine-readable summary. Always returns 0 (reporting is non-fatal).
# Args: <binary_lesion_mask> <out_dir>
_shiva_report_volumes() {
    local lesion_mask="$1"
    local out_dir="$2"
    local tool_label="shiva"

    if [ ! -f "$lesion_mask" ]; then
        log_formatted "WARNING" "SHIVA-WMH: lesion mask not found for volume reporting: $lesion_mask"
        return 0
    fi

    # Whole-brain WMH (cluster count + volume).
    local total_vol="N/A"
    if total_vol=$(_shiva_mask_volume_mm3 "$lesion_mask"); then
        :
    else
        log_formatted "WARNING" "SHIVA-WMH: could not compute whole-brain WMH volume"
        total_vol="N/A"
    fi
    local total_clusters
    total_clusters=$(_shiva_cluster_count "$lesion_mask")
    log_formatted "INFO" "SHIVA-WMH: whole-brain WMH clusters=${total_clusters}, volume=${total_vol} mm^3"

    # Brainstem-restricted WMH (the specificity-pairing intersection).
    local brainstem_mask
    brainstem_mask="$(_shiva_find_brainstem_mask)"
    local brainstem_vol="N/A"
    local brainstem_clusters="N/A"
    local brainstem_wmh="${out_dir}/${tool_label}_brainstem_wmh.nii.gz"

    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        log_message "SHIVA-WMH: intersecting lesion mask with brainstem mask: $brainstem_mask"
        # Binarise the brainstem mask (it may be a labelled/intensity volume)
        # before intersecting, so a labelled brainstem volume restricts to its
        # nonzero support rather than scaling the WMH mask.
        local bs_bin="${out_dir}/${tool_label}_brainstem_bin.nii.gz"
        if ! _shiva_fslmaths "SHIVA-WMH: binarise brainstem mask" "$brainstem_mask" -bin "$bs_bin"; then
            bs_bin="$brainstem_mask"
        fi

        # Resample the brainstem mask onto the WMH grid when their dimensions
        # differ. SHIVA-WMH runs on the ORIGINAL-space T1/FLAIR, while the
        # pipeline's brainstem mask is produced in the standardized/reference
        # space - so the two grids routinely differ and fslmaths -mas would
        # otherwise fail on a dimension mismatch, silently dropping the
        # brainstem-restricted WMH. Mirror the BIANCA module's flirt resample
        # (nearest-neighbour, sform-based) to align them first.
        # '|| true' guards the pipes against pipefail/set -e on fslinfo failure.
        local wmh_dims bs_dims
        wmh_dims=$(fslinfo "$lesion_mask" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        bs_dims=$(fslinfo "$bs_bin" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        if [ -n "$wmh_dims" ] && [ "$wmh_dims" != "$bs_dims" ] && command -v flirt >/dev/null 2>&1; then
            log_message "SHIVA-WMH: brainstem mask grid ($bs_dims) != WMH grid ($wmh_dims); resampling to WMH space"
            local bs_resampled="${out_dir}/${tool_label}_brainstem_resampled.nii.gz"
            if flirt -in "$bs_bin" -ref "$lesion_mask" -out "$bs_resampled" \
                     -applyxfm -usesqform -interp nearestneighbour >/dev/null 2>&1; then
                _shiva_fslmaths "SHIVA-WMH: resampled brainstem bin" "$bs_resampled" -bin "$bs_bin" || true
            else
                log_formatted "WARNING" "SHIVA-WMH: failed to resample brainstem mask to WMH grid; intersection may fail"
            fi
        fi

        if _shiva_fslmaths "SHIVA-WMH: brainstem WMH intersection" \
            "$lesion_mask" -mas "$bs_bin" -bin "$brainstem_wmh"; then
            if brainstem_vol=$(_shiva_mask_volume_mm3 "$brainstem_wmh"); then
                :
            else
                log_formatted "WARNING" "SHIVA-WMH: could not compute brainstem WMH volume"
                brainstem_vol="N/A"
            fi
            brainstem_clusters=$(_shiva_cluster_count "$brainstem_wmh")
            log_formatted "INFO" "SHIVA-WMH: brainstem-restricted WMH clusters=${brainstem_clusters}, volume=${brainstem_vol} mm^3"
        else
            log_formatted "WARNING" "SHIVA-WMH: brainstem intersection failed"
        fi
    else
        log_formatted "WARNING" "SHIVA-WMH: no brainstem mask found; skipping brainstem-restricted WMH (run segmentation stage first)"
    fi

    # Persist a small machine-readable summary.
    local summary="${out_dir}/${tool_label}_wmh_summary.txt"
    {
        echo "tool=shiva_wmh"
        echo "lesion_mask=${lesion_mask}"
        echo "whole_brain_wmh_clusters=${total_clusters}"
        echo "whole_brain_wmh_mm3=${total_vol}"
        echo "brainstem_mask=${brainstem_mask:-none}"
        echo "brainstem_wmh_mask=${brainstem_wmh}"
        echo "brainstem_wmh_clusters=${brainstem_clusters}"
        echo "brainstem_wmh_mm3=${brainstem_vol}"
        echo "note=SHIVA-WMH is a high-sensitivity small-lesion detector; pair with the FP filter for specificity"
    } > "$summary" 2>/dev/null || true
    log_message "SHIVA-WMH: summary written to $summary"

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Back-end detection
# ──────────────────────────────────────────────────────────────────────────────

# Detect an available SHIVA-WMH back-end.
# Echoes one of: "antspynet" | "container" | "" (none). Always returns 0.
# Honors SHIVA_WMH_BACKEND if set to a non-"auto" value (still verified).
_shiva_detect_backend() {
    local want="${SHIVA_WMH_BACKEND:-auto}"

    # antspynet (preferred): importable Python module via uv (Python 3.12.8).
    # Never bare python. --no-sync so a mere availability probe does not trigger
    # a (potentially slow / network-bound) environment resolve+sync.
    if [ "$want" = "auto" ] || [ "$want" = "antspynet" ]; then
        if command -v uv >/dev/null 2>&1 && uv run --no-sync python -c "import antspynet" >/dev/null 2>&1; then
            echo "antspynet"
            return 0
        fi
    fi

    # SHiVAi container (Docker or Apptainer/Singularity).
    if [ "$want" = "auto" ] || [ "$want" = "container" ]; then
        local image="${SHIVA_WMH_CONTAINER_IMAGE:-}"
        if [ -n "$image" ]; then
            if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
                echo "container"
                return 0
            fi
            # Apptainer/Singularity: the "image" is an .sif path on disk.
            if [ -f "$image" ] && { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
                echo "container"
                return 0
            fi
        fi
    fi

    echo ""
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# antspynet back-end
# ──────────────────────────────────────────────────────────────────────────────

# Run SHIVA-WMH via antspynet.shiva_wmh_segmentation, writing a probability map.
# Args: <flair> <t1> <out_prob_map>
# Returns 0 on success (prob map written), non-zero on failure.
_shiva_run_antspynet() {
    local flair_file="$1"
    local t1_file="$2"
    local prob_map="$3"

    local which_model="${SHIVA_WMH_MODEL:-all}"
    local verbose_py="False"
    [ "${SHIVA_WMH_VERBOSE:-true}" = "true" ] && verbose_py="True"

    log_message "SHIVA-WMH (antspynet): flair=$flair_file t1=$t1_file model=$which_model"

    # Inline Python via uv (Python 3.12.8), never bare python. The FLAIR must be
    # aligned to the T1; antspynet performs its own preprocessing
    # (do_preprocessing=True: N4, intensity truncation, brain extraction). The
    # output probability image is in the (T1) input space.
    SHIVA_FLAIR="$flair_file" SHIVA_T1="$t1_file" SHIVA_OUT="$prob_map" \
    SHIVA_MODEL="$which_model" SHIVA_VERBOSE="$verbose_py" \
    uv run --no-sync python - <<'PYEOF'
import os
import sys

flair_path = os.environ["SHIVA_FLAIR"]
t1_path = os.environ.get("SHIVA_T1", "")
out_path = os.environ["SHIVA_OUT"]
which_model = os.environ.get("SHIVA_MODEL", "all")
verbose = os.environ.get("SHIVA_VERBOSE", "False") == "True"

# which_model may be "all" or an integer fold index (0-4).
if which_model != "all":
    try:
        which_model = int(which_model)
    except ValueError:
        which_model = "all"

try:
    import ants
    import antspynet
except Exception as exc:  # pragma: no cover - guarded by availability check
    sys.stderr.write("SHIVA-WMH: failed to import ants/antspynet: %s\n" % exc)
    sys.exit(3)

try:
    flair = ants.image_read(flair_path)
    t1 = ants.image_read(t1_path) if t1_path else None
    prob = antspynet.shiva_wmh_segmentation(
        flair,
        t1=t1,
        which_model=which_model,
        do_preprocessing=True,
        verbose=verbose,
    )
    ants.image_write(prob, out_path)
except Exception as exc:
    sys.stderr.write("SHIVA-WMH: segmentation failed: %s\n" % exc)
    sys.exit(4)

sys.exit(0)
PYEOF
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "SHIVA-WMH (antspynet) exited with status $rc"
        return "$rc"
    fi
    if [ ! -f "$prob_map" ]; then
        log_formatted "WARNING" "SHIVA-WMH (antspynet) produced no probability map at $prob_map"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# SHiVAi container back-end
# ──────────────────────────────────────────────────────────────────────────────

# Locate a SHIVA-WMH probability map produced by the SHiVAi container under a
# directory. Echoes the first plausible match (empty if none). Always returns 0.
_shiva_find_container_output() {
    local out_dir="$1"
    local cand f
    for cand in \
        "${out_dir}/"*"wmh"*"map"*".nii.gz" \
        "${out_dir}/"*"WMH"*"map"*".nii.gz" \
        "${out_dir}/"*"wmh"*".nii.gz" \
        "${out_dir}/"*"WMH"*".nii.gz"; do
        for f in $cand; do
            if [ -f "$f" ]; then
                echo "$f"
                return 0
            fi
        done
    done
    # Recursive fallback (the SHiVAi container nests outputs per-subject).
    f=$(find "$out_dir" \( -iname "*wmh*map*.nii.gz" -o -iname "*wmh*.nii.gz" \) -type f 2>/dev/null | head -1 || true)
    echo "$f"
    return 0
}

# Run SHIVA-WMH via the SHiVAi container, writing a probability map.
# Args: <flair> <t1> <out_prob_map> <work_dir>
# Returns 0 on success (prob map written), non-zero on failure.
#
# The SHiVAi container CLI varies by version and deployment; the exact processing
# command must be supplied via SHIVA_WMH_CONTAINER_CMD. This wrapper sets up the
# bind-mounted input/output dirs and substitutes placeholders, leaving the
# subject-level orchestration to the user-provided command.
_shiva_run_container() {
    local flair_file="$1"
    local t1_file="$2"
    local prob_map="$3"
    local work_dir="$4"

    local image="${SHIVA_WMH_CONTAINER_IMAGE:-}"
    local user_cmd="${SHIVA_WMH_CONTAINER_CMD:-}"
    local runtime="${SHIVA_WMH_CONTAINER_RUNTIME:-auto}"

    if [ -z "$image" ]; then
        log_formatted "WARNING" "SHIVA-WMH (container): SHIVA_WMH_CONTAINER_IMAGE not set; skipping"
        return 1
    fi
    if [ -z "$user_cmd" ]; then
        log_formatted "WARNING" "SHIVA-WMH (container): SHIVA_WMH_CONTAINER_CMD not set."
        log_formatted "WARNING" "  The SHiVAi CLI varies by version; supply the full processing command via"
        log_formatted "WARNING" "  SHIVA_WMH_CONTAINER_CMD using placeholders {FLAIR} {T1} {OUTDIR}. Skipping (non-fatal)."
        return 1
    fi

    local out_dir="${work_dir}/container_out"
    mkdir -p "$out_dir"

    # Resolve the container runtime: docker, or apptainer/singularity for .sif.
    local rt=""
    case "$runtime" in
        docker) rt="docker" ;;
        apptainer) rt="apptainer" ;;
        singularity) rt="singularity" ;;
        auto)
            if [ -f "$image" ] && command -v apptainer >/dev/null 2>&1; then
                rt="apptainer"
            elif [ -f "$image" ] && command -v singularity >/dev/null 2>&1; then
                rt="singularity"
            elif command -v docker >/dev/null 2>&1; then
                rt="docker"
            fi
            ;;
    esac
    if [ -z "$rt" ]; then
        log_formatted "WARNING" "SHIVA-WMH (container): no usable runtime for image '$image' (runtime=$runtime); skipping"
        return 1
    fi

    # Substitute placeholders in the user command. The user command is
    # responsible for the in-container processing invocation; we only provide the
    # paths and a wrapping runtime call with bind mounts.
    local subbed="$user_cmd"
    subbed="${subbed//\{FLAIR\}/$flair_file}"
    subbed="${subbed//\{T1\}/$t1_file}"
    subbed="${subbed//\{OUTDIR\}/$out_dir}"
    subbed="${subbed//\{IMAGE\}/$image}"

    log_message "SHIVA-WMH (container): runtime=$rt image=$image"
    log_message "SHIVA-WMH (container): cmd=$subbed"

    local rc=0
    # The user command is executed verbatim (it already includes the runtime +
    # bind-mount layout appropriate for their deployment). eval is required to
    # honour the user's quoting/redirection in SHIVA_WMH_CONTAINER_CMD.
    eval "$subbed" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log_formatted "WARNING" "SHIVA-WMH (container) command exited with status $rc"
        return "$rc"
    fi

    local found
    found="$(_shiva_find_container_output "$out_dir")"
    if [ -z "$found" ]; then
        log_formatted "WARNING" "SHIVA-WMH (container) produced no WMH map under $out_dir"
        return 1
    fi
    # Copy the container output to the caller's expected probability-map path.
    # On copy failure, signal failure explicitly (the caller checks both the
    # return code and the existence of "$prob_map") rather than silently
    # returning 0 with no file at the expected path.
    if ! cp -f "$found" "$prob_map" 2>/dev/null; then
        log_formatted "WARNING" "SHIVA-WMH (container): failed to copy $found -> $prob_map"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Main entry point
# ──────────────────────────────────────────────────────────────────────────────

# run_shiva_wmh <flair> <t1> [out_dir]
#
# Runs the SHIVA-WMH small-lesion detector on a subject's co-registered T1 +
# FLAIR, thresholds the probability map to a binary WMH mask, reports cluster
# count + volume, intersects with the brainstem mask, and writes a summary.
#
# Graceful non-fatal skip (WARNING + return 0) when:
#   * WMH_SHIVA_ENABLED is not "true"
#   * FLAIR or T1 is missing
#   * neither back-end (antspynet / SHiVAi container) is installed
#   * the chosen back-end fails to produce a probability map
#
# Because SHIVA-WMH is tuned for HIGH SENSITIVITY to small/punctate lesions
# (lower specificity), its output is meant to be paired with the pipeline's FP
# filter (CSF/PV + cortical exclusion in analysis.sh) and the brainstem-mask
# intersection performed here for specificity.
run_shiva_wmh() {
    log_message "=== run_shiva_wmh (SHIVA-WMH small-lesion WMH detector) ==="

    local flair_file="${1:-}"
    local t1_file="${2:-}"
    local out_dir="${3:-}"

    # --- Feature flag --------------------------------------------------------
    if [ "${WMH_SHIVA_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "SHIVA-WMH detection disabled (WMH_SHIVA_ENABLED=${WMH_SHIVA_ENABLED:-false}); skipping"
        return 0
    fi

    # --- Argument validation -------------------------------------------------
    if [ -z "$flair_file" ] || [ -z "$t1_file" ]; then
        log_formatted "WARNING" "SHIVA-WMH: FLAIR and T1 are both required; skipping (non-fatal)"
        return 0
    fi
    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "SHIVA-WMH: FLAIR file not found: $flair_file; skipping (non-fatal)"
        return 0
    fi
    if [ ! -f "$t1_file" ]; then
        log_formatted "WARNING" "SHIVA-WMH: T1 file not found: $t1_file; skipping (non-fatal)"
        return 0
    fi

    # --- Back-end detection (graceful skip) ----------------------------------
    local backend
    backend="$(_shiva_detect_backend)"
    if [ -z "$backend" ]; then
        log_formatted "WARNING" "SHIVA-WMH not found: no importable 'antspynet' module and no configured SHiVAi container."
        log_formatted "WARNING" "  Install antspynet (uv add antspynet) or set SHIVA_WMH_CONTAINER_IMAGE/_CMD."
        log_formatted "WARNING" "  Skipping SHIVA-WMH detection (non-fatal)."
        return 0
    fi
    log_formatted "INFO" "SHIVA-WMH back-end detected: $backend"

    # --- Workspace -----------------------------------------------------------
    [ -z "$out_dir" ] && out_dir="$(_shiva_default_out_dir)"
    mkdir -p "$out_dir" || {
        log_formatted "WARNING" "SHIVA-WMH: could not create output directory: $out_dir; skipping (non-fatal)"
        return 0
    }

    log_message "SHIVA-WMH inputs: FLAIR=$flair_file T1=$t1_file"
    log_message "SHIVA-WMH output dir: $out_dir"

    # --- Run the chosen back-end to produce a probability map ----------------
    local prob_map="${out_dir}/shiva_wmh_probability.nii.gz"
    local rc=0
    case "$backend" in
        antspynet)
            _shiva_run_antspynet "$flair_file" "$t1_file" "$prob_map" || rc=$?
            ;;
        container)
            _shiva_run_container "$flair_file" "$t1_file" "$prob_map" "$out_dir" || rc=$?
            ;;
    esac

    if [ "$rc" -ne 0 ] || [ ! -f "$prob_map" ]; then
        log_formatted "WARNING" "SHIVA-WMH ($backend) did not produce a probability map; skipping reporting (non-fatal)"
        return 0
    fi
    log_formatted "SUCCESS" "SHIVA-WMH probability map: $prob_map"

    # --- Threshold to a binary WMH mask --------------------------------------
    # SHIVA-WMH probability maps are in [0,1]; 0.5 balances precision/sensitivity
    # (per the original implementation). Validate the threshold before use.
    local threshold="${SHIVA_WMH_THRESHOLD:-0.5}"
    if ! [[ "$threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_formatted "WARNING" "SHIVA_WMH_THRESHOLD='$threshold' is not numeric - falling back to 0.5"
        threshold=0.5
    fi
    local wmh_mask="${out_dir}/shiva_wmh_thr${threshold}_bin.nii.gz"
    if ! _shiva_fslmaths "SHIVA-WMH threshold" "$prob_map" -thr "$threshold" -bin "$wmh_mask"; then
        log_formatted "WARNING" "SHIVA-WMH: failed to threshold probability map; skipping reporting (non-fatal)"
        return 0
    fi

    # Optional cluster-size post-processing: drop clusters below the minimum.
    # SHIVA's small-lesion sensitivity can yield many tiny FP specks; this is a
    # first-line specificity guard (the brainstem mask + analysis.sh FP filter
    # are the others).
    local min_cluster="${SHIVA_WMH_MIN_CLUSTER_SIZE:-0}"
    if [ -n "${SHIVA_WMH_MIN_CLUSTER_SIZE:-}" ] && ! [[ "$min_cluster" =~ ^[0-9]+$ ]]; then
        log_formatted "WARNING" "SHIVA_WMH_MIN_CLUSTER_SIZE='$min_cluster' is not a non-negative integer - skipping cluster filtering"
    elif [ "$min_cluster" -gt 0 ] && command -v cluster >/dev/null 2>&1; then
        local clustered="${out_dir}/shiva_wmh_clustered.nii.gz"
        # Only claim the filter was applied if BOTH the cluster index image was
        # produced AND the re-binarised mask was written back; otherwise the
        # reported volumes would silently reflect the UNFILTERED mask.
        if cluster --in="$wmh_mask" --thresh=0.5 --connectivity=26 \
                   --minextent="$min_cluster" --oindex="$clustered" >/dev/null 2>&1 \
           && [ -f "$clustered" ]; then
            if _shiva_fslmaths "SHIVA-WMH cluster bin" "$clustered" -bin "$wmh_mask"; then
                log_message "SHIVA-WMH: applied min-cluster-size post-processing (>= ${min_cluster} voxels)"
            else
                log_formatted "WARNING" "SHIVA-WMH: min-cluster-size re-binarisation failed; reporting unfiltered mask"
            fi
        else
            log_formatted "WARNING" "SHIVA-WMH: min-cluster-size filtering did not run; reporting unfiltered mask"
        fi
    fi

    log_formatted "SUCCESS" "SHIVA-WMH whole-brain WMH mask: $wmh_mask"

    # --- Report + brainstem intersection + summary ---------------------------
    _shiva_report_volumes "$wmh_mask" "$out_dir"

    log_formatted "SUCCESS" "SHIVA-WMH small-lesion WMH detection complete"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Exports
# ──────────────────────────────────────────────────────────────────────────────
export -f _shiva_default_out_dir
export -f _shiva_fslmaths
export -f _shiva_mask_volume_mm3
export -f _shiva_cluster_count
export -f _shiva_find_brainstem_mask
export -f _shiva_report_volumes
export -f _shiva_detect_backend
export -f _shiva_run_antspynet
export -f _shiva_find_container_output
export -f _shiva_run_container
export -f run_shiva_wmh

log_message "WMH SHIVA module loaded"
