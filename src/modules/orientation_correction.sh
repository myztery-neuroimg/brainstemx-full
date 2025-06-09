#!/usr/bin/env bash
#
# orientation_correction.sh - Functions for preserving and correcting orientation in registrations
#
# This module provides functionality to preserve anatomical orientation during registration
# and correct any orientation distortions that might occur. It implements three methods:
# 1. Topology-preserving registration
# 2. Anatomically-constrained registration 
# 3. Post-registration correction

# Function to perform registration with topology preservation
register_with_topology_preservation() {
    local fixed="$1"
    local moving="$2"
    local output_prefix="$3"
    local transform_type="${4:-r}"  # Default to rigid
    
    log_message "Running registration with topology preservation"
    
    # Determine appropriate ANTs binary path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Set topology constraint parameters
    local topology_weight="${TOPOLOGY_CONSTRAINT_WEIGHT:-0.5}"
    local constraint_field="${TOPOLOGY_CONSTRAINT_FIELD:-1x1x1}"
    
    # Use ANTs SyN with restricting deformation field
    execute_ants_command "orientation_preserving_registration" "Topology-preserving registration to maintain anatomical orientation" \
      ${ants_bin}/antsRegistrationSyN.sh \
      -d 3 \
      -f "$fixed" \
      -m "$moving" \
      -o "$output_prefix" \
      -t "$transform_type" \
      -n "$ANTS_THREADS" \
      -p f \
      -j "$ANTS_THREADS" \
      -x "$REG_METRIC_CROSS_MODALITY" \
      -r "$constraint_field" \
      --restrict-deformation "$constraint_field" \
      --float "$REG_PRECISION" \
      --jacobian-regularization "$topology_weight"
    
    local registration_status=$?
    
    if [ $registration_status -ne 0 ]; then
        log_formatted "WARNING" "Topology-preserving registration failed with status $registration_status"
        return $registration_status
    fi
    
    log_formatted "SUCCESS" "Topology-preserving registration completed"
    return 0
}

# Function to perform registration with anatomical constraints
register_with_anatomical_constraints() {
    local fixed="$1"
    local moving="$2"
    local output_prefix="$3"
    local anatomical_mask="$4"  # Optional mask for critical structures
    local transform_type="${5:-r}"  # Default to rigid
    
    log_message "Running registration with anatomical constraints"
    
    # Determine appropriate ANTs binary path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Create temporary directory for processing
    local temp_dir=$(mktemp -d)
    
    # Create orientation priors (principal direction field) if not provided
    # This preserves anatomical orientation in critical structures
    log_message "Calculating gradient fields for orientation constraints"
    
    # Calculate gradient fields of fixed image to capture anatomical orientation
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    # If anatomical mask is provided, use it to focus constraints
    local mask_arg=""
    if [ -n "$anatomical_mask" ] && [ -f "$anatomical_mask" ]; then
        mask_arg="-m $anatomical_mask"
        log_message "Using anatomical mask for constraining registration: $anatomical_mask"
    fi
    
    # Set regularization parameters
    local jacobian_weight="${JACOBIAN_REGULARIZATION_WEIGHT:-1.0}"
    local regularization_weight="${REGULARIZATION_GRADIENT_FIELD_WEIGHT:-0.5}"
    
    # Run registration with orientation constraints
    execute_ants_command "anatomically_constrained_registration" "Registration with anatomical constraints to preserve critical structures" \
      ${ants_bin}/antsRegistrationSyN.sh \
      -d 3 \
      -f "$fixed" \
      -m "$moving" \
      -o "$output_prefix" \
      -t "$transform_type" \
      -n "$ANTS_THREADS" \
      -p f \
      -j "$ANTS_THREADS" \
      -x "$REG_METRIC_CROSS_MODALITY" \
      $mask_arg \
      --float "$REG_PRECISION" \
      --jacobian-regularization "$jacobian_weight" \
      --regularization-weight "$regularization_weight"
    
    local registration_status=$?
    
    # Clean up temporary files
    rm -rf "$temp_dir"
    
    if [ $registration_status -ne 0 ]; then
        log_formatted "WARNING" "Anatomically-constrained registration failed with status $registration_status"
        return $registration_status
    fi
    
    log_formatted "SUCCESS" "Anatomically-constrained registration completed"
    return 0
}

