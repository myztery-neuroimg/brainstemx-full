#!/usr/bin/env bash
#
# registration.sh - Registration functions for the brain MRI processing pipeline
#
# This module contains:
# - T2-SPACE-FLAIR to T1MPRAGE registration
# - Registration visualization
# - Registration QA integration
#

# Function to register FLAIR to T1
register_t2_flair_to_t1mprage() {
    # Usage: register_t2_flair_to_t1mprage <T1_file.nii.gz> <FLAIR_file.nii.gz> <output_prefix>
    #
    # If T1 and FLAIR have identical dimensions & orientation, you might only need a
    # simple identity transform or a short rigid alignment.
    # This function uses antsRegistrationSyN for a minimal transformation.

    local t1_file="$1"
    local flair_file="$2"
    local out_prefix="${3:-${RESULTS_DIR}/registered/t1_to_flair}"

    if [ ! -f "$t1_file" ] || [ ! -f "$flair_file" ]; then
        log_formatted "ERROR" "T1 or FLAIR file not found"
        return 1
    fi

    log_message "=== Registering FLAIR to T1 ==="
    log_message "T1: $t1_file"
    log_message "FLAIR: $flair_file"
    log_message "Output prefix: $out_prefix"

    # Create output directory
    mkdir -p "$(dirname "$out_prefix")"

    # If T1 & FLAIR are from the same 3D session, we can use a simpler transform
    # -t r => rigid. For cross-modality, we can specify 'MI' or 'CC'.
    # antsRegistrationSyN.sh defaults to 's' (SyN) with reg type 'r' or 'a'.
    
    antsRegistrationSyN.sh \
      -d 3 \
      -f "$t1_file" \
      -m "$flair_file" \
      -o "$out_prefix" \
      -t r \
      -n 4 \
      -p f \
      -j 1 \
      -x "$REG_METRIC_CROSS_MODALITY"

    # The Warped file => ${out_prefix}Warped.nii.gz
    # The transform(s) => ${out_prefix}0GenericAffine.mat, etc.

    log_message "Registration complete. Warped FLAIR => ${out_prefix}Warped.nii.gz"
    
    # Validate the registration
    validate_registration "$t1_file" "$flair_file" "${out_prefix}Warped.nii.gz" "${out_prefix}"
    
    return 0
}

# Function to create registration visualizations
create_registration_visualizations() {
    local fixed="$1"
    local moving="$2"
    local warped="${3:-${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz}"
    local output_dir="${4:-${RESULTS_DIR}/validation/registration}"
    
    log_message "Creating registration visualizations"
    mkdir -p "$output_dir"
    
    # Create checkerboard pattern for registration check
    local checker="${output_dir}/checkerboard.nii.gz"
    
    # Use FSL's checkerboard function
    fslcpgeom "$fixed" "$warped"  # Ensure geometry is identical
    fslmaths "$fixed" -mul 0 "$checker"  # Initialize empty volume
    
    # Create 5x5x5 checkerboard
    local dim_x=$(fslval "$fixed" dim1)
    local dim_y=$(fslval "$fixed" dim2)
    local dim_z=$(fslval "$fixed" dim3)
    
    local block_x=$((dim_x / 5))
    local block_y=$((dim_y / 5))
    local block_z=$((dim_z / 5))
    
    for ((x=0; x<5; x++)); do
        for ((y=0; y<5; y++)); do
            for ((z=0; z<5; z++)); do
                if [ $(( (x+y+z) % 2 )) -eq 0 ]; then
                    # Use fixed image for this block
                    fslmaths "$fixed" -roi $((x*block_x)) $block_x $((y*block_y)) $block_y $((z*block_z)) $block_z 0 1 \
                             -add "$checker" "$checker"
                else
                    # Use moving image for this block
                    fslmaths "$warped" -roi $((x*block_x)) $block_x $((y*block_y)) $block_y $((z*block_z)) $block_z 0 1 \
                             -add "$checker" "$checker"
                fi
            done
        done
    done
    
    # Create overlay command for fsleyes
    echo "fsleyes $checker" > "${output_dir}/view_registration_check.sh"
    chmod +x "${output_dir}/view_registration_check.sh"
    
    # Create slices for quick visual inspection
    slicer "$checker" -a "${output_dir}/registration_check.png"
    
    # Create difference map for registration quality assessment
    log_message "Creating registration difference map"
    
    # Normalize both images to 0-1 range for comparable intensity
    fslmaths "$fixed" -inm 1 "${output_dir}/fixed_norm.nii.gz"
    fslmaths "$warped" -inm 1 "${output_dir}/warped_norm.nii.gz"
    
    # Calculate absolute difference
    fslmaths "${output_dir}/fixed_norm.nii.gz" -sub "${output_dir}/warped_norm.nii.gz" -abs "${output_dir}/reg_diff.nii.gz"
    
    # Create overlay command for fsleyes
    echo "fsleyes $fixed ${output_dir}/reg_diff.nii.gz -cm hot -a 80" > "${output_dir}/view_reg_diff.sh"
    chmod +x "${output_dir}/view_reg_diff.sh"
    
    # Create slices for quick visual inspection
    slicer "${output_dir}/reg_diff.nii.gz" -a "${output_dir}/registration_diff.png"
    
    # Clean up temporary files
    rm "${output_dir}/fixed_norm.nii.gz" "${output_dir}/warped_norm.nii.gz"
    
    log_message "Registration visualizations created in $output_dir"
    return 0
}

