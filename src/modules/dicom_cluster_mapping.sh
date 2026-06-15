#!/usr/bin/env bash
#
# dicom_cluster_mapping.sh - Map hyperintensity clusters back to source DICOM files
#
# Rewrite (2026): real reverse spatial chain + pydicom slice matching.
#
# Spatial premise (verified against the pipeline)
# -----------------------------------------------
# Clusters are detected in `orig_flair` space - the brain-extracted FLAIR, which
# PRESERVES the original native FLAIR voxel grid (brain extraction either runs on
# the native image directly or maps its mask back onto the native grid via
# map_mask_to_original_grid in utils.sh). The cluster INDEX volume
# (`clusters.nii.gz`, integer ids, written by analyze_hyperintensity_clusters in
# qa.sh) is therefore already on the native FLAIR grid, whose NIfTI sform encodes
# the scanner geometry dcm2niix wrote. The reverse step back to the original
# native FLAIR grid is consequently an IDENTITY transform: a pure resample onto
# the native reference (no ANTs -t transforms). We deliberately do NOT apply the
# contrast-matched cascade's T1<->secondary inverse chain here - those map T1 to
# a DIFFERENT modality (DWI/SWI/T2) and would displace the FLAIR-space clusters.
#
# Flow
# ----
#   1. Consume the machine-readable cluster INDEX volume (clusters.nii.gz).
#   2. Resample it onto the original native FLAIR grid with
#      `antsApplyTransforms -n GenericLabel` (identity transform; GenericLabel
#      preserves discrete cluster ids). The COG is re-derived on that grid.
#   3. Hand the native-grid index volume + the source DICOM directory to
#      map_clusters_to_dicom.py (nibabel + pydicom): COG voxel -> world mm
#      (sform) -> DICOM LPS patient mm (RAS->LPS flip) and nearest source DICOM
#      slice by ImagePositionPatient / ImageOrientationPatient slice-normal
#      projection (full 3D distance), emitting InstanceNumber + SOPInstanceUID +
#      SliceLocation + a WithinTolerance flag per cluster.
#   4. If pydicom is unavailable, fall back to a dcmdump-based matcher.
#
# Outputs (per cluster index volume processed, under <output_dir>):
#   <name>_dicom_mapping.csv   machine-readable mapping (one row per cluster)
#   <name>_dicom_mapping.txt   human-readable report
#   cluster_dicom_mapping_summary.txt
#

set -o pipefail

# Lightweight environment guard (logging, ERR_* codes, path helpers).
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# Resolve the python launcher (uv-managed venv) the rest of the pipeline uses.
# Validate the ACTUAL runtime deps (numpy/nibabel), not just a bare interpreter,
# so a venv that has never been `uv sync`'d surfaces a clear hint instead of a
# late ImportError.
_dicom_python_cmd() {
    if command -v uv >/dev/null 2>&1 && \
       uv run --no-sync python -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "uv run --no-sync python"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1 && \
       python3 -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    return 1
}

# Resample a cluster index volume onto the ORIGINAL native FLAIR grid.
# The cluster index is already in native FLAIR space, so this is an IDENTITY
# transform (pure resample onto the native reference grid). Falls back to copying
# the input when ANTs / the native reference is unavailable.
resample_index_to_native() {
    local index_volume="$1"      # clusters.nii.gz (native FLAIR grid)
    local native_reference="$2"  # original native FLAIR (defines target grid)
    local output_volume="$3"

    mkdir -p "$(dirname "$output_volume")"

    local ants_bin="${ANTS_BIN:-${ANTS_PATH:-}/bin}"
    local ants_apply="${ants_bin}/antsApplyTransforms"
    command -v "$ants_apply" >/dev/null 2>&1 || ants_apply="antsApplyTransforms"

    if [ -z "$native_reference" ] || [ ! -f "$native_reference" ] || \
       ! command -v "$ants_apply" >/dev/null 2>&1; then
        log_formatted "WARNING" "Native reference or antsApplyTransforms unavailable - using cluster grid directly"
        cp -f "$index_volume" "$output_volume"
        return 0
    fi

    log_message "Resampling cluster index onto native FLAIR grid (identity transform)"

    # GenericLabel preserves discrete cluster ids across the resample. No -t
    # transforms: the cluster index already lives on the native FLAIR grid.
    "$ants_apply" -d 3 -n GenericLabel \
        -i "$index_volume" -r "$native_reference" -o "$output_volume" \
        >/dev/null 2>&1 || true

    if [ ! -f "$output_volume" ]; then
        log_formatted "WARNING" "Resample to native grid failed - using cluster grid directly"
        cp -f "$index_volume" "$output_volume"
    fi
    return 0
}

