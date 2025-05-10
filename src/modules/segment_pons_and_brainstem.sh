#!/bin/bash
#
# segment_pons_and_brainstem.sh
#
# This script integrates all brainstem segmentation methods (ANTs, SUIT, Juelich)
# and ensures all outputs are in MNI standard space for consistent comparison.

# Source the environment settings
source "$(dirname "$0")/environment.sh"

segment_brainstem_comprehensive() {
    local input_file="$1"
    local output_prefix="${2:-DiCOM}"
    
    # Create output directories
    local brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    local pons_dir="${RESULTS_DIR}/segmentation/pons"
    mkdir -p "$brainstem_dir" "$pons_dir"
    
    log_message "Starting comprehensive brainstem and pons segmentation for $input_file"
    
    # Check if input file exists
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $input_file does not exist"
        return 1
    fi
    
    # Ensure we have SUIT directory set
    if [ -z "$SUIT_DIR" ]; then
        log_formatted "ERROR" "SUIT_DIR environment variable is not set"
        return 1
    fi
    
    # Check if SUIT directory exists
    if [ ! -d "$SUIT_DIR" ]; then
        log_formatted "ERROR" "SUIT directory $SUIT_DIR does not exist"
        return 1
    fi

    # Run the Python segmentation script
    log_message "Running advanced segmentation with SUIT, ANTs, and Juelich atlas..."
    python3 "$(dirname "$0")/segment_pons_suitlib.py" \
        "$input_file" \
        --output-dir "$RESULTS_DIR" \
        --suit-dir "$SUIT_DIR" \
        --prefix "$output_prefix"
    
    # Check if segmentation was successful by checking that main output files exist
    local required_files=(
        "${brainstem_dir}/${output_prefix}_brainstem.nii.gz"
        "${pons_dir}/${output_prefix}_pons.nii.gz"
        "${pons_dir}/${output_prefix}_dorsal_pons.nii.gz"
        "${pons_dir}/${output_prefix}_ventral_pons.nii.gz"
    )
    
    # Check all required files
    missing_files=false
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_formatted "WARNING" "Brainstem file not found: $file"
            missing_files=true
        fi
    done
    
    # Create intensity versions of segmentation masks (these should already be created by Python script,
    # but this is a backup in case they weren't)
    log_message "Creating intensity versions of segmentation masks for better visualization..."
    for mask_type in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
        local mask_file="${brainstem_dir}/${output_prefix}_${mask_type}.nii.gz"
        if [ "$mask_type" != "brainstem" ]; then
            mask_file="${pons_dir}/${output_prefix}_${mask_type}.nii.gz"
        fi
        
        local intensity_file="${mask_file%.nii.gz}_intensity.nii.gz"
        
        log_message "Creating intensity mask from binary mask..."
        log_message "Binary mask: $mask_file"
        log_message "Intensity image: ${RESULTS_DIR}/standardized/${output_prefix}_std.nii.gz"
        log_message "Output: $intensity_file"
        
        if [ -f "$mask_file" ] && [ -f "${RESULTS_DIR}/standardized/${output_prefix}_std.nii.gz" ]; then
            fslmaths "$mask_file" -mas "${RESULTS_DIR}/standardized/${output_prefix}_std.nii.gz" "$intensity_file"
        else
            log_formatted "WARNING" "Could not create intensity mask: $intensity_file (files not found)"
        fi
    done
    
    # Validate segmentation
    log_message "Validating segmentation..."
    validate_segmentation "${RESULTS_DIR}/standardized/${output_prefix}_std.nii.gz" \
        "${brainstem_dir}/${output_prefix}_brainstem.nii.gz" \
        "${pons_dir}/${output_prefix}_pons.nii.gz" \
        "${pons_dir}/${output_prefix}_dorsal_pons.nii.gz" \
        "${pons_dir}/${output_prefix}_ventral_pons.nii.gz"
    
    if $missing_files; then
        log_formatted "WARNING" "Some required segmentation files are missing. Check logs for details."
        return 1
    else
        log_message "Brainstem and pons segmentation completed successfully"
        return 0
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly
    segment_brainstem_comprehensive "$1" "$2"
fi
export segment_brainstem_comprehensive