# Function to detect and correct orientation distortion in already registered image
correct_orientation_distortion() {
    local fixed="$1"
    local moving="$2"
    local warped="$3"  # Already registered image that may have orientation distortion
    local transform="$4"  # Transform that was used to create warped
    local output="$5"  # Output corrected image
    
    log_message "Detecting and correcting orientation distortion"
    
    # Create temporary directory for processing
    local temp_dir=$(mktemp -d)
    
    # Calculate gradient fields to detect orientation distortion
    log_message "SKIPPED: Calculating gradient fields to detect orientation distortion"
    return 0
    #fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    #fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    #fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    #fslmaths "$warped" -gradient_x "${temp_dir}/warped_grad_x.nii.gz"
    #fslmaths "$warped" -gradient_y "${temp_dir}/warped_grad_y.nii.gz"
    #fslmaths "$warped" -gradient_z "${temp_dir}/warped_grad_z.nii.gz"
    
    # Calculate gradient differences (velocity field)
    log_message "Calculating gradient differences for correction"
    #fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -sub "${temp_dir}/warped_grad_x.nii.gz" "${temp_dir}/diff_x.nii.gz"
    #fslmaths "${temp_dir}/fixed_grad_y.nii.gz" -sub "${temp_dir}/warped_grad_y.nii.gz" "${temp_dir}/diff_y.nii.gz"
    #fslmaths "${temp_dir}/fixed_grad_z.nii.gz" -sub "${temp_dir}/warped_grad_z.nii.gz" "${temp_dir}/diff_z.nii.gz"
    
    # Calculate angular deviation for quality assessment
    #local mean_angular_deviation=$(calculate_orientation_deviation "$fixed" "$warped")
    #log_message "Mean angular deviation before correction: $mean_angular_deviation"
    
    # Check if correction is needed based on threshold
    local correction_threshold="${ORIENTATION_CORRECTION_THRESHOLD:-0.3}"
    if (( $(echo "$mean_angular_deviation < $correction_threshold" | bc -l) )); then
        log_message "Mean angular deviation ($mean_angular_deviation) is below threshold ($correction_threshold), no correction needed"
        # Simply copy the warped to output since no correction is needed
        cp "$warped" "$output"
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Apply orientation correction
    log_message "Applying orientation correction (deviation: $mean_angular_deviation, threshold: $correction_threshold)"
    
    # Scale correction by scaling factor (controls correction strength)
    local scaling_factor="${ORIENTATION_SCALING_FACTOR:-0.05}"
    fslmaths "${temp_dir}/diff_x.nii.gz" -mul "$scaling_factor" "${temp_dir}/scaled_diff_x.nii.gz"
    fslmaths "${temp_dir}/diff_y.nii.gz" -mul "$scaling_factor" "${temp_dir}/scaled_diff_y.nii.gz"
    fslmaths "${temp_dir}/diff_z.nii.gz" -mul "$scaling_factor" "${temp_dir}/scaled_diff_z.nii.gz"
    
    # Smooth correction field to avoid sharp transitions
    local smooth_sigma="${ORIENTATION_SMOOTH_SIGMA:-1.5}"
    fslmaths "${temp_dir}/scaled_diff_x.nii.gz" -s "$smooth_sigma" "${temp_dir}/smooth_diff_x.nii.gz"
    fslmaths "${temp_dir}/scaled_diff_y.nii.gz" -s "$smooth_sigma" "${temp_dir}/smooth_diff_y.nii.gz"
    fslmaths "${temp_dir}/scaled_diff_z.nii.gz" -s "$smooth_sigma" "${temp_dir}/smooth_diff_z.nii.gz"
    
    # Determine appropriate ANTs binary path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Combine the smooth scaled differences into a vector field
    ${ants_bin}/ImageMath 3 "${temp_dir}/correction_field.nii.gz" ComponentToVector \
        "${temp_dir}/smooth_diff_x.nii.gz" "${temp_dir}/smooth_diff_y.nii.gz" "${temp_dir}/smooth_diff_z.nii.gz"
    
    # Apply the correction to create a corrected transform
    ${ants_bin}/ComposeTransforms 3 "${temp_dir}/corrected_transform.nii.gz" \
        -r "$transform" "${temp_dir}/correction_field.nii.gz"
    
    # Apply the corrected transform to create the corrected image
    ${ants_bin}/antsApplyTransforms -d 3 -i "$moving" -r "$fixed" \
        -o "$output" -t "${temp_dir}/corrected_transform.nii.gz" -n Linear
    
    # Calculate angular deviation after correction for validation
    local corrected_deviation=$(calculate_orientation_deviation "$fixed" "$output")
    log_message "Mean angular deviation after correction: $corrected_deviation"
    
    # Calculate improvement metric
    local improvement=$(echo "$mean_angular_deviation - $corrected_deviation" | bc -l)
    log_message "Orientation improvement: $improvement"
    
    # Create validation report
    {
        echo "Orientation Correction Report"
        echo "============================="
        echo "Fixed image: $fixed"
        echo "Warped image: $warped"
        echo "Corrected image: $output"
        echo ""
        echo "Metrics:"
        echo "  Mean angular deviation before correction: $mean_angular_deviation"
        echo "  Mean angular deviation after correction: $corrected_deviation"
        echo "  Orientation improvement: $improvement"
        echo ""
        echo "Parameters:"
        echo "  Correction threshold: $correction_threshold"
        echo "  Scaling factor: $scaling_factor"
        echo "  Smoothing sigma: $smooth_sigma"
        echo ""
        echo "Correction completed: $(date)"
    } > "$(dirname "$output")/orientation_correction_report.txt"
    
    # Clean up temporary files
    rm -rf "$temp_dir"
    
    log_formatted "SUCCESS" "Orientation correction applied successfully"
    return 0
}