# Sniff whether a file is DICOM: .dcm/.ima extension, or the DICM magic at
# offset 128 (mirrors the Python path so extension-less exports are found too).
_is_dicom_file() {
    local f="$1"
    case "${f,,}" in
        *.dcm|*.ima) return 0 ;;
    esac
    [ "$(dd if="$f" bs=1 skip=128 count=4 2>/dev/null)" = "DICM" ]
}

# dcmdump fallback matcher: nearest ImagePositionPatient slice by full 3D
# distance to the cluster's DICOM (LPS) coordinate read from the CSV. Used only
# when pydicom found no matches (the Python tool then leaves match columns
# empty, so DICOM_X/Y/Z are the only populated DICOM columns - all numeric and
# comma-free, safe for awk -F',').
match_with_dcmdump() {
    local coords_csv="$1"     # CSV from map_clusters_to_dicom.py (coords populated)
    local dicom_directory="$2"
    local output_csv="$3"
    local tolerance="${4:-5.0}"

    command -v dcmdump >/dev/null 2>&1 || return 1
    log_message "Matching clusters to DICOM slices via dcmdump fallback"

    # Build a slice table: file<TAB>x<TAB>y<TAB>z<TAB>instance<TAB>sop<TAB>slloc
    local slices_tbl
    slices_tbl="$(mktemp)"
    local dicom_file
    while IFS= read -r dicom_file; do
        [ -f "$dicom_file" ] || continue
        _is_dicom_file "$dicom_file" || continue
        local ipp instance sop slloc
        ipp=$(dcmdump +P ImagePositionPatient "$dicom_file" 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/' | head -1)
        [ -n "$ipp" ] || continue
        instance=$(dcmdump +P InstanceNumber "$dicom_file" 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/' | head -1)
        sop=$(dcmdump +P SOPInstanceUID "$dicom_file" 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/' | head -1)
        slloc=$(dcmdump +P SliceLocation "$dicom_file" 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/' | head -1)
        local px py pz
        px=$(echo "$ipp" | awk -F'\\\\' '{print $1}')
        py=$(echo "$ipp" | awk -F'\\\\' '{print $2}')
        pz=$(echo "$ipp" | awk -F'\\\\' '{print $3}')
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$dicom_file" "${px:-0}" "${py:-0}" "${pz:-0}" "${instance:-}" "${sop:-}" "${slloc:-}" \
            >> "$slices_tbl"
    done < <(find "$dicom_directory" -type f 2>/dev/null)

    if [ ! -s "$slices_tbl" ]; then
        rm -f "$slices_tbl"
        return 1
    fi

    # Rewrite the CSV, filling match columns by nearest 3D distance. AWK keeps
    # everything in one process (no subshell variable-loss). The matched path is
    # CSV-quoted (it may legally contain a comma); numeric/id fields do not.
    awk -F',' -v OFS=',' -v sl="$slices_tbl" -v tol="$tolerance" '
        function csvq(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
        BEGIN {
            n = 0
            while ((getline line < sl) > 0) {
                split(line, f, "\t")
                n++
                sf[n] = f[1]; sx[n] = f[2]; sy[n] = f[3]; sz[n] = f[4]
                si[n] = f[5]; ss[n] = f[6]; sloc[n] = f[7]
            }
        }
        NR == 1 { print; next }   # header passthrough
        {
            dx = $9; dy = $10; dz = $11   # DICOM_{X,Y,Z}_mm columns
            best = -1; bestd = 1e18
            for (i = 1; i <= n; i++) {
                d = sqrt((dx - sx[i])^2 + (dy - sy[i])^2 + (dz - sz[i])^2)
                if (d < bestd) { bestd = d; best = i }
            }
            if (best > 0) {
                $12 = csvq(sf[best]); $14 = si[best]; $15 = ss[best]
                $16 = sloc[best]; $17 = sprintf("%.4f", bestd)
                $18 = (bestd <= tol) ? "yes" : "no"
            }
            print
        }
    ' "$coords_csv" > "$output_csv"

    rm -f "$slices_tbl"
    return 0
}

# Map clusters from one cluster index volume to source DICOM files.
map_cluster_index_to_dicom() {
    local index_volume="$1"      # clusters.nii.gz
    local native_reference="$2"  # original native FLAIR (target grid)
    local dicom_directory="$3"
    local output_prefix="$4"     # e.g. <output_dir>/clusters
    local tolerance="${5:-5.0}"

    log_formatted "INFO" "===== MAPPING CLUSTER INDEX TO DICOM ====="
    log_message "Cluster index: $index_volume"
    log_message "Native reference: ${native_reference:-<none>}"
    log_message "DICOM directory: $dicom_directory"

    if [ ! -f "$index_volume" ]; then
        log_formatted "ERROR" "Cluster index volume not found: $index_volume"
        return 1
    fi

    mkdir -p "$(dirname "$output_prefix")"

    # Step 1: resample the cluster index onto the original native grid (identity).
    local native_index="${output_prefix}_native_index.nii.gz"
    resample_index_to_native "$index_volume" "$native_reference" "$native_index"

    # Step 2: COG -> world mm -> DICOM LPS + slice matching (pydicom).
    local out_csv="${output_prefix}_dicom_mapping.csv"
    local out_txt="${output_prefix}_dicom_mapping.txt"
    local py_cmd
    if ! py_cmd=$(_dicom_python_cmd); then
        log_formatted "WARNING" "No python interpreter available - cannot map clusters"
        return 1
    fi

    local py_script py_summary py_status
    py_script="$(dirname "${BASH_SOURCE[0]}")/map_clusters_to_dicom.py"
    # Capture stdout (the machine-readable SUMMARY line) while letting stderr
    # diagnostics flow to the log. `|| true` keeps set -e from aborting before
    # we read the status (the graceful WARNING path below handles failures).
    # shellcheck disable=SC2086  # py_cmd is an intentional multi-word launcher
    py_summary=$($py_cmd "$py_script" \
        --index "$native_index" \
        --dicom-dir "$dicom_directory" \
        --out-csv "$out_csv" \
        --out-txt "$out_txt" \
        --tolerance "$tolerance") && py_status=0 || py_status=$?

    if [ "${py_status:-1}" -ne 0 ] || [ ! -f "$out_csv" ]; then
        log_formatted "WARNING" "Python mapping failed (status ${py_status:-?}) - ensure 'uv sync' has installed nibabel/numpy/pydicom"
        return 1
    fi
    [ -n "$py_summary" ] && log_message "Mapping summary: $py_summary"

    # Step 3: if pydicom left match columns empty (matched=0 in the summary), try
    # the dcmdump fallback. DICOM_X/Y/Z (cols 9-11) are numeric and comma-free,
    # so the awk fallback parses them safely.
    if echo "$py_summary" | grep -q "matched=0"; then
        log_message "No DICOM matches from pydicom - attempting dcmdump fallback"
        local fallback_csv="${out_csv%.csv}_dcmdump.csv"
        if match_with_dcmdump "$out_csv" "$dicom_directory" "$fallback_csv" "$tolerance"; then
            mv -f "$fallback_csv" "$out_csv"
            log_message "dcmdump fallback populated DICOM matches"
        else
            log_message "dcmdump fallback unavailable - coordinates emitted without file matches"
        fi
    fi

    log_formatted "SUCCESS" "Cluster->DICOM mapping written: $out_csv"
    return 0
}

# Locate the original native FLAIR used as the cluster/analysis grid reference.
find_native_flair_reference() {
    local results_dir="$1"
    local ref=""
    ref=$(find "${results_dir}/brain_extraction" -iname "*FLAIR*brain.nii.gz" 2>/dev/null | head -1)
    if [ -z "$ref" ] && [ -n "${EXTRACT_DIR:-}" ]; then
        ref=$(find "${EXTRACT_DIR}" -iname "*FLAIR*.nii.gz" ! -iname "*Mask*" 2>/dev/null | head -1)
    fi
    echo "$ref"
}

# Main orchestration: discover cluster index volume(s) and map each to DICOM.
perform_cluster_to_dicom_mapping() {
    local cluster_analysis_dir="$1"   # dir containing clusters.nii.gz
    local results_dir="$2"            # pipeline results directory
    local dicom_directory="$3"        # original DICOM directory
    local output_dir="${4:-${cluster_analysis_dir}/dicom_mapping}"
    local tolerance="${5:-${DICOM_MATCH_TOLERANCE_MM:-5.0}}"

    log_formatted "INFO" "===== PERFORMING CLUSTER-TO-DICOM MAPPING ====="
    log_message "Cluster analysis: $cluster_analysis_dir"
    log_message "Results directory: $results_dir"
    log_message "DICOM directory: $dicom_directory"
    log_message "Output directory: $output_dir"

    mkdir -p "$output_dir"

    # The machine-readable input contract: the cluster INDEX volume(s).
    local index_volumes=()
    while IFS= read -r -d '' vol; do
        index_volumes+=("$vol")
    done < <(find "$cluster_analysis_dir" -name "clusters.nii.gz" -type f -print0 2>/dev/null)

    if [ ${#index_volumes[@]} -eq 0 ]; then
        log_formatted "ERROR" "No cluster index volume (clusters.nii.gz) found in $cluster_analysis_dir"
        return 1
    fi
    log_message "Found ${#index_volumes[@]} cluster index volume(s)"

    local native_reference
    native_reference=$(find_native_flair_reference "$results_dir")
    log_message "Native FLAIR reference: ${native_reference:-<none found>}"

    local mapped=0
    local index_volume
    for index_volume in "${index_volumes[@]}"; do
        local label
        label=$(basename "$(dirname "$index_volume")")
        [ "$label" = "." ] && label="clusters"
        local output_prefix="${output_dir}/${label}"
        if map_cluster_index_to_dicom \
            "$index_volume" "$native_reference" "$dicom_directory" \
            "$output_prefix" "$tolerance"; then
            mapped=$((mapped + 1))
        else
            log_formatted "WARNING" "Mapping failed for $index_volume"
        fi
    done

    # Summary report.
    local summary_report="${output_dir}/cluster_dicom_mapping_summary.txt"
    {
        echo "Cluster-to-DICOM Mapping Summary"
        echo "================================"
        echo "Generated: $(date)"
        echo "Cluster analysis directory: $cluster_analysis_dir"
        echo "DICOM directory: $dicom_directory"
        echo "Native reference: ${native_reference:-<none>}"
        echo "Index volumes mapped: ${mapped}/${#index_volumes[@]}"
        echo ""
        echo "Mapping files:"
        find "$output_dir" -name "*_dicom_mapping.csv" -exec basename {} \; 2>/dev/null | sort | sed 's/^/  - /'
    } > "$summary_report"

    log_formatted "SUCCESS" "Cluster-to-DICOM mapping complete (${mapped}/${#index_volumes[@]} index volume(s))"
    log_message "Summary report: $summary_report"
    log_message "Output directory: $output_dir"

    [ "$mapped" -gt 0 ] && return 0 || return 1
}

# Export functions
export -f resample_index_to_native
export -f match_with_dcmdump
export -f map_cluster_index_to_dicom
export -f find_native_flair_reference
export -f perform_cluster_to_dicom_mapping

log_message "DICOM cluster mapping module loaded"
