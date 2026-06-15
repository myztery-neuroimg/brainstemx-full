#!/usr/bin/env bash
#
# wmh_bianca.sh - Supervised white-matter-hyperintensity (WMH) detection via FSL BIANCA
#
# This module provides a self-contained, sourceable wrapper around FSL's BIANCA
# (Brain Intensity AbNormality Classification Algorithm), a k-NN supervised
# classifier for WMH segmentation. The literature (Griffanti et al., NeuroImage
# 2016) shows supervised tools such as BIANCA and LST outperform unsupervised
# intensity thresholding for small-lesion sensitivity, which is exactly the
# regime relevant to brainstem/pons hyperintensity analysis.
#
# BIANCA requires manually-labelled TRAINING data: a masterfile listing subjects
# that each have a FLAIR (and optionally T1) plus a MANUAL lesion mask, and a
# query subject to be segmented. When no training data is available (the common
# case for a fresh deployment) this module logs a clear, non-fatal warning and
# skips gracefully - it never hard-crashes the pipeline.
#
# Integration hook (wire from the analysis stage):
#   run_bianca_wmh "<flair_std.nii.gz>" "<output_prefix>" "<t1_std.nii.gz>" "<flair_to_mni.mat>"
#
# Dependencies: FSL (bianca, make_bianca_mask, bianca_cluster_stats). All are
# detected at runtime; absence is a graceful non-fatal skip.
#