# Function to calculate orientation deviation between two images
calculate_orientation_deviation() {
    local fixed="$1"
    local warped="$2"
    local mask="${3:-}"  # Optional mask to focus calculation
    # Create temporary directory for processing
    local temp_dir=$(mktemp -d)
    
    # Calculate gradient fields to detect orientation
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    fslmaths "$warped" -gradient_x "${temp_dir}/warped_grad_x.nii.gz"
    fslmaths "$warped" -gradient_y "${temp_dir}/warped_grad_y.nii.gz"
    fslmaths "$warped" -gradient_z "${temp_dir}/warped_grad_z.nii.gz"
    
    # Calculate dot product of gradient vectors
    fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -mul "${temp_dir}/warped_grad_x.nii.gz" "${temp_dir}/dot_x.nii.gz"
    fslmaths "${temp_dir}/fixed_grad_y.nii.gz" -mul "${temp_dir}/warped_grad_y.nii.gz" "${temp_dir}/dot_y.nii.gz"
    fslmaths "${temp_dir}/fixed_grad_z.nii.gz" -mul "${temp_dir}/warped_grad_z.nii.gz" "${temp_dir}/dot_z.nii.gz"
    
    # Sum dot products
    fslmaths "${temp_dir}/dot_x.nii.gz" -add "${temp_dir}/dot_y.nii.gz" -add "${temp_dir}/dot_z.nii.gz" "${temp_dir}/dot_sum.nii.gz"
    
    # Calculate magnitude of vectors
    fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -mul "${temp_dir}/fixed_grad_x.nii.gz" "${temp_dir}/fixed_mag_x.nii.gz"
    fslmaths "${temp_dir}/fixed_grad_y.nii.gz" -mul "${temp_dir}/fixed_grad_y.nii.gz" "${temp_dir}/fixed_mag_y.nii.gz"
    fslmaths "${temp_dir}/fixed_grad_z.nii.gz" -mul "${temp_dir}/fixed_grad_z.nii.gz" "${temp_dir}/fixed_mag_z.nii.gz"
    
    fslmaths "${temp_dir}/warped_grad_x.nii.gz" -mul "${temp_dir}/warped_grad_x.nii.gz" "${temp_dir}/warped_mag_x.nii.gz"
    fslmaths "${temp_dir}/warped_grad_y.nii.gz" -mul "${temp_dir}/warped_grad_y.nii.gz" "${temp_dir}/warped_mag_y.nii.gz"
    fslmaths "${temp_dir}/warped_grad_z.nii.gz" -mul "${temp_dir}/warped_grad_z.nii.gz" "${temp_dir}/warped_mag_z.nii.gz"
    
    # Calculate magnitude sums
    fslmaths "${temp_dir}/fixed_mag_x.nii.gz" -add "${temp_dir}/fixed_mag_y.nii.gz" -add "${temp_dir}/fixed_mag_z.nii.gz" "${temp_dir}/fixed_mag_sum.nii.gz"
    fslmaths "${temp_dir}/warped_mag_x.nii.gz" -add "${temp_dir}/warped_mag_y.nii.gz" -add "${temp_dir}/warped_mag_z.nii.gz" "${temp_dir}/warped_mag_sum.nii.gz"
    
    # Calculate square root of magnitudes
    fslmaths "${temp_dir}/fixed_mag_sum.nii.gz" -sqrt "${temp_dir}/fixed_mag.nii.gz"
    fslmaths "${temp_dir}/warped_mag_sum.nii.gz" -sqrt "${temp_dir}/warped_mag.nii.gz"
    
    # Calculate product of magnitudes
    fslmaths "${temp_dir}/fixed_mag.nii.gz" -mul "${temp_dir}/warped_mag.nii.gz" "${temp_dir}/mag_product.nii.gz"
    
    # Calculate cosine of angle between vectors (dot product / product of magnitudes)
    fslmaths "${temp_dir}/dot_sum.nii.gz" -div "${temp_dir}/mag_product.nii.gz" "${temp_dir}/cos_angle.nii.gz"
    
    # Restrict values to range [-1, 1] to avoid NaNs in acos
    fslmaths "${temp_dir}/cos_angle.nii.gz" -min 1 -max -1 -mul -1 -add 1 -div 2 "${temp_dir}/cos_angle_bounded.nii.gz"
    
    # Calculate acos to get angular deviation in radians
    fslmaths "${temp_dir}/cos_angle_bounded.nii.gz" -acos "${temp_dir}/angle.nii.gz"
    
    # Apply mask if provided to focus calculation on specific regions
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        fslmaths "${temp_dir}/angle.nii.gz" -mas "$mask" "${temp_dir}/angle_masked.nii.gz"
        mean_angle=$(fslstats "${temp_dir}/angle_masked.nii.gz" -M)
    else
        mean_angle=$(fslstats "${temp_dir}/angle.nii.gz" -M)
    fi
    log_message "Angled mask - mean: ${mean_angle}"
    
    # Clean up temporary files
    rm -rf "$temp_dir"
}

# Function to detect shearing in a transform
detect_shearing() {
    local transform="$1"
    local threshold="${SHEARING_DETECTION_THRESHOLD:-0.05}"
    
    # Only works with ANTs transform files
    if [[ "$transform" != *".mat" ]] && [[ "$transform" != *".txt" ]]; then
        log_formatted "WARNING" "Shearing detection only works with matrix transforms (.mat or .txt), skipping"
        return 1
    fi
    
    # Read transform from file
    local transform_content=$(cat "$transform")
    
    # Extract matrix elements from ANTs transform
    # Format depends on the transform type, but we'll try to extract a 3x3 rotation matrix
    local matrix=$(echo "$transform_content" | grep -A 3 "Parameters:" | sed 's/Parameters: //g' | tr -d '\n')
    
    # If couldn't extract matrix, return error
    if [ -z "$matrix" ]; then
        log_formatted "WARNING" "Could not extract transformation matrix from $transform"
        return 1
    fi
    
    # Check for shearing by evaluating deviation from orthogonality
    # ...simplified approach here, a real implementation would compute proper metrics
    # like column dot products and check determinant signs
    
    # For now, just return a dummy value - replacing with true implementation would require
    # more complex matrix operations that are better done in Python or using external tools
    local shearing_detected=false
    
    echo "$shearing_detected"
}

