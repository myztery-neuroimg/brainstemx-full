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
    
    if [[ "$transform" == *".mat" ]]; then
        if [[ "$transform" == *"ants"* || "$transform" == *"Affine"* ]]; then
            # ANTs .mat transform — likely affine, must be inverted to go MNI -> subject
            antsApplyTransforms -d 3 -i "$input" -r "$reference" -o "$output" -t "[$transform,1]" -n "$interpolation"
        else
            # FSL .mat transform
            flirt -in "$input" -ref "$reference" -applyxfm -init "$transform" -out "$output" -interp "$interpolation"
        fi
    else
        # ANTs .h5 or .txt transforms — typically don't need inversion unless explicitly known
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

# Function to calculate orientation metrics from registration
calculate_orientation_metrics() {
    local fixed="$1"
    local warped="$2"
    local output_dir="${3:-${RESULTS_DIR}/validation/orientation}"
    
    log_message "Calculating orientation metrics"
    mkdir -p "$output_dir"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Calculate gradient fields
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    fslmaths "$warped" -gradient_x "${temp_dir}/warped_grad_x.nii.gz"
    fslmaths "$warped" -gradient_y "${temp_dir}/warped_grad_y.nii.gz"
    fslmaths "$warped" -gradient_z "${temp_dir}/warped_grad_z.nii.gz"
    
    # Calculate angles between gradient vectors
    local orient_mean_dev=$(python -c "
import numpy as np
import nibabel as nib

# Load gradient fields
fx = nib.load('${temp_dir}/fixed_grad_x.nii.gz').get_fdata()
fy = nib.load('${temp_dir}/fixed_grad_y.nii.gz').get_fdata()
fz = nib.load('${temp_dir}/fixed_grad_z.nii.gz').get_fdata()

wx = nib.load('${temp_dir}/warped_grad_x.nii.gz').get_fdata()
wy = nib.load('${temp_dir}/warped_grad_y.nii.gz').get_fdata()
wz = nib.load('${temp_dir}/warped_grad_z.nii.gz').get_fdata()

# Create vector fields
fixed_vec = np.stack([fx, fy, fz], axis=-1)
warped_vec = np.stack([wx, wy, wz], axis=-1)

# Calculate magnitudes
fixed_mag = np.sqrt(np.sum(fixed_vec**2, axis=-1))
warped_mag = np.sqrt(np.sum(warped_vec**2, axis=-1))

# Create mask for valid vectors (non-zero magnitude)
mask = (fixed_mag > 0.01) & (warped_mag > 0.01)

# Normalize vectors
fixed_norm = fixed_vec.copy()
warped_norm = warped_vec.copy()

for i in range(3):
    fixed_norm[..., i] = np.divide(fixed_vec[..., i], fixed_mag, where=mask)
    warped_norm[..., i] = np.divide(warped_vec[..., i], warped_mag, where=mask)

# Calculate dot product
dot_product = np.sum(fixed_norm * warped_norm, axis=-1)
dot_product = np.clip(dot_product, -1.0, 1.0)  # Ensure in valid range for arccos

# Calculate angle in radians
angles = np.arccos(dot_product)

# Calculate mean angular deviation (in masked region)
mean_dev = np.mean(angles[mask])
print(f'{mean_dev:.6f}')
")
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Return metrics as comma-separated values
    echo "${orient_mean_dev}"
}

# Function to register with topology preservation
register_with_topology_preservation() {
    local fixed="$1"
    local moving="$2"
    local output_prefix="$3"
    
    log_message "Performing topology-preserving registration with parameters from config"
    
    # Use ANTs SyN with topology preservation parameter
    antsRegistration --dimensionality 3 \
      --float 1 \
      --output [$output_prefix,${output_prefix}Warped.nii.gz] \
      --interpolation Linear \
      --use-histogram-matching 1 \
      --winsorize-image-intensities [0.005,0.995] \
      --initial-moving-transform [$fixed,$moving,1] \
      --transform Rigid[0.1] \
      --metric MI[$fixed,$moving,1,32,Regular,0.25] \
      --convergence [1000x500x250x100,1e-6,10] \
      --shrink-factors 8x4x2x1 \
      --smoothing-sigmas 3x2x1x0vox \
      --transform Affine[0.1] \
      --metric MI[$fixed,$moving,1,32,Regular,0.25] \
      --convergence [1000x500x250x100,1e-6,10] \
      --shrink-factors 8x4x2x1 \
      --smoothing-sigmas 3x2x1x0vox \
      --transform SyN[0.1,3,0] \
      --restrict-deformation ${TOPOLOGY_CONSTRAINT_FIELD} \
      --metric CC[$fixed,$moving,1,4] \
      --convergence [100x70x50x20,1e-6,10] \
      --shrink-factors 8x4x2x1 \
      --smoothing-sigmas 3x2x1x0vox
      
    return $?
}

# Function to register with anatomical constraints
register_with_anatomical_constraints() {
    local fixed="$1"
    local moving="$2"
    local output_prefix="$3"
    local brainstem_mask="$4"  # Optional mask for constraint
    
    log_message "Performing anatomically-constrained registration with parameters from config"
    
    # Create directional gradient maps to capture anatomical orientation
    local temp_dir=$(mktemp -d)
    
    # Create orientation priors (principal direction field)
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    # Create orientation constraint field
    if [ -n "$brainstem_mask" ] && [ -f "$brainstem_mask" ]; then
        # Apply mask to gradients
        fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -mas "$brainstem_mask" "${temp_dir}/fixed_orient_x.nii.gz"
        fslmaths "${temp_dir}/fixed_grad_y.nii.gz" -mas "$brainstem_mask" "${temp_dir}/fixed_orient_y.nii.gz"
        fslmaths "${temp_dir}/fixed_grad_z.nii.gz" -mas "$brainstem_mask" "${temp_dir}/fixed_orient_z.nii.gz"
        
        # Create vector field for constraint
        fslmerge -t "${temp_dir}/orientation_field.nii.gz" \
                 "${temp_dir}/fixed_orient_x.nii.gz" \
                 "${temp_dir}/fixed_orient_y.nii.gz" \
                 "${temp_dir}/fixed_orient_z.nii.gz"
                 
        # Use ANTs with orientation constraints via the jacobian regularization parameter
        antsRegistration --dimensionality 3 \
          --float 1 \
          --output [$output_prefix,${output_prefix}Warped.nii.gz] \
          --interpolation Linear \
          --use-histogram-matching 1 \
          --winsorize-image-intensities [0.005,0.995] \
          --initial-moving-transform [$fixed,$moving,1] \
          --transform Rigid[0.1] \
          --metric MI[$fixed,$moving,1,32,Regular,0.25] \
          --convergence [1000x500x250x100,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox \
          --transform Affine[0.1] \
          --metric MI[$fixed,$moving,1,32,Regular,0.25] \
          --convergence [1000x500x250x100,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox \
          --transform SyN[0.1,3,0] \
          --jacobian-regularization ${JACOBIAN_REGULARIZATION_WEIGHT} \
          --regularization-weight ${TOPOLOGY_CONSTRAINT_WEIGHT} \
          --metric CC[$fixed,$moving,1,4] \
          --metric PSE[$fixed,$moving,${temp_dir}/orientation_field.nii.gz,${REGULARIZATION_GRADIENT_FIELD_WEIGHT},4] \
          --convergence [100x70x50x20,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox
    else
        # If no mask provided, use whole-brain constraint with heavier regularization
        antsRegistration --dimensionality 3 \
          --float 1 \
          --output [$output_prefix,${output_prefix}Warped.nii.gz] \
          --interpolation Linear \
          --use-histogram-matching 1 \
          --winsorize-image-intensities [0.005,0.995] \
          --initial-moving-transform [$fixed,$moving,1] \
          --transform Rigid[0.1] \
          --metric MI[$fixed,$moving,1,32,Regular,0.25] \
          --convergence [1000x500x250x100,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox \
          --transform Affine[0.1] \
          --metric MI[$fixed,$moving,1,32,Regular,0.25] \
          --convergence [1000x500x250x100,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox \
          --transform SyN[0.1,3,0] \
          --jacobian-regularization ${JACOBIAN_REGULARIZATION_WEIGHT} \
          --regularization-weight ${TOPOLOGY_CONSTRAINT_WEIGHT} \
          --metric CC[$fixed,$moving,1,4] \
          --convergence [100x70x50x20,1e-6,10] \
          --shrink-factors 8x4x2x1 \
          --smoothing-sigmas 3x2x1x0vox
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    return $?
}

# Function to correct orientation distortion
correct_orientation_distortion() {
    local fixed="$1"
    local warped="$2"
    local transform="$3"
    local output="$4"
    
    log_message "Correcting orientation distortion in registration using configured parameters"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Calculate gradient fields
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    fslmaths "$warped" -gradient_x "${temp_dir}/warped_grad_x.nii.gz"
    fslmaths "$warped" -gradient_y "${temp_dir}/warped_grad_y.nii.gz"
    fslmaths "$warped" -gradient_z "${temp_dir}/warped_grad_z.nii.gz"
    
    # Create correction transformation
    if command -v ANTSIntegrateVelocityField &>/dev/null; then
        # Calculate gradient differences (velocity field)
        fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -sub "${temp_dir}/warped_grad_x.nii.gz" "${temp_dir}/diff_x.nii.gz"
        fslmaths "${temp_dir}/fixed_grad_y.nii.gz" -sub "${temp_dir}/warped_grad_y.nii.gz" "${temp_dir}/diff_y.nii.gz"
        fslmaths "${temp_dir}/fixed_grad_z.nii.gz" -sub "${temp_dir}/warped_grad_z.nii.gz" "${temp_dir}/diff_z.nii.gz"
        
        # Merge into vector field
        fslmerge -t "${temp_dir}/diff_field.nii.gz" \
                 "${temp_dir}/diff_x.nii.gz" \
                 "${temp_dir}/diff_y.nii.gz" \
                 "${temp_dir}/diff_z.nii.gz"
        
        # Smooth the difference field with configured sigma
        ImageMath 3 "${temp_dir}/smooth_diff.nii.gz" G "${temp_dir}/diff_field.nii.gz" ${ORIENTATION_SMOOTH_SIGMA}
        
        # Scale down difference field with configured factor
        ImageMath 3 "${temp_dir}/scaled_diff.nii.gz" m "${temp_dir}/smooth_diff.nii.gz" ${ORIENTATION_SCALING_FACTOR}
        
        # Integrate velocity field to get displacement field
        ANTSIntegrateVelocityField 3 "${temp_dir}/scaled_diff.nii.gz" "${temp_dir}/correction_field.nii.gz" 1 5
        
        # Compose with original transform to get corrected transform
        ComposeTransforms 3 "${temp_dir}/corrected_transform.nii.gz" -r "$transform" "${temp_dir}/correction_field.nii.gz"
        
        # Apply corrected transform
        antsApplyTransforms -d 3 -i "$warped" -r "$fixed" -o "$output" -t "${temp_dir}/corrected_transform.nii.gz"
    else
        log_formatted "WARNING" "ANTSIntegrateVelocityField not available, skipping orientation distortion correction"
        # Simply copy the input as output
        cp "$warped" "$output"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    return 0
}

# Function to validate transformation with orientation checks
validate_transformation() {
    local fixed="$1"
    local moving="$2"
    local warped="$3"
    local output_prefix="$4"
    local validation_dir="${output_prefix}_validation"
    
    log_message "Validating transformation with orientation metrics"
    mkdir -p "$validation_dir"
    
    # Standard validation metrics
    validate_registration "$fixed" "$moving" "$warped" "$output_prefix"
    
    # Additional orientation-specific validation
    local orientation_metrics=$(calculate_orientation_metrics "$fixed" "$warped" "${validation_dir}/orientation")
    local orient_mean_dev=$(echo "$orientation_metrics")
    
    log_message "Orientation mean angular deviation: $orient_mean_dev radians"
    
    # Analyze shearing distortion
    analyze_shearing_distortion "$fixed" "$warped" "$validation_dir"
    
    # Determine orientation quality
    local orientation_quality="ACCEPTABLE"
    if (( $(echo "$orient_mean_dev < $ORIENTATION_EXCELLENT_THRESHOLD" | bc -l) )); then
        orientation_quality="EXCELLENT"
    elif (( $(echo "$orient_mean_dev < $ORIENTATION_GOOD_THRESHOLD" | bc -l) )); then
        orientation_quality="GOOD"
    elif (( $(echo "$orient_mean_dev > $ORIENTATION_ACCEPTABLE_THRESHOLD" | bc -l) )); then
        orientation_quality="POOR"
    fi
    
    log_message "Orientation preservation quality: $orientation_quality"
    echo "$orientation_quality" > "${validation_dir}/orientation_quality.txt"
    
    # Save extended validation report
    {
        echo "Extended Registration Validation Report"
        echo "======================================"
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Warped image: $warped"
        echo ""
        echo "Orientation Metrics:"
        echo "  Mean angular deviation: $orient_mean_dev radians"
        echo "  Orientation quality: $orientation_quality"
        echo ""
        echo "Validation completed: $(date)"
    } > "${validation_dir}/orientation_validation_report.txt"
    
    return 0
}

# Function to analyze shearing distortion in transformation
analyze_shearing_distortion() {
    local fixed="$1"
    local warped="$2"
    local output_dir="$3"
    
    log_message "Analyzing shearing distortion"
    
    # Extract transform matrix from header
    local affine_matrix=$(python -c "
import nibabel as nib
import numpy as np

# Load images
fixed_img = nib.load('$fixed')
warped_img = nib.load('$warped')

# Get affine transforms
fixed_affine = fixed_img.affine
warped_affine = warped_img.affine

# Extract rotation/scaling components (upper 3x3 matrix)
fixed_rsm = fixed_affine[:3, :3]
warped_rsm = warped_affine[:3, :3]

# Normalize by removing scaling
fixed_norm = fixed_rsm / np.sqrt(np.sum(fixed_rsm**2, axis=0))
warped_norm = warped_rsm / np.sqrt(np.sum(warped_rsm**2, axis=0))

# Calculate relative transform
relative_transform = np.dot(warped_norm, np.linalg.inv(fixed_norm))

# Check for orthogonality (deviation indicates shearing)
identity = np.eye(3)
ortho_deviation = np.linalg.norm(np.dot(relative_transform.T, relative_transform) - identity)

# Calculate individual shear components
shear_x = abs(relative_transform[0, 1]**2 + relative_transform[0, 2]**2)
shear_y = abs(relative_transform[1, 0]**2 + relative_transform[1, 2]**2)
shear_z = abs(relative_transform[2, 0]**2 + relative_transform[2, 1]**2)

print(f'{ortho_deviation:.6f},{shear_x:.6f},{shear_y:.6f},{shear_z:.6f}')
")
    
    # Parse results
    local ortho_deviation=$(echo "$affine_matrix" | cut -d',' -f1)
    local shear_x=$(echo "$affine_matrix" | cut -d',' -f2)
    local shear_y=$(echo "$affine_matrix" | cut -d',' -f3)
    local shear_z=$(echo "$affine_matrix" | cut -d',' -f4)
    
    # Determine if significant shearing is present
    local shearing_detected=false
    if (( $(echo "$shear_x > $SHEARING_DETECTION_THRESHOLD" | bc -l) )) ||
       (( $(echo "$shear_y > $SHEARING_DETECTION_THRESHOLD" | bc -l) )) ||
       (( $(echo "$shear_z > $SHEARING_DETECTION_THRESHOLD" | bc -l) )); then
        shearing_detected=true
    fi
    
    # Save shearing analysis
    {
        echo "Shearing Distortion Analysis"
        echo "============================"
        echo "Orthogonality deviation: $ortho_deviation"
        echo "Shear components:"
        echo "  X: $shear_x"
        echo "  Y: $shear_y"
        echo "  Z: $shear_z"
        echo ""
        echo "Significant shearing detected: $shearing_detected"
        echo ""
        echo "Analysis completed: $(date)"
    } > "${output_dir}/shearing_analysis.txt"
    
    log_message "Shearing analysis completed. Significant shearing: $shearing_detected"
    
    return 0
}

# Export functions
export -f register_with_topology_preservation
export -f register_with_anatomical_constraints
export -f correct_orientation_distortion
export -f calculate_orientation_metrics
export -f validate_transformation
export -f analyze_shearing_distortion

log_message "Registration module loaded with orientation preservation capabilities"
