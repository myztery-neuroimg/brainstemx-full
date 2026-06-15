#!/usr/bin/env bash
#
# brainstem_freesurfer.sh - FreeSurfer brainstem substructure segmentation
#
# Implements docs/brainstem_freesurfer_segmentation_spec.md:
#   recon-all (structural reconstruction) -> segmentBS.sh / segment_subregions
#   brainstem -> brainstemSsLabels (Iglesias 2015 Bayesian segmentation) ->
#   midbrain / pons / medulla / SCP binary masks brought into subject native
#   space.
#
# Honesty ceiling: parcel level only (pons/midbrain/medulla/SCP). The
# inter-parcel boundary is FreeSurfer-asserted; dorsal/ventral pons is never
# produced.
#
# Graceful degradation: when FreeSurfer (FREESURFER_HOME, recon-all,
# segmentBS.sh / segment_subregions) or a FreeSurfer license is unavailable,
# this module logs a clear, non-fatal message and signals the caller to fall
# back to the Harvard-Oxford gross brainstem mask. It never hard-crashes the
# pipeline.
#
set -e -u -o pipefail

# Include guard
if [ -n "${_BRAINSTEM_FS_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_BRAINSTEM_FS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# FreeSurfer brainstemSsLabels label values (FreeSurferColorLUT.txt):
#   173 = Midbrain, 174 = Pons, 175 = Medulla, 178 = SCP
export FS_BS_LABEL_MIDBRAIN="${FS_BS_LABEL_MIDBRAIN:-173}"
export FS_BS_LABEL_PONS="${FS_BS_LABEL_PONS:-174}"
export FS_BS_LABEL_MEDULLA="${FS_BS_LABEL_MEDULLA:-175}"
export FS_BS_LABEL_SCP="${FS_BS_LABEL_SCP:-178}"

# ---------------------------------------------------------------------------
# fs_brainstem_available - detect FreeSurfer brainstem-segmentation capability
#
# Returns 0 if recon-all + (segmentBS.sh or segment_subregions) are available,
# FREESURFER_HOME is set, and a license file exists. Returns 1 otherwise (the
# caller should fall back to the atlas/HO gross mask).
# ---------------------------------------------------------------------------
fs_brainstem_available() {
    log_message "Checking FreeSurfer brainstem-segmentation availability..."

    if [ -z "${FREESURFER_HOME:-}" ]; then
        log_formatted "WARNING" "FREESURFER_HOME is not set; FreeSurfer brainstem segmentation unavailable"
        return 1
    fi

    if ! command -v recon-all >/dev/null 2>&1; then
        log_formatted "WARNING" "recon-all not found on PATH; FreeSurfer brainstem segmentation unavailable"
        return 1
    fi

    if ! command -v segmentBS.sh >/dev/null 2>&1 && ! command -v segment_subregions >/dev/null 2>&1; then
        log_formatted "WARNING" "Neither segmentBS.sh nor segment_subregions found; FreeSurfer brainstem segmentation unavailable"
        return 1
    fi

    # License: $FS_LICENSE, $FREESURFER_HOME/license.txt or .license
    local license_file="${FS_LICENSE:-}"
    if [ -z "$license_file" ]; then
        if [ -f "${FREESURFER_HOME}/license.txt" ]; then
            license_file="${FREESURFER_HOME}/license.txt"
        elif [ -f "${FREESURFER_HOME}/.license" ]; then
            license_file="${FREESURFER_HOME}/.license"
        fi
    fi
    if [ -z "$license_file" ] || [ ! -f "$license_file" ]; then
        log_formatted "WARNING" "FreeSurfer license not found (set FS_LICENSE or place license.txt in FREESURFER_HOME); FreeSurfer brainstem segmentation unavailable"
        return 1
    fi

    # Export the resolved license so recon-all/segmentBS use the SAME file this
    # check validated (otherwise the tools' own discovery could pick a different
    # path and reject the run hours into recon-all).
    export FS_LICENSE="$license_file"

    log_message "  ✓ FreeSurfer brainstem segmentation available (FREESURFER_HOME=$FREESURFER_HOME, license=$license_file)"
    return 0
}

# ---------------------------------------------------------------------------
# fs_record_provenance - record FreeSurfer version for reproducibility
# ---------------------------------------------------------------------------
fs_record_provenance() {
    local provenance_file="$1"

    log_message "Recording FreeSurfer provenance..."

    local fs_version="unknown"
    if [ -f "${FREESURFER_HOME:-}/build-stamp.txt" ]; then
        fs_version="$(cat "${FREESURFER_HOME}/build-stamp.txt" 2>/dev/null || echo unknown)"
    elif command -v recon-all >/dev/null 2>&1; then
        fs_version="$(recon-all --version 2>/dev/null | head -1 || echo unknown)"
    fi

    {
        echo "FreeSurfer brainstem segmentation provenance"
        echo "==========================================="
        echo "Date: $(date)"
        echo "FREESURFER_HOME: ${FREESURFER_HOME:-unset}"
        echo "FreeSurfer version: ${fs_version}"
        echo "Method: brainstemSsLabels (Iglesias 2015)"
    } > "$provenance_file"

    log_message "  ✓ Provenance: $provenance_file"
    return 0
}

# ---------------------------------------------------------------------------
# run_recon_all - run FreeSurfer structural reconstruction (cached/resumable)
#
# Args: <t1_file> <subjects_dir> <subject_id>
# Skips if the recon outputs (aseg.mgz) already exist for the subject.
# ---------------------------------------------------------------------------
run_recon_all() {
    local t1_file="$1"
    local subjects_dir="$2"
    local subject_id="$3"

    log_message "Running FreeSurfer recon-all for subject '$subject_id'..."

    local subject_dir="${subjects_dir}/${subject_id}"
    # segmentBS / segment_subregions need a full recon (norm.mgz, aseg.mgz,
    # talairach transform). Treat aseg.mgz as the completion marker.
    local recon_marker="${subject_dir}/mri/aseg.mgz"

    if [ -f "$recon_marker" ]; then
        log_message "  ✓ recon-all outputs already exist (cached): $recon_marker"
        return 0
    fi

    mkdir -p "$subjects_dir"

    # recon-all level is configurable; default is a full recon (-all) because
    # the brainstem segmentation needs aseg/norm. Apple-Silicon native builds
    # reduce the runtime but it remains hours-long, hence the caching above.
    local recon_flag="${FS_RECON_ALL_FLAG:--all}"
    local recon_threads="${ANTS_THREADS:-4}"

    log_message "  recon-all flag: $recon_flag (threads: $recon_threads)"
    log_message "  This may take several hours; outputs are cached for resumption."

    # SUBJECTS_DIR must point at our results-local subjects directory.
    if ! SUBJECTS_DIR="$subjects_dir" recon-all \
            -i "$t1_file" \
            -s "$subject_id" \
            "$recon_flag" \
            -parallel -openmp "$recon_threads" \
            -sd "$subjects_dir" >/dev/null 2>&1; then
        log_formatted "ERROR" "recon-all failed for subject '$subject_id'"
        return 1
    fi

    if [ ! -f "$recon_marker" ]; then
        log_formatted "ERROR" "recon-all completed but expected output missing: $recon_marker"
        return 1
    fi

    log_message "  ✓ recon-all completed: $subject_dir"
    return 0
}

# ---------------------------------------------------------------------------
# run_brainstem_substructures - run segmentBS / segment_subregions (cached)
#
# Args: <subjects_dir> <subject_id>
# Produces $subject_dir/mri/brainstemSsLabels.*.mgz and echoes its path.
# ---------------------------------------------------------------------------
# fs_find_labels - first brainstemSsLabels*.mgz in an mri dir, SIGPIPE-safe.
# `-print -quit` makes find itself stop after the first hit, so there is no
# `| head` pipe to take SIGPIPE under `set -o pipefail`.
fs_find_labels() {
    local mri_dir="$1"
    find "$mri_dir" -maxdepth 1 -name 'brainstemSsLabels*.mgz' -print -quit 2>/dev/null
}

run_brainstem_substructures() {
    local subjects_dir="$1"
    local subject_id="$2"

    log_message "Running FreeSurfer brainstem substructure segmentation..."

    local subject_dir="${subjects_dir}/${subject_id}"

    # Find an existing brainstemSsLabels volume (cached)
    local existing_labels
    existing_labels=$(fs_find_labels "${subject_dir}/mri")
    if [ -n "$existing_labels" ] && [ -f "$existing_labels" ]; then
        log_message "  ✓ brainstemSsLabels already exists (cached): $existing_labels"
        echo "$existing_labels"
        return 0
    fi

    # Prefer segment_subregions (newer FS); fall back to segmentBS.sh.
    if command -v segment_subregions >/dev/null 2>&1; then
        log_message "  Using segment_subregions brainstem..."
        if ! SUBJECTS_DIR="$subjects_dir" segment_subregions brainstem \
                --cross "$subject_id" --sd "$subjects_dir" >/dev/null 2>&1; then
            log_formatted "WARNING" "segment_subregions brainstem failed; trying segmentBS.sh"
        fi
    fi

    existing_labels=$(fs_find_labels "${subject_dir}/mri")
    if [ -z "$existing_labels" ] && command -v segmentBS.sh >/dev/null 2>&1; then
        log_message "  Using segmentBS.sh..."
        if ! SUBJECTS_DIR="$subjects_dir" segmentBS.sh "$subject_id" "$subjects_dir" >/dev/null 2>&1; then
            log_formatted "ERROR" "segmentBS.sh failed for subject '$subject_id'"
            return 1
        fi
        existing_labels=$(fs_find_labels "${subject_dir}/mri")
    fi

    if [ -z "$existing_labels" ] || [ ! -f "$existing_labels" ]; then
        log_formatted "ERROR" "brainstemSsLabels not produced for subject '$subject_id'"
        return 1
    fi

    log_message "  ✓ brainstemSsLabels: $existing_labels"
    echo "$existing_labels"
    return 0
}

# ---------------------------------------------------------------------------
# fs_labels_to_subject_space - resample brainstemSsLabels into the input grid
#
# FreeSurfer segments the subject's own T1 (conformed 1mm space). Resample the
# label volume back onto the pipeline's input grid using nearest-neighbour so
# downstream masks share the input geometry.
#
# Args: <brainstemSsLabels.mgz> <input_file> <output_labels.nii.gz>
# ---------------------------------------------------------------------------
fs_labels_to_subject_space() {
    local fs_labels="$1"
    local input_file="$2"
    local output_labels="$3"

    log_message "Resampling brainstemSsLabels into subject input grid..."

    if ! command -v mri_convert >/dev/null 2>&1; then
        log_formatted "ERROR" "mri_convert not found; cannot resample FreeSurfer labels"
        return 1
    fi

    # Resample to the input file's grid (nearest neighbour preserves labels).
    if ! mri_convert -rl "$input_file" -rt nearest "$fs_labels" "$output_labels" >/dev/null 2>&1; then
        log_formatted "ERROR" "mri_convert failed to resample brainstemSsLabels to subject space"
        return 1
    fi

    if [ ! -f "$output_labels" ]; then
        log_formatted "ERROR" "Resampled label volume not created: $output_labels"
        return 1
    fi

    log_message "  ✓ Labels in subject space: $output_labels"
    return 0
}

# ---------------------------------------------------------------------------
# fs_split_parcels - split label volume into per-structure binary masks
#
# Writes masks under <detailed_dir> using the filenames the downstream GMM
# per-region path expects:
#   <basename>_midbrain.nii.gz, <basename>_pons.nii.gz,
#   <basename>_medulla.nii.gz, <basename>_scp.nii.gz
# plus left/right hemisphere splits (<basename>_left_pons.nii.gz, ...).
#
# Args: <labels_in_subject_space> <detailed_dir> <basename>
# ---------------------------------------------------------------------------
fs_split_parcels() {
    local labels="$1"
    local detailed_dir="$2"
    local basename="$3"

    log_message "Splitting FreeSurfer parcels into per-structure masks..."

    mkdir -p "$detailed_dir"

    # parcel name -> label value
    declare -A fs_parcels=(
        ["midbrain"]="$FS_BS_LABEL_MIDBRAIN"
        ["pons"]="$FS_BS_LABEL_PONS"
        ["medulla"]="$FS_BS_LABEL_MEDULLA"
        ["scp"]="$FS_BS_LABEL_SCP"
    )

    # Determine midline x voxel for hemisphere splitting from the label grid.
    local dim_x
    dim_x=$(fslval "$labels" dim1)
    local center_x
    center_x=$(echo "$dim_x" | awk '{print int($1/2)}')
    local remaining_x=$((dim_x - center_x))

    local produced=0
    local parcel
    for parcel in "${!fs_parcels[@]}"; do
        local label="${fs_parcels[$parcel]}"
        local parcel_mask="${detailed_dir}/${basename}_${parcel}.nii.gz"

        safe_fslmaths "FS parcel ${parcel}" "$labels" -thr "$label" -uthr "$label" -bin "$parcel_mask" || {
            log_formatted "WARNING" "Failed to extract FS parcel: $parcel"
            continue
        }

        local voxels
        voxels=$(fslstats "$parcel_mask" -V | awk '{print $1}')
        if [ -z "$voxels" ]; then voxels=0; fi

        if [ "$voxels" -gt 0 ]; then
            log_message "  ✓ ${parcel}: ${voxels} voxels"
            produced=$((produced + 1))

            # Left/right hemisphere splits (image x axis).
            local left_mask="${detailed_dir}/${basename}_left_${parcel}.nii.gz"
            local right_mask="${detailed_dir}/${basename}_right_${parcel}.nii.gz"
            safe_fslmaths "FS ${parcel} left" "$parcel_mask" -roi 0 "$center_x" 0 -1 0 -1 0 -1 "$left_mask" || true
            safe_fslmaths "FS ${parcel} right" "$parcel_mask" -roi "$center_x" "$remaining_x" 0 -1 0 -1 0 -1 "$right_mask" || true
        else
            log_formatted "WARNING" "  ${parcel}: 0 voxels (parcel absent or out of grid)"
            rm -f "$parcel_mask"
        fi
    done

    if [ "$produced" -eq 0 ]; then
        log_formatted "ERROR" "No FreeSurfer brainstem parcels produced any voxels"
        return 1
    fi

    log_message "  ✓ Produced $produced FreeSurfer brainstem parcels in $detailed_dir"
    return 0
}

# ---------------------------------------------------------------------------
# fs_brainstem_agreement_qc - FS-union vs HO Brain-Stem Dice + leakage gate
#
# Args: <detailed_dir> <basename> <ho_brainstem_mask> <qc_file>
# Echoes the Dice value on success. Returns 0 if Dice >= threshold AND leakage
# below the cap; returns 1 (low confidence -> caller falls back) otherwise.
# ---------------------------------------------------------------------------
fs_brainstem_agreement_qc() {
    local detailed_dir="$1"
    local basename="$2"
    local ho_brainstem_mask="$3"
    local qc_file="$4"

    log_message "Computing FS-HO brainstem agreement QC..."

    if [ ! -f "$ho_brainstem_mask" ]; then
        log_formatted "WARNING" "Harvard-Oxford brainstem mask not found for agreement QC: $ho_brainstem_mask"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local fs_union="${tmp_dir}/fs_union.nii.gz"

    # Build the FreeSurfer brainstem union from the parcel masks.
    local first=1
    local parcel
    for parcel in midbrain pons medulla scp; do
        local pmask="${detailed_dir}/${basename}_${parcel}.nii.gz"
        [ -f "$pmask" ] || continue
        if [ "$first" -eq 1 ]; then
            safe_fslmaths "FS union init" "$pmask" -bin "$fs_union" || { rm -rf "$tmp_dir"; return 1; }
            first=0
        else
            safe_fslmaths "FS union add" "$fs_union" -add "$pmask" -bin "$fs_union" || { rm -rf "$tmp_dir"; return 1; }
        fi
    done

    if [ "$first" -eq 1 ] || [ ! -f "$fs_union" ]; then
        log_formatted "WARNING" "No FreeSurfer parcels available to build union for QC"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Binarise the HO blob once; reuse for both Dice and leakage. Computing Dice
    # inline (intersection + the two volumes) keeps this module self-contained:
    # no dependency on qa.sh's calculate_dice, and the FS-union volume measured
    # here is reused for the leakage denominator.
    local ho_bin="${tmp_dir}/ho_bin.nii.gz"
    safe_fslmaths "HO bin" "$ho_brainstem_mask" -bin "$ho_bin" || { rm -rf "$tmp_dir"; return 1; }

    local intersection="${tmp_dir}/fs_ho_intersection.nii.gz"
    safe_fslmaths "FS-HO intersection" "$fs_union" -mul "$ho_bin" "$intersection" || { rm -rf "$tmp_dir"; return 1; }

    # Leakage = fraction of FS union voxels falling OUTSIDE the HO blob.
    local outside="${tmp_dir}/fs_outside_ho.nii.gz"
    safe_fslmaths "FS outside HO" "$fs_union" -sub "$ho_bin" -thr 0.5 -bin "$outside" || { rm -rf "$tmp_dir"; return 1; }

    local fs_voxels
    fs_voxels=$(fslstats "$fs_union" -V | awk '{print $1}')
    local ho_voxels
    ho_voxels=$(fslstats "$ho_bin" -V | awk '{print $1}')
    local inter_voxels
    inter_voxels=$(fslstats "$intersection" -V | awk '{print $1}')
    local outside_voxels
    outside_voxels=$(fslstats "$outside" -V | awk '{print $1}')
    if [ -z "$fs_voxels" ] || [ "$fs_voxels" -eq 0 ]; then fs_voxels=1; fi
    if [ -z "$ho_voxels" ]; then ho_voxels=0; fi
    if [ -z "$inter_voxels" ]; then inter_voxels=0; fi
    if [ -z "$outside_voxels" ]; then outside_voxels=0; fi

    # Dice(FS union, HO Brain-Stem) — independent methods, genuine corroboration.
    local denom=$((fs_voxels + ho_voxels))
    local dice="0"
    if [ "$denom" -gt 0 ]; then
        dice=$(echo "scale=4; 2 * $inter_voxels / $denom" | bc)
    fi
    local leakage
    leakage=$(echo "scale=4; $outside_voxels / $fs_voxels" | bc)

    local dice_min="${FS_BS_AGREEMENT_DICE_MIN:-0.7}"
    local leakage_max="${FS_BS_AGREEMENT_LEAKAGE_MAX:-0.2}"

    local status="PASS"
    local agree=0
    if (( $(echo "$dice < $dice_min" | bc -l) )) || (( $(echo "$leakage > $leakage_max" | bc -l) )); then
        status="FAIL_LOW_AGREEMENT"
        agree=1
    fi

    {
        echo "FreeSurfer / Harvard-Oxford brainstem agreement QC"
        echo "=================================================="
        echo "Date: $(date)"
        echo "FS union voxels: $fs_voxels"
        echo "Dice(FS union, HO Brain-Stem): $dice (min: $dice_min)"
        echo "Leakage (FS outside HO): $leakage (max: $leakage_max)"
        echo "Status: $status"
    } > "$qc_file"

    rm -rf "$tmp_dir"

    log_message "  Dice=$dice  Leakage=$leakage  Status=$status"
    echo "$dice"

    if [ "$agree" -eq 1 ]; then
        log_formatted "WARNING" "FS-HO brainstem agreement is LOW (Dice=$dice, leakage=$leakage); FreeSurfer parcels are low-confidence"
        return 1
    fi

    log_formatted "SUCCESS" "FS-HO brainstem agreement OK (Dice=$dice)"
    return 0
}

# ---------------------------------------------------------------------------
# extract_brainstem_freesurfer - top-level FreeSurfer brainstem segmentation
#
# Args: <input_file> <output_prefix> [<ho_brainstem_mask>]
#   input_file        : subject T1 (segmentation reference)
#   output_prefix     : <brainstem_dir>/<basename>
#   ho_brainstem_mask : optional HO Brain-Stem mask for the agreement QC gate
#
# On success the per-parcel masks are written to
# <RESULTS_DIR>/segmentation/detailed_brainstem/ using GMM-compatible names.
# Returns 0 on success (parcels trusted), 1 if FreeSurfer is unavailable / the
# segmentation failed / the agreement gate failed (caller must fall back).
# ---------------------------------------------------------------------------
extract_brainstem_freesurfer() {
    local input_file="$1"
    local output_prefix="$2"
    local ho_brainstem_mask="${3:-}"

    log_formatted "INFO" "=== FREESURFER BRAINSTEM SUBSTRUCTURE SEGMENTATION ==="
    log_message "Input: $input_file"
    log_message "Output prefix: $output_prefix"

    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file does not exist: $input_file"
        return 1
    fi

    if ! fs_brainstem_available; then
        log_formatted "WARNING" "FreeSurfer brainstem segmentation unavailable — falling back to atlas/HO gross mask"
        return 1
    fi

    local basename
    basename=$(basename "$output_prefix")
    local subjects_dir="${RESULTS_DIR}/freesurfer"
    local subject_id="${basename}"
    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
    mkdir -p "$subjects_dir" "$detailed_dir"

    if ! run_recon_all "$input_file" "$subjects_dir" "$subject_id"; then
        log_formatted "WARNING" "recon-all failed — falling back to atlas/HO gross mask"
        return 1
    fi

    local fs_labels
    if ! fs_labels=$(run_brainstem_substructures "$subjects_dir" "$subject_id"); then
        log_formatted "WARNING" "Brainstem substructure segmentation failed — falling back to atlas/HO gross mask"
        return 1
    fi

    local labels_subject="${output_prefix}_brainstemSsLabels.nii.gz"
    if ! fs_labels_to_subject_space "$fs_labels" "$input_file" "$labels_subject"; then
        log_formatted "WARNING" "Failed to bring FreeSurfer labels to subject space — falling back"
        return 1
    fi

    if ! fs_split_parcels "$labels_subject" "$detailed_dir" "$basename"; then
        log_formatted "WARNING" "Failed to split FreeSurfer parcels — falling back"
        return 1
    fi

    # FS-HO agreement gate (when an HO reference mask is available).
    if [ -n "$ho_brainstem_mask" ] && [ -f "$ho_brainstem_mask" ]; then
        local qc_file="${output_prefix}_fs_ho_agreement_qc.txt"
        if ! fs_brainstem_agreement_qc "$detailed_dir" "$basename" "$ho_brainstem_mask" "$qc_file" >/dev/null; then
            log_formatted "WARNING" "FS parcels disagree with HO gross extent — caller should fall back to HO gross mask (low confidence)"
            return 1
        fi
    else
        log_message "No HO reference mask supplied — skipping FS-HO agreement QC"
    fi

    # Record provenance only after the parcels are accepted, so the provenance
    # file is never left behind asserting FreeSurfer was used on a fall-back run.
    fs_record_provenance "${output_prefix}_freesurfer_provenance.txt" || true

    log_formatted "SUCCESS" "FreeSurfer brainstem substructure segmentation completed"
    return 0
}

export -f fs_brainstem_available
export -f fs_record_provenance
export -f run_recon_all
export -f fs_find_labels
export -f run_brainstem_substructures
export -f fs_labels_to_subject_space
export -f fs_split_parcels
export -f fs_brainstem_agreement_qc
export -f extract_brainstem_freesurfer

log_message "FreeSurfer brainstem segmentation module loaded"