# Include guard - prevent redundant re-sourcing by modules
if [ -n "${_WMH_BIANCA_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_WMH_BIANCA_LOADED=1

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

# Detect whether the FSL BIANCA toolset is available on PATH.
# Returns 0 if both 'bianca' and 'make_bianca_mask' are present, 1 otherwise.
bianca_is_available() {
    log_message "Checking for FSL BIANCA availability"

    if ! command -v bianca >/dev/null 2>&1; then
        log_formatted "WARNING" "FSL 'bianca' not found on PATH - skipping supervised WMH (BIANCA) analysis"
        return 1
    fi

    if ! command -v make_bianca_mask >/dev/null 2>&1; then
        log_formatted "WARNING" "FSL 'make_bianca_mask' not found on PATH - skipping supervised WMH (BIANCA) analysis"
        return 1
    fi

    log_message "FSL BIANCA toolset detected"
    return 0
}

# Locate the pipeline's brainstem / posterior-fossa mask in the results tree.
# Echoes the path to the first match (stdout); returns 0 if found, 1 otherwise.
# All diagnostic output goes to stderr (via the logging helpers) so the caller
# can safely capture stdout.
find_brainstem_mask() {
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

    local dir
    local found
    for dir in "${search_dirs[@]}"; do
        [ -d "$dir" ] || continue
        # Prefer a file matching *brainstem*mask*.nii.gz
        found=$(find "$dir" -name "*brainstem*mask*.nii.gz" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    done

    # Broader fallback: any *brainstem*.nii.gz (an intensity/labelled volume can
    # still be binarised downstream).
    for dir in "${search_dirs[@]}"; do
        [ -d "$dir" ] || continue
        found=$(find "$dir" -name "*brainstem*.nii.gz" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    done

    return 1
}

# Report cluster count and total volume (mm^3) of a binary mask.
# Usage: report_wmh_stats <binary_mask.nii.gz> <label>
report_wmh_stats() {
    local mask="$1"
    local label="${2:-WMH}"

    if [ ! -f "$mask" ]; then
        log_formatted "WARNING" "report_wmh_stats: mask not found: $mask"
        return 1
    fi

    # Total volume in voxels and mm^3. fslstats -V => "<nvoxels> <volume_mm3>".
    local vol_stats
    vol_stats=$(fslstats "$mask" -V 2>/dev/null || echo "0 0")
    local n_voxels
    local volume_mm3
    n_voxels=$(echo "$vol_stats" | awk '{print $1}')
    volume_mm3=$(echo "$vol_stats" | awk '{print $2}')

    # Cluster count via FSL 'cluster' (connected components). The table has a
    # header line plus one row per cluster, so cluster count = data rows.
    # Capture the report first (guarded so a cluster/pipefail failure never
    # aborts under set -e), then count rows separately.
    local n_clusters=0
    if command -v cluster >/dev/null 2>&1; then
        local cluster_report
        cluster_report=$(cluster --in="$mask" --thresh=0.5 --connectivity=26 2>/dev/null) || cluster_report=""
        if [ -n "$cluster_report" ]; then
            # Count data rows (skip the header line); default to 0 if none.
            n_clusters=$(printf '%s\n' "$cluster_report" | tail -n +2 | grep -c . || true)
            [ -z "$n_clusters" ] && n_clusters=0
        fi
    fi

    log_formatted "INFO" "${label}: clusters=${n_clusters}, voxels=${n_voxels}, volume=${volume_mm3} mm^3"
    return 0
}

# ----------------------------------------------------------------------------
# Main entry point
# ----------------------------------------------------------------------------

# run_bianca_wmh - Supervised WMH segmentation for one query subject.
#
# Usage:
#   run_bianca_wmh <flair_std.nii.gz> <output_prefix> [<t1_std.nii.gz>] [<flair_to_mni.mat>]
#
# Arguments:
#   $1  FLAIR image in the pipeline's standard space (brain-extracted preferred)
#   $2  Output prefix (directory + basename); the dir is created if missing
#   $3  (optional) T1 image co-registered to the FLAIR/standard space
#   $4  (optional) FLAIR->MNI linear transform (.mat) for spatial features.
#       If omitted, the module attempts to locate one under RESULTS_DIR.
#
# Behaviour:
#   - Non-fatal graceful skip (return non-zero, never 'exit') when:
#       * WMH_BIANCA_ENABLED is not "true"
#       * the FSL BIANCA toolset is unavailable
#       * no training data (BIANCA_TRAINING_MASTERFILE) and no pre-trained
#         classifier (BIANCA_LOAD_CLASSIFIER) is configured
#       * required inputs are missing
#   - On success: writes a probability map, a thresholded binary WMH mask, and a
#     brainstem-restricted WMH mask; reports cluster count + volume for both.
run_bianca_wmh() {
    local flair_file="${1:-}"
    local out_prefix="${2:-}"
    local t1_file="${3:-}"
    local flair_to_mni="${4:-}"

    log_formatted "INFO" "=== SUPERVISED WMH DETECTION (FSL BIANCA) ==="
    log_message "FLAIR (query): ${flair_file:-<none>}"
    log_message "Output prefix: ${out_prefix:-<none>}"
    [ -n "$t1_file" ] && log_message "T1 (query): $t1_file"
    [ -n "$flair_to_mni" ] && log_message "FLAIR->MNI transform: $flair_to_mni"

    # --- Feature flag --------------------------------------------------------
    if [ "${WMH_BIANCA_ENABLED:-false}" != "true" ]; then
        log_formatted "INFO" "WMH_BIANCA_ENABLED is not 'true' - skipping BIANCA (set WMH_BIANCA_ENABLED=true to enable)"
        return 0
    fi

    # --- Argument validation -------------------------------------------------
    if [ -z "$flair_file" ] || [ -z "$out_prefix" ]; then
        log_formatted "WARNING" "run_bianca_wmh: missing required arguments (FLAIR and output prefix) - skipping"
        return "${ERR_INVALID_ARGS:-2}"
    fi

    if [ ! -f "$flair_file" ]; then
        log_formatted "WARNING" "run_bianca_wmh: FLAIR file not found: $flair_file - skipping BIANCA"
        return "${ERR_DATA_MISSING:-31}"
    fi

    # --- Tool availability (graceful skip) -----------------------------------
    if ! bianca_is_available; then
        log_formatted "WARNING" "FSL BIANCA unavailable - supervised WMH analysis skipped (non-fatal)"
        return "${ERR_DEPENDENCY:-127}"
    fi

    # --- Training data / pre-trained classifier (graceful skip) --------------
    # BIANCA needs EITHER a training masterfile with manual lesion masks, OR a
    # previously-saved classifier to load. Without either it cannot run.
    local have_training=false
    local have_classifier=false
    if [ -n "${BIANCA_TRAINING_MASTERFILE:-}" ] && [ -f "${BIANCA_TRAINING_MASTERFILE}" ]; then
        have_training=true
    fi
    if [ -n "${BIANCA_LOAD_CLASSIFIER:-}" ] && [ -f "${BIANCA_LOAD_CLASSIFIER}" ]; then
        have_classifier=true
    fi

    if [ "$have_training" != "true" ] && [ "$have_classifier" != "true" ]; then
        log_formatted "WARNING" "BIANCA requires manually-labelled TRAINING data or a pre-trained classifier."
        log_formatted "WARNING" "  None configured. Set ONE of the following in your config:"
        log_formatted "WARNING" "    BIANCA_TRAINING_MASTERFILE=/path/to/training_masterfile.txt  (with manual lesion masks)"
        log_formatted "WARNING" "    BIANCA_LOAD_CLASSIFIER=/path/to/saved_classifier_data        (from --saveclassifierdata)"
        log_formatted "WARNING" "  This is EXPECTED on a fresh deployment - supervised WMH analysis skipped (non-fatal)."
        return "${ERR_DATA_MISSING:-31}"
    fi

    # --- Workspace -----------------------------------------------------------
    local work_dir
    work_dir="$(dirname "$out_prefix")"
    mkdir -p "$work_dir" || {
        log_formatted "WARNING" "Could not create BIANCA output directory: $work_dir - skipping"
        return "${ERR_PERMISSION:-4}"
    }
    local bianca_tmp="${work_dir}/bianca_tmp"
    mkdir -p "$bianca_tmp" || {
        log_formatted "WARNING" "Could not create BIANCA temp directory: $bianca_tmp - skipping"
        return "${ERR_PERMISSION:-4}"
    }

    # --- Locate FLAIR->MNI transform if not supplied -------------------------
    # BIANCA uses MNI coordinates as spatial features (--matfeaturenum). A linear
    # .mat from the query FLAIR to MNI is strongly recommended.
    if [ -z "$flair_to_mni" ]; then
        local candidate
        # '|| true' guards against SIGPIPE/pipefail from 'find | head' under set -e.
        candidate=$(find "${RESULTS_DIR:-.}" \( -name "*flair*to*mni*.mat" -o -name "*flair*2mni*.mat" -o -name "*to_mni*.mat" \) -type f 2>/dev/null | head -1 || true)
        if [ -n "$candidate" ]; then
            flair_to_mni="$candidate"
            log_message "Auto-located FLAIR->MNI transform: $flair_to_mni"
        else
            log_formatted "WARNING" "No FLAIR->MNI transform found; proceeding WITHOUT spatial (MNI) features."
            log_formatted "WARNING" "  Spatial features improve BIANCA accuracy - supply BIANCA query transform if possible."
        fi
    fi

    # --- Brain mask for the query FLAIR --------------------------------------
    # BIANCA needs a brain mask feature column (--brainmaskfeaturenum). Derive
    # one from the (brain-extracted) FLAIR if a dedicated mask is not present.
    local brain_mask="${out_prefix}_bianca_brainmask.nii.gz"
    if ! safe_fslmaths "BIANCA brain mask" "$flair_file" -bin "$brain_mask"; then
        log_formatted "WARNING" "Failed to create brain mask for BIANCA - skipping"
        return "${ERR_FSL:-21}"
    fi

    # --- Build the query masterfile ------------------------------------------
    # Column order for the QUERY row (1-based), kept consistent with training:
    #   1: FLAIR
    #   2: T1 (if present)
    #   3 (or 2): brain mask
    #   last: FLAIR->MNI .mat (if present)
    # We compute the column indices dynamically so --featuresubset etc. match.
    local query_masterfile="${bianca_tmp}/bianca_query_masterfile.txt"
    local -a row_fields=()
    local -a feature_cols=()   # intensity feature columns (FLAIR, T1)
    local col=0

    # FLAIR (intensity feature, column 1)
    row_fields+=("$flair_file"); col=$((col + 1)); feature_cols+=("$col")
    local flair_col=$col

    # T1 (intensity feature) if provided
    local t1_col=0
    if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
        row_fields+=("$t1_file"); col=$((col + 1)); feature_cols+=("$col")
        t1_col=$col
    elif [ -n "$t1_file" ]; then
        log_formatted "WARNING" "T1 supplied but not found ($t1_file) - using FLAIR-only features"
    fi

    # Brain mask column
    row_fields+=("$brain_mask"); col=$((col + 1))
    local brainmask_col=$col

    # FLAIR->MNI transform column (spatial features)
    local mat_col=0
    if [ -n "$flair_to_mni" ] && [ -f "$flair_to_mni" ]; then
        row_fields+=("$flair_to_mni"); col=$((col + 1))
        mat_col=$col
    fi

    # BIANCA masterfiles are space-delimited with NO quoting mechanism, so any
    # path containing a space would silently corrupt the column layout. Detect
    # and skip rather than produce a wrong segmentation.
    local field
    for field in "${row_fields[@]}"; do
        if [[ "$field" == *" "* ]]; then
            log_formatted "WARNING" "Input path contains a space ('$field'); BIANCA masterfiles cannot quote paths - skipping (non-fatal)"
            return "${ERR_INVALID_ARGS:-2}"
        fi
    done

    # Write the single query row (space-separated).
    printf '%s\n' "$(IFS=' '; echo "${row_fields[*]}")" > "$query_masterfile"
    log_message "BIANCA query masterfile: $query_masterfile"
    log_message "  columns: FLAIR=$flair_col, T1=$t1_col, brainmask=$brainmask_col, mat=$mat_col"

    # featuresubset: comma-separated intensity feature columns
    local featuresubset
    featuresubset="$(IFS=','; echo "${feature_cols[*]}")"

    # --- Assemble the bianca command -----------------------------------------
    local bianca_out="${out_prefix}_bianca_output"
    local -a bianca_cmd=(bianca)

    if [ "$have_classifier" = "true" ]; then
        # Pre-trained: query subject is row 1 of the (query-only) masterfile and
        # we load the saved classifier rather than training. The column layout of
        # the auto-built query row must match the layout the classifier was
        # trained with - configure BIANCA_* feature columns if it differs.
        bianca_cmd+=(--singlefile="$query_masterfile")
        bianca_cmd+=(--querysubjectnum=1)
        bianca_cmd+=(--brainmaskfeaturenum="${BIANCA_BRAINMASK_FEATURENUM:-$brainmask_col}")
        bianca_cmd+=(--loadclassifierdata="$BIANCA_LOAD_CLASSIFIER")
        bianca_cmd+=(--featuresubset="${BIANCA_FEATURESUBSET:-$featuresubset}")
        if [ -n "${BIANCA_MATFEATURENUM:-}" ]; then
            bianca_cmd+=(--matfeaturenum="$BIANCA_MATFEATURENUM")
        elif [ "$mat_col" -gt 0 ]; then
            bianca_cmd+=(--matfeaturenum="$mat_col")
        fi
        log_message "Using pre-trained BIANCA classifier: $BIANCA_LOAD_CLASSIFIER"
    else
        # Train from a masterfile with manual lesion masks, then segment the
        # query. BIANCA applies ONE global column layout to every row of the
        # combined masterfile, so the appended query row must have the SAME
        # column layout as the training rows - including the manual-label column.
        #
        # The training masterfile (and its column numbers) are entirely
        # user-defined via BIANCA_*_FEATURENUM. To keep columns aligned, the
        # query row is appended with a PLACEHOLDER value at the label column
        # (the brain mask, which is harmless because the query is NOT included in
        # --trainingnums and BIANCA ignores the query's label). The query row's
        # feature/brainmask/mat columns must therefore match the training layout;
        # configure BIANCA_FEATURESUBSET / BIANCA_BRAINMASK_FEATURENUM /
        # BIANCA_MATFEATURENUM to match your training masterfile.
        local label_col="${BIANCA_LABEL_FEATURENUM:-4}"
        local query_row_aligned="${bianca_tmp}/bianca_query_row_aligned.txt"

        # Insert a PLACEHOLDER value at the label column of the auto-built query
        # row so its columns line up with the training rows' label column.
        # - If the query already has >= label_col fields, the placeholder is
        #   inserted at position label_col (shifting later fields right by one).
        # - If the query is shorter than label_col, intervening missing columns
        #   are padded with the placeholder so the label lands exactly at label_col.
        # The placeholder is the query brain mask (harmless: the query is never a
        # training subject, so BIANCA ignores its label).
        if ! awk -v c="$label_col" -v ph="$brain_mask" '
            { n = NF;
              total = (n + 1 > c ? n + 1 : c);  # output has at least c columns
              out = "";
              src = 0;                          # index into the original fields
              for (i = 1; i <= total; i++) {
                  if (i == c) {
                      val = ph                  # the label placeholder
                  } else if (src < n) {
                      src++; val = $src         # next real field
                  } else {
                      val = ph                  # pad missing columns
                  }
                  out = (i == 1 ? val : out OFS val)
              }
              print out }' "$query_masterfile" > "$query_row_aligned"; then
            log_formatted "WARNING" "Failed to align query row with training label column - skipping BIANCA"
            return "${ERR_GENERAL:-1}"
        fi

        local combined_masterfile="${bianca_tmp}/bianca_combined_masterfile.txt"
        # Normalise: ensure the training file ends with a newline before
        # appending the query row, so concatenation can never merge two rows.
        awk '1' "$BIANCA_TRAINING_MASTERFILE" > "$combined_masterfile"
        cat "$query_row_aligned" >> "$combined_masterfile"

        # Count NON-EMPTY training rows. grep -c returns 1 (and would abort under
        # set -e) when there are zero matches, so guard with '|| true'.
        local n_training
        n_training=$(grep -c '[^[:space:]]' "$BIANCA_TRAINING_MASTERFILE" || true)
        [ -z "$n_training" ] && n_training=0
        if [ "$n_training" -lt 1 ]; then
            log_formatted "WARNING" "BIANCA training masterfile has no usable rows: $BIANCA_TRAINING_MASTERFILE - skipping (non-fatal)"
            return "${ERR_DATA_MISSING:-31}"
        fi
        # The query row is the row physically after the training rows. 'awk 1'
        # normalises trailing newlines so the combined file has exactly
        # n_training + 1 rows and the query is the last one.
        local query_row=$((n_training + 1))

        # The placeholder label was inserted at label_col, so every AUTO-derived
        # query column index at or after label_col shifts right by one. Compute
        # the shifted brainmask/mat columns and shifted featuresubset list so the
        # --*featurenum flags point at the correct columns of the combined file.
        local brainmask_col_s="$brainmask_col"
        [ "$brainmask_col" -ge "$label_col" ] && brainmask_col_s=$((brainmask_col + 1))
        local mat_col_s="$mat_col"
        [ "$mat_col" -gt 0 ] && [ "$mat_col" -ge "$label_col" ] && mat_col_s=$((mat_col + 1))
        local featuresubset_s=""
        local fc
        for fc in "${feature_cols[@]}"; do
            [ "$fc" -ge "$label_col" ] && fc=$((fc + 1))
            featuresubset_s="${featuresubset_s:+$featuresubset_s,}$fc"
        done

        # Train ONLY on the real training rows (1..n_training); never include the
        # appended query row (which has a placeholder label) in training.
        local trainingnums="${BIANCA_TRAININGNUMS:-}"
        if [ -z "$trainingnums" ] || [ "$trainingnums" = "all" ]; then
            # BSD/macOS 'seq -s,' appends a trailing separator; strip it so the
            # list is a clean "1,2,...,N" that BIANCA accepts.
            trainingnums=$(seq -s, 1 "$n_training")
            trainingnums="${trainingnums%,}"
        fi

        bianca_cmd+=(--singlefile="$combined_masterfile")
        bianca_cmd+=(--querysubjectnum="$query_row")
        bianca_cmd+=(--brainmaskfeaturenum="${BIANCA_BRAINMASK_FEATURENUM:-$brainmask_col_s}")
        bianca_cmd+=(--labelfeaturenum="$label_col")
        bianca_cmd+=(--trainingnums="$trainingnums")
        bianca_cmd+=(--featuresubset="${BIANCA_FEATURESUBSET:-$featuresubset_s}")
        if [ -n "${BIANCA_MATFEATURENUM:-}" ]; then
            bianca_cmd+=(--matfeaturenum="$BIANCA_MATFEATURENUM")
        elif [ "$mat_col_s" -gt 0 ]; then
            bianca_cmd+=(--matfeaturenum="$mat_col_s")
        fi
        [ -n "${BIANCA_TRAININGPTS:-}" ] && bianca_cmd+=(--trainingpts="$BIANCA_TRAININGPTS")
        [ -n "${BIANCA_NONLESPTS:-}" ] && bianca_cmd+=(--nonlespts="$BIANCA_NONLESPTS")
        [ -n "${BIANCA_SELECTPTS:-}" ] && bianca_cmd+=(--selectpts="$BIANCA_SELECTPTS")
        # Persist the trained classifier so future runs can reuse it.
        [ -n "${BIANCA_SAVE_CLASSIFIER:-}" ] && bianca_cmd+=(--saveclassifierdata="$BIANCA_SAVE_CLASSIFIER")
        log_message "Training BIANCA from: $BIANCA_TRAINING_MASTERFILE ($n_training subjects), query row $query_row"
    fi

    # Spatial / patch features (tunable via config)
    [ -n "${BIANCA_SPATIALWEIGHT:-}" ] && bianca_cmd+=(--spatialweight="$BIANCA_SPATIALWEIGHT")
    [ -n "${BIANCA_PATCHSIZES:-}" ] && bianca_cmd+=(--patchsizes="$BIANCA_PATCHSIZES")
    [ "${BIANCA_PATCH3D:-false}" = "true" ] && bianca_cmd+=(--patch3D)
    bianca_cmd+=(-o "$bianca_out")
    [ "${BIANCA_VERBOSE:-true}" = "true" ] && bianca_cmd+=(-v)

    # --- Run BIANCA ----------------------------------------------------------
    log_message "Running: ${bianca_cmd[*]}"
    if ! "${bianca_cmd[@]}"; then
        log_formatted "WARNING" "BIANCA execution failed - supervised WMH analysis skipped (non-fatal)"
        return "${ERR_FSL:-21}"
    fi

    # BIANCA writes <output>.nii.gz (probability map).
    local prob_map="${bianca_out}.nii.gz"
    if [ ! -f "$prob_map" ]; then
        log_formatted "WARNING" "BIANCA output probability map not found: $prob_map - skipping post-processing"
        return "${ERR_FSL:-21}"
    fi
    log_formatted "SUCCESS" "BIANCA probability map: $prob_map"

    # --- Threshold to a binary WMH mask --------------------------------------
    local threshold="${BIANCA_THRESHOLD:-0.9}"
    # Validate the threshold is numeric (integer or decimal) before use.
    if ! [[ "$threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_formatted "WARNING" "BIANCA_THRESHOLD='$threshold' is not numeric - falling back to 0.9"
        threshold=0.9
    fi
    local wmh_mask="${out_prefix}_bianca_wmh_thr${threshold}_bin.nii.gz"
    if ! safe_fslmaths "BIANCA threshold" "$prob_map" -thr "$threshold" -bin "$wmh_mask"; then
        log_formatted "WARNING" "Failed to threshold BIANCA probability map - skipping"
        return "${ERR_FSL:-21}"
    fi

    # Optional cluster-size post-processing: drop clusters below BIANCA_MIN_CLUSTER_SIZE.
    local min_cluster="${BIANCA_MIN_CLUSTER_SIZE:-0}"
    if [ -n "${BIANCA_MIN_CLUSTER_SIZE:-}" ] && ! [[ "$min_cluster" =~ ^[0-9]+$ ]]; then
        log_formatted "WARNING" "BIANCA_MIN_CLUSTER_SIZE='$min_cluster' is not a non-negative integer - skipping cluster filtering"
    elif [ "$min_cluster" -gt 0 ]; then
        if command -v cluster >/dev/null 2>&1; then
            local clustered="${out_prefix}_bianca_wmh_clustered.nii.gz"
            if cluster --in="$wmh_mask" --thresh=0.5 --connectivity=26 \
                       --minextent="$min_cluster" --oindex="$clustered" >/dev/null 2>&1; then
                safe_fslmaths "BIANCA cluster bin" "$clustered" -bin "$wmh_mask" || true
                log_message "Applied min-cluster-size post-processing (>= ${min_cluster} voxels)"
            fi
        fi
    fi

    log_formatted "SUCCESS" "BIANCA whole-brain WMH mask: $wmh_mask"
    report_wmh_stats "$wmh_mask" "Whole-brain WMH"

    # --- Brainstem-restricted WMH --------------------------------------------
    local brainstem_mask
    if brainstem_mask=$(find_brainstem_mask); then
        log_message "Brainstem mask: $brainstem_mask"

        # Binarise the brainstem mask (it may be a labelled/intensity volume) and
        # ensure it shares the WMH grid; resample to the WMH mask if needed.
        local bs_bin="${bianca_tmp}/brainstem_bin.nii.gz"
        safe_fslmaths "Brainstem binarise" "$brainstem_mask" -bin "$bs_bin" || bs_bin="$brainstem_mask"

        # Resample brainstem mask to WMH space if dimensions differ.
        # '|| true' guards the pipes against pipefail/set -e on fslinfo failure.
        local wmh_dims bs_dims
        wmh_dims=$(fslinfo "$wmh_mask" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        bs_dims=$(fslinfo "$bs_bin" 2>/dev/null | awk '/^dim[1-3]/{print $2}' | tr '\n' 'x' || true)
        if [ -n "$wmh_dims" ] && [ "$wmh_dims" != "$bs_dims" ] && command -v flirt >/dev/null 2>&1; then
            local bs_resampled="${bianca_tmp}/brainstem_resampled.nii.gz"
            if flirt -in "$bs_bin" -ref "$wmh_mask" -out "$bs_resampled" \
                     -applyxfm -usesqform -interp nearestneighbour >/dev/null 2>&1; then
                safe_fslmaths "Brainstem resample bin" "$bs_resampled" -bin "$bs_bin" || true
            fi
        fi

        local wmh_brainstem="${out_prefix}_bianca_wmh_brainstem.nii.gz"
        if safe_fslmaths "BIANCA brainstem-restricted WMH" "$wmh_mask" -mas "$bs_bin" "$wmh_brainstem"; then
            log_formatted "SUCCESS" "BIANCA brainstem-restricted WMH mask: $wmh_brainstem"
            report_wmh_stats "$wmh_brainstem" "Brainstem WMH"
        else
            log_formatted "WARNING" "Failed to intersect WMH with brainstem mask"
        fi
    else
        log_formatted "WARNING" "No brainstem mask found under ${RESULTS_DIR:-.} - reporting whole-brain WMH only"
        log_formatted "WARNING" "  Run the segmentation stage first to enable brainstem-restricted WMH."
    fi

    log_formatted "SUCCESS" "Supervised WMH detection (BIANCA) completed"
    return 0
}

# ----------------------------------------------------------------------------
# Exports
# ----------------------------------------------------------------------------
export -f bianca_is_available
export -f find_brainstem_mask
export -f report_wmh_stats
export -f run_bianca_wmh

log_message "WMH BIANCA module loaded"
