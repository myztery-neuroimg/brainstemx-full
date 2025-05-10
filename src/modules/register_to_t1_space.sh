#!/usr/bin/env bash
#
# register_to_t1_space.sh - Helper script for registering images to T1 space using ANTs
#
# This module provides functions for:
# 1. Registering T2/FLAIR images to T1 space without white matter segmentation
# 2. Registering atlas/mask images to subject T1 space
# 3. Validating registration results and ensuring correct filename handling
#

# Source environment.sh to get access to logging and utility functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/environment.sh"

# Function to register a FLAIR/T2 image to T1 reference space
# This bypasses the white matter segmentation step that often causes issues
register_flair_to_t1() {
    local flair_image="$1"
    local t1_reference="$2"
    local output_dir="${3:-$(dirname "$flair_image")}"
    local output_prefix="${4:-$(basename "$flair_image" .nii.gz)_reg}"
    
    # Ensure consistent naming by extracting just the filename
    local flair_basename=$(basename "$flair_image" .nii.gz)
    
    # Create full output path
    local full_output_prefix="${output_dir}/${output_prefix}"
    
    log_formatted "INFO" "===== REGISTERING FLAIR/T2 TO T1 SPACE USING ANTs SyN ====="
    log_message "FLAIR/T2 image: $flair_image"
    log_message "T1 reference: $t1_reference"
    log_message "Output directory: $output_dir"
    log_message "Output prefix: $full_output_prefix"
    
    # Create output directory if needed
    mkdir -p "$output_dir"
    
    # Create a modified antsRegistrationSyN.sh script that doesn't modify intensities
    local temp_script="${output_dir}/no_intensity_mod_ants_script.sh"
    
    # Copy the original script and modify it to remove intensity manipulation
    if command -v antsRegistrationSyN.sh &> /dev/null; then
        local original_script=$(command -v antsRegistrationSyN.sh)
        cp "$original_script" "$temp_script"
        # Remove winsorizing to prevent intensity manipulation
        sed -i.bak 's/--winsorize-image-intensities \[ 0.005,0.995 \]//' "$temp_script"
        chmod +x "$temp_script"
        log_message "Created modified ANTs script without intensity manipulation at: $temp_script"
    else
        log_formatted "ERROR" "Cannot find antsRegistrationSyN.sh script to modify"
        return 1
    fi

    # Execute ANTs registration with proper logging and error handling
    # Using modified script with NO intensity manipulation
    execute_ants_command "direct_syn" "Direct ANTs SyN registration of FLAIR/T2 to T1 without intensity manipulation" \
        "$temp_script" \
        -d 3 \
        -f "$t1_reference" \
        -m "$flair_image" \
        -o "${full_output_prefix}_" \
        -t s \
        -n 12 \
        -p f \
        -x MI
    
    local ants_status=$?
    
    # Check if registration was successful
    if [ $ants_status -ne 0 ]; then
        log_formatted "ERROR" "ANTs SyN registration failed with status $ants_status"
        return $ants_status
    fi
    
    # Check if expected output files exist
    if [ ! -f "${full_output_prefix}_Warped.nii.gz" ]; then
        log_formatted "ERROR" "Expected output file not found: ${full_output_prefix}_Warped.nii.gz"
        return 1
    fi
    
    # IMPORTANT: Create a copy with the exact filename expected by validation processes
    # This ensures downstream processes will find the registered file with consistent naming
    cp "${full_output_prefix}_Warped.nii.gz" "${output_dir}/${flair_basename}_reg.nii.gz"
    
    # Also copy the transform file with a consistent name
    cp "${full_output_prefix}_0GenericAffine.mat" "${output_dir}/${flair_basename}_to_t1.mat"
    
    log_formatted "SUCCESS" "FLAIR/T2 to T1 registration complete"
    log_message "Registered image: ${output_dir}/${flair_basename}_reg.nii.gz"
    log_message "Transform: ${output_dir}/${flair_basename}_to_t1.mat"
    
    # Validate the registration to ensure quality
    validate_registration_result "$t1_reference" "${output_dir}/${flair_basename}_reg.nii.gz" "$output_dir"
    
    return 0
}

# Function to validate a registration result
validate_registration_result() {
    local reference="$1"
    local registered="$2"
    local output_dir="${3:-$(dirname "$registered")}/validation"
    
    log_formatted "INFO" "===== VALIDATING REGISTRATION RESULT ====="
    log_message "Reference: $reference"
    log_message "Registered image: $registered"
    log_message "Output directory: $output_dir"
    
    mkdir -p "$output_dir"
    
    # Create normalized images for comparison (each in their own intensity space)
    local ref_norm="${output_dir}/reference_norm.nii.gz"
    local reg_norm="${output_dir}/registered_norm.nii.gz"
    
    log_message "Creating normalized images (each in their own intensity space)"
    # Use -inm 1 to normalize each image to its own [0,1] range
    # This preserves the relative intensity relationships within each modality
    fslmaths "$reference" -inm 1 "$ref_norm"
    fslmaths "$registered" -inm 1 "$reg_norm"
    
    # Calculate difference map
    local diff_map="${output_dir}/difference_map.nii.gz"
    log_message "Calculating difference map"
    fslmaths "$ref_norm" -sub "$reg_norm" -abs "$diff_map"
    
    # Calculate metrics
    local mean_diff=$(fslstats "$diff_map" -M)
    local max_diff=$(fslstats "$diff_map" -R | awk '{print $2}')
    
    # Calculate mutual information
    local mi=$(fslcc -t 1 "$reference" "$registered" | tail -n 1 | awk '{print $3}')
    
    # Calculate cross-correlation
    local cc=$(fslcc -t 0 "$reference" "$registered" | tail -n 1 | awk '{print $3}')
    
    # Create report
    {
        echo "Registration Validation Report"
        echo "============================="
        echo "Date: $(date)"
        echo ""
        echo "Images:"
        echo "  Reference: $reference"
        echo "  Registered: $registered"
        echo ""
        echo "Metrics:"
        echo "  Mean Absolute Difference: $mean_diff"
        echo "  Maximum Absolute Difference: $max_diff"
        echo "  Mutual Information: $mi"
        echo "  Cross-Correlation: $cc"
        echo ""
        echo "Quality Assessment:"
        if (( $(echo "$cc > 0.7" | bc -l) )); then
            echo "  EXCELLENT"
        elif (( $(echo "$cc > 0.5" | bc -l) )); then
            echo "  GOOD"
        elif (( $(echo "$cc > 0.3" | bc -l) )); then
            echo "  ACCEPTABLE"
        else
            echo "  POOR - Registration may need improvement"
        fi
    } > "${output_dir}/validation_report.txt"
    
    log_message "Validation report written to: ${output_dir}/validation_report.txt"
    
    return 0
}