# Function to validate registration
validate_registration() {
    local fixed="$1"
    local moving="$2"
    local warped="$3"
    local output_prefix="$4"
    local output_dir="${output_prefix}_validation"
    
    log_message "Validating registration"
    mkdir -p "$output_dir"
    
    # Calculate correlation coefficient
    local cc=$(calculate_cc "$fixed" "$warped")
    log_message "Cross-correlation: $cc"
    
    # Calculate mutual information
    local mi=$(calculate_mi "$fixed" "$warped")
    log_message "Mutual information: $mi"
    
    # Calculate normalized cross-correlation
    local ncc=$(calculate_ncc "$fixed" "$warped")
    log_message "Normalized cross-correlation: $ncc"
    
    # Save validation report
    {
        echo "Registration Validation Report"
        echo "=============================="
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Warped image: $warped"
        echo ""
        echo "Metrics:"
        echo "  Cross-correlation: $cc"
        echo "  Mutual information: $mi"
        echo "  Normalized cross-correlation: $ncc"
        echo ""
        echo "Validation completed: $(date)"
    } > "${output_dir}/validation_report.txt"
    
    # Determine overall quality
    local quality="UNKNOWN"
    if (( $(echo "$cc > 0.7" | bc -l) )); then
        quality="EXCELLENT"
    elif (( $(echo "$cc > 0.5" | bc -l) )); then
        quality="GOOD"
    elif (( $(echo "$cc > 0.3" | bc -l) )); then
        quality="ACCEPTABLE"
    else
        quality="POOR"
    fi
    
    log_message "Overall registration quality: $quality"
    echo "$quality" > "${output_dir}/quality.txt"
    
    # Create visualizations
    create_registration_visualizations "$fixed" "$moving" "$warped" "$output_dir"
    
    return 0
}

# Function to apply transformation
apply_transformation() {
    local input="$1"
    local reference="$2"
    local transform="$3"
    local output="$4"
    local interpolation="${5:-Linear}"
    
    log_message "Applying transformation to $input"
    
    # Check if transform is a .mat file (FSL) or a .h5/.txt file (ANTs)
    if [[ "$transform" == *".mat" ]]; then
        # FSL linear transform
        flirt -in "$input" -ref "$reference" -applyxfm -init "$transform" -out "$output" -interp "$interpolation"
    else
        # ANTs transform
        antsApplyTransforms -d 3 -i "$input" -r "$reference" -o "$output" -t "$transform" -n "$interpolation"
    fi
    
    log_message "Transformation applied. Output: $output"
    return 0
}

# Function to register multiple images to a reference
register_multiple_to_reference() {
    local reference="$1"
    local output_dir="$2"
    shift 2
    local input_files=("$@")
    
    log_message "Registering multiple images to reference: $reference"
    mkdir -p "$output_dir"
    
    for input in "${input_files[@]}"; do
        local basename=$(basename "$input" .nii.gz)
        local output_prefix="${output_dir}/${basename}_to_ref"
        
        log_message "Registering $basename to reference"
        register_t2_flair_to_t1mprage "$reference" "$input" "$output_prefix"
    done
    
    log_message "Multiple registration complete"
    return 0
}

# Export functions
export -f register_t2_flair_to_t1mprage
export -f create_registration_visualizations
export -f validate_registration
export -f apply_transformation
export -f register_multiple_to_reference

log_message "Registration module loaded"