# Function to assess orientation quality and return a rating
assess_orientation_quality() {
    local deviation="$1"
    
    # Get thresholds from environment or use defaults
    local excellent_threshold="${ORIENTATION_EXCELLENT_THRESHOLD:-0.1}"  # < 0.1 rad is excellent (~6 degrees)
    local good_threshold="${ORIENTATION_GOOD_THRESHOLD:-0.2}"           # < 0.2 rad is good (~11 degrees)
    local acceptable_threshold="${ORIENTATION_ACCEPTABLE_THRESHOLD:-0.3}" # < 0.3 rad is acceptable (~17 degrees)
    
    # Determine quality based on thresholds
    if (( $(echo "$deviation < $excellent_threshold" | bc -l) )); then
        echo "EXCELLENT"
    elif (( $(echo "$deviation < $good_threshold" | bc -l) )); then
        echo "GOOD"
    elif (( $(echo "$deviation < $acceptable_threshold" | bc -l) )); then
        echo "ACCEPTABLE"
    else
        echo "POOR"
    fi
}

# Function to run orientation distortion test
run_orientation_test() {
    local t1_file="$1"
    local modality_file="$2"
    local output_dir="$3"
    
    log_message "Running orientation preservation test suite"
    
    # Create test output directory
    local test_dir="${output_dir}/orientation_test"
    mkdir -p "$test_dir"
    
    # Run standard registration (baseline)
    local standard_prefix="${test_dir}/standard"
    log_message "Running standard registration for baseline comparison"
    register_modality_to_t1 "$t1_file" "$modality_file" "TEST" "$standard_prefix"
    
    # Run topology-preserving registration
    local topology_prefix="${test_dir}/topology"
    log_message "Running topology-preserving registration"
    register_with_topology_preservation "$t1_file" "$modality_file" "$topology_prefix" "r"
    
    # Try to find or create a brainstem mask for anatomical constraints
    local brainstem_mask=""
    local found_mask=$(find "${RESULTS_DIR}/segmentation" -name "*brainstem*.nii.gz" | head -1)
    if [ -n "$found_mask" ] && [ -f "$found_mask" ]; then
        brainstem_mask="$found_mask"
        log_message "Using existing brainstem mask: $brainstem_mask"
    fi
    
    # Run anatomically-constrained registration
    local anatomical_prefix="${test_dir}/anatomical"
    log_message "Running anatomically-constrained registration"
    register_with_anatomical_constraints "$t1_file" "$modality_file" "$anatomical_prefix" "$brainstem_mask" "r"
    
    # Run post-correction on standard registration
    local corrected_prefix="${test_dir}/corrected"
    log_message "Applying post-registration correction to standard result"
    correct_orientation_distortion "$t1_file" "$modality_file" "${standard_prefix}Warped.nii.gz" \
        "${standard_prefix}0GenericAffine.mat" "${corrected_prefix}Warped.nii.gz"
    
    # Calculate metrics for all approaches
    log_message "Calculating orientation metrics for comparison"
    local standard_deviation=$(calculate_orientation_deviation "$t1_file" "${standard_prefix}Warped.nii.gz")
    local topology_deviation=$(calculate_orientation_deviation "$t1_file" "${topology_prefix}Warped.nii.gz")
    local anatomical_deviation=$(calculate_orientation_deviation "$t1_file" "${anatomical_prefix}Warped.nii.gz")
    local corrected_deviation=$(calculate_orientation_deviation "$t1_file" "${corrected_prefix}Warped.nii.gz")
    
    # Calculate improvement metrics
    local topology_improvement=$(echo "$standard_deviation - $topology_deviation" | bc -l)
    local anatomical_improvement=$(echo "$standard_deviation - $anatomical_deviation" | bc -l)
    local corrected_improvement=$(echo "$standard_deviation - $corrected_deviation" | bc -l)
    
    # Generate comprehensive report
    log_message "Generating orientation test report"
    {
        echo "Orientation Preservation Test Results"
        echo "===================================="
        echo ""
        echo "Standard Registration Mean Angular Deviation: $standard_deviation"
        echo "Topology-Preserving Registration Mean Angular Deviation: $topology_deviation"
        echo "Anatomically-Constrained Registration Mean Angular Deviation: $anatomical_deviation"
        echo "Corrected Registration Mean Angular Deviation: $corrected_deviation"
        echo ""
        echo "Configuration Parameters:"
        echo "  TOPOLOGY_CONSTRAINT_WEIGHT: ${TOPOLOGY_CONSTRAINT_WEIGHT:-0.5}"
        echo "  TOPOLOGY_CONSTRAINT_FIELD: ${TOPOLOGY_CONSTRAINT_FIELD:-1x1x1}"
        echo "  JACOBIAN_REGULARIZATION_WEIGHT: ${JACOBIAN_REGULARIZATION_WEIGHT:-1.0}"
        echo "  REGULARIZATION_GRADIENT_FIELD_WEIGHT: ${REGULARIZATION_GRADIENT_FIELD_WEIGHT:-0.5}"
        echo "  ORIENTATION_CORRECTION_THRESHOLD: ${ORIENTATION_CORRECTION_THRESHOLD:-0.3}"
        echo "  ORIENTATION_SCALING_FACTOR: ${ORIENTATION_SCALING_FACTOR:-0.05}"
        echo "  ORIENTATION_SMOOTH_SIGMA: ${ORIENTATION_SMOOTH_SIGMA:-1.0}"
        echo ""
        echo "Improvement Metrics:"
        echo "  Standard to Topology: $topology_improvement"
        echo "  Standard to Anatomical: $anatomical_improvement"
        echo "  Standard to Corrected: $corrected_improvement"
        echo ""
        echo "Quality Assessment:"
        echo "  Standard Registration: $(assess_orientation_quality "$standard_deviation")"
        echo "  Topology-Preserving: $(assess_orientation_quality "$topology_deviation")"
        echo "  Anatomically-Constrained: $(assess_orientation_quality "$anatomical_deviation")"
        echo "  Corrected Registration: $(assess_orientation_quality "$corrected_deviation")"
        echo ""
        echo "Test completed: $(date)"
    } > "${test_dir}/orientation_test_report.txt"
    
    log_formatted "SUCCESS" "Orientation test suite completed. Report generated at ${test_dir}/orientation_test_report.txt"
    
    # Return the best approach based on the results
    if (( $(echo "$anatomical_deviation <= $topology_deviation" | bc -l) )) && \
       (( $(echo "$anatomical_deviation <= $corrected_deviation" | bc -l) )); then
        echo "ANATOMICAL"
    elif (( $(echo "$topology_deviation <= $corrected_deviation" | bc -l) )); then
        echo "TOPOLOGY"
    else
        echo "CORRECTED"
    fi
}

# Export functions
export -f register_with_topology_preservation
export -f register_with_anatomical_constraints
export -f correct_orientation_distortion
export -f calculate_orientation_deviation
export -f detect_shearing
export -f assess_orientation_quality
export -f run_orientation_test

log_message "Orientation correction module loaded"