# Function to register atlas or mask image to subject's T1 space
register_atlas_to_t1() {
    local atlas_image="$1"
    local t1_reference="$2"
    local output_dir="${3:-$(dirname "$atlas_image")}"
    local output_prefix="${4:-$(basename "$atlas_image" .nii.gz)_to_subject}"
    
    # Extract just the filename without path
    local atlas_basename=$(basename "$atlas_image" .nii.gz)
    
    # Create full output path
    local full_output_prefix="${output_dir}/${output_prefix}"
    
    log_formatted "INFO" "===== REGISTERING ATLAS/MASK TO SUBJECT T1 SPACE ====="
    log_message "Atlas/mask image: $atlas_image"
    log_message "T1 reference: $t1_reference"
    log_message "Output directory: $output_dir"
    log_message "Output prefix: $full_output_prefix"
    
    # Create output directory if needed
    mkdir -p "$output_dir"
    
    # Use the same no-intensity-manipulation approach
    local temp_script="${output_dir}/no_intensity_mod_ants_script.sh"
    
    # Create modified script if it doesn't exist yet
    if [ ! -f "$temp_script" ] && command -v antsRegistrationSyN.sh &> /dev/null; then
        local original_script=$(command -v antsRegistrationSyN.sh)
        cp "$original_script" "$temp_script"
        # Remove winsorizing to prevent intensity manipulation
        sed -i.bak 's/--winsorize-image-intensities \[ 0.005,0.995 \]//' "$temp_script"
        chmod +x "$temp_script"
        log_message "Created modified ANTs script without intensity manipulation at: $temp_script"
    fi
    
    # Execute ANTs registration with proper logging and error handling
    # Using modified script with NO intensity manipulation
    execute_ants_command "atlas_reg" "Registering atlas/mask to subject T1 space without intensity manipulation" \
        "$temp_script" \
        -d 3 \
        -f "$t1_reference" \
        -m "$atlas_image" \
        -o "${full_output_prefix}_" \
        -t s \
        -n 12 \
        -p f
    
    local ants_status=$?
    
    # Check if registration was successful
    if [ $ants_status -ne 0 ]; then
        log_formatted "ERROR" "Atlas registration failed with status $ants_status"
        return $ants_status
    fi
    
    # Check if expected output files exist
    if [ ! -f "${full_output_prefix}_Warped.nii.gz" ]; then
        log_formatted "ERROR" "Expected output file not found: ${full_output_prefix}_Warped.nii.gz"
        return 1
    fi
    
    # Create a copy with consistent naming convention
    cp "${full_output_prefix}_Warped.nii.gz" "${output_dir}/${atlas_basename}_in_subject.nii.gz"
    
    log_formatted "SUCCESS" "Atlas/mask registration complete"
    log_message "Registered atlas: ${output_dir}/${atlas_basename}_in_subject.nii.gz"
    
    return 0
}

# Main function to run the script from command line
main() {
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <mode> <image> <reference> [output_dir] [output_prefix]"
        echo ""
        echo "Modes:"
        echo "  flair   - Register FLAIR/T2 image to T1 reference"
        echo "  atlas   - Register atlas/mask image to T1 reference"
        echo ""
        echo "Arguments:"
        echo "  <mode>         - Registration mode (flair or atlas)"
        echo "  <image>        - FLAIR, T2 or atlas image to register"
        echo "  <reference>    - T1 reference image"
        echo "  [output_dir]   - Output directory (default: same as input image)"
        echo "  [output_prefix] - Output filename prefix (default: input filename + _reg)"
        echo ""
        echo "Example:"
        echo "  $0 flair ../mri_results/standardized/T2_SPACE_FLAIR_Sag_CS_17a_n4_brain_std.nii.gz ../mri_results/standardized/T1_MPRAGE_SAG_12a_n4_brain_std.nii.gz ../mri_results/validation/space/t1_flair/"
        return 1
    fi
    
    local mode="$1"
    local image="$2"
    local reference="$3"
    local output_dir="${4:-$(dirname "$image")}"
    local output_prefix="${5:-}"
    
    case "$mode" in
        "flair")
            register_flair_to_t1 "$image" "$reference" "$output_dir" "$output_prefix"
            ;;
        "atlas")
            register_atlas_to_t1 "$image" "$reference" "$output_dir" "$output_prefix"
            ;;
        *)
            echo "Unknown mode: $mode"
            echo "Valid modes: flair, atlas"
            return 1
            ;;
    esac
    
    return $?
}

# Make functions available to sourcing scripts
export -f register_flair_to_t1 register_atlas_to_t1 validate_registration_result

# Execute main function if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi