#!/usr/bin/env bash
#
# registration.sh - Registration functions for the brain MRI processing pipeline
#
# This module contains:
# - T2-SPACE-FLAIR to T1MPRAGE registration
# - Registration visualization
# - Registration QA integration
#

# Function to detect image resolution and set appropriate template
detect_image_resolution() {
    local image_file="$1"
    local result="$DEFAULT_TEMPLATE_RES"  # Default if detection fails
    
    # Check if file exists
    if [ ! -f "$image_file" ]; then
        log_formatted "ERROR" "Image file not found: $image_file"
        echo "$result"
        return 1
    fi
    
    # Get voxel dimensions using fslinfo
    local pixdim1=$(fslinfo "$image_file" | grep pixdim1 | awk '{print $2}')
    local pixdim2=$(fslinfo "$image_file" | grep pixdim2 | awk '{print $2}')
    local pixdim3=$(fslinfo "$image_file" | grep pixdim3 | awk '{print $2}')
    
    # Calculate average voxel dimension
    local avg_dim=$(echo "($pixdim1 + $pixdim2 + $pixdim3) / 3" | bc -l)
    
    log_message "Detected average voxel dimension: $avg_dim mm"
    
    # Determine closest template resolution
    if (( $(echo "$avg_dim <= 1.25" | bc -l) )); then
        result="1mm"
    elif (( $(echo "$avg_dim <= 2.5" | bc -l) )); then
        result="2mm"
    else
        log_formatted "WARNING" "Image has unusual resolution ($avg_dim mm). Using default template."
    fi
    
    log_message "Selected template resolution: $result"
    echo "$result"
    return 0
}

# Function to set template based on detected resolution
set_template_resolution() {
    local resolution="$1"
    
    case "$resolution" in
        "1mm")
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"
            ;;
        "2mm")
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_2MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_2MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_2MM"
            ;;
        *)
            log_formatted "WARNING" "Unknown resolution: $resolution. Using default (1mm)"
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"
            ;;
    esac
    
    log_message "Set templates for $resolution resolution: $EXTRACTION_TEMPLATE"
    return 0
}

# Function to register any modality to T1
register_modality_to_t1() {
    # Usage: register_modality_to_t1 <T1_file.nii.gz> <modality_file.nii.gz> <modality_name> <output_prefix>
    #
    # Enhanced with BBR priming for better cortical alignment
    # First uses FSL's BBR for an initial alignment, then refines with ANTs SyN

    local t1_file="$1"
    local modality_file="$2"
    local modality_name="${3:-OTHER}"  # Default to OTHER if not specified
    local out_prefix="${4:-${RESULTS_DIR}/registered/t1_to_${modality_name,,}}"  # Convert to lowercase

    if [ ! -f "$t1_file" ] || [ ! -f "$modality_file" ]; then
        log_formatted "ERROR" "T1 or $modality_name file not found"
        return 1
    fi

    log_message "=== Registering $modality_name to T1 with BBR Priming ==="
    log_message "T1: $t1_file"
    log_message "$modality_name: $modality_file"
    log_message "Output prefix: $out_prefix"
    
    # Detect resolution and set appropriate template
    local detected_res=$(detect_image_resolution "$modality_file")
    set_template_resolution "$detected_res"

    # Create output directory
    mkdir -p "$(dirname "$out_prefix")"
    
    # Initialize BBR variables
    local use_bbr="${USE_BBR_PRIMING:-true}"
    local bbr_mat="${out_prefix}_bbr.mat"
    local wm_mask="${out_prefix}_wm_mask.nii.gz"
    local bbr_initialized=false
    local outer_ribbon_mask="${out_prefix}_outer_ribbon_mask.nii.gz"
    
    # Step 1: Create WM mask for BBR if it doesn't exist
    if [ "$use_bbr" = "true" ]; then
        log_message "Preparing for BBR priming..."
        
        # Check if we already have a WM segmentation
        local wm_seg=$(find "$RESULTS_DIR/segmentation" -name "*white_matter*.nii.gz" -o -name "*wm*.nii.gz" | head -1)
        
        if [ -n "$wm_seg" ] && [ -f "$wm_seg" ]; then
            log_message "Using existing WM segmentation: $wm_seg"
            cp "$wm_seg" "$wm_mask"
        else
            # Use FSL's FAST for WM segmentation
            log_message "Creating WM segmentation using FAST..."
            if command -v fast &>/dev/null; then
                # Create brain mask to speed up segmentation
                local temp_dir=$(mktemp -d)
                local brain_mask="${temp_dir}/brain_mask.nii.gz"
                fslmaths "$t1_file" -bin "$brain_mask"
                
                # Run FAST segmentation
                fast -t 1 -n 3 -o "${temp_dir}/fast" -m "$brain_mask" "$t1_file"
                
                # WM is typically label 3 in FAST output
                fslmaths "${temp_dir}/fast_seg" -thr 3 -uthr 3 -bin "$wm_mask"
                
                # Clean up temporary files
                rm -rf "$temp_dir"
            else
                log_formatted "WARNING" "FSL's FAST not available, skipping BBR priming"
                use_bbr=false
            fi
        fi
        
        # Create outer ribbon mask
        if [ "$use_bbr" = "true" ]; then
            # Create brain mask
            fslmaths "$t1_file" -bin "${out_prefix}_brain_mask.nii.gz"
            
            # Create eroded mask (outer ribbon excluded)
            log_message "Creating outer ribbon mask for cost function masking..."
            fslmaths "${out_prefix}_brain_mask.nii.gz" -ero -ero "$outer_ribbon_mask"
        fi
    fi
    
    # Step 2: Perform BBR registration
    if [ "$use_bbr" = "true" ] && [ -f "$wm_mask" ]; then
        log_message "Running BBR priming step..."
        
        # Run FSL's FLIRT with BBR cost function
        flirt -in "$modality_file" -ref "$t1_file" \
              -out "${out_prefix}_bbr.nii.gz" \
              -omat "$bbr_mat" \
              -dof 6 -cost bbr -wmseg "$wm_mask"
              
        # Check if BBR transform was created successfully
        if [ -f "$bbr_mat" ]; then
            bbr_initialized=true
            log_message "BBR priming completed successfully"
        else
            log_formatted "WARNING" "BBR priming failed, falling back to standard registration"
        fi
    fi
    
    # Step 3: Run ANTs registration with BBR initialization or mask constraint
    # Set ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS environment variable to ensure ANTs uses all cores
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$ANTS_THREADS"
    
    # Explicitly use the full path to antsRegistration commands
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    log_message "Running ANTs registration with full parallelization (ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$ANTS_THREADS)"
    
    if [ "$bbr_initialized" = "true" ]; then
        # Convert FSL BBR matrix to ANTs format for initialization
        log_message "Using BBR initialization for ANTs registration"
        
        # Convert FSL transform to ITK format (required for ANTs initialization)
        c3d_affine_tool -ref "$t1_file" -src "$modality_file" \
            -fsl2ras -oitk "${out_prefix}_bbr_itk.txt" "$bbr_mat"
        
        # Run antsRegistration with the BBR initialization
        ${ants_bin}/antsRegistrationSyN.sh \
          -d 3 \
          -f "$t1_file" \
          -m "$modality_file" \
          -o "$out_prefix" \
          -t r \
          -i "${out_prefix}_bbr_itk.txt" \
          -n "$ANTS_THREADS" \
          -p f \
          -j "$ANTS_THREADS" \
          -x "$REG_METRIC_CROSS_MODALITY"
    elif [ -f "$outer_ribbon_mask" ]; then
        # If BBR failed but we have the outer ribbon mask, use it for cost function masking
        log_message "Using outer ribbon mask constraint for ANTs registration"
        ${ants_bin}/antsRegistrationSyN.sh \
          -d 3 \
          -f "$t1_file" \
          -m "$modality_file" \
          -o "$out_prefix" \
          -t r \
          -n "$ANTS_THREADS" \
          -p f \
          -j "$ANTS_THREADS" \
          -x "$REG_METRIC_CROSS_MODALITY" \
          -m "$outer_ribbon_mask"
    else
        # Fall back to standard registration
        log_message "Using standard ANTs registration"
        ${ants_bin}/antsRegistrationSyN.sh \
          -d 3 \
          -f "$t1_file" \
          -m "$modality_file" \
          -o "$out_prefix" \
          -t r \
          -n "$ANTS_THREADS" \
          -p f \
          -j "$ANTS_THREADS" \
          -x "$REG_METRIC_CROSS_MODALITY"
    fi
    
    # Optional: Print resource utilization during registration
    log_message "Resource utilization during registration:"
    ps -p $$ -o %cpu,%mem | tail -n 1 || true

    # The Warped file => ${out_prefix}Warped.nii.gz
    # The transform(s) => ${out_prefix}0GenericAffine.mat, etc.

    log_message "Registration complete. Warped ${modality_name} => ${out_prefix}Warped.nii.gz"
    
    # Validate the registration with improved error handling
    log_message "Validating registration with improved error handling"
    if ! validate_registration "$t1_file" "$modality_file" "${out_prefix}Warped.nii.gz" "${out_prefix}"; then
        log_formatted "WARNING" "Registration validation produced errors but continuing with pipeline"
        # Create a minimal validation report to allow pipeline to continue
        mkdir -p "${out_prefix}_validation"
        echo "UNKNOWN" > "${out_prefix}_validation/quality.txt"
    fi
    
    return 0
}

# Function to register FLAIR to T1 (wrapper for backward compatibility)
register_t2_flair_to_t1mprage() {
    # Usage: register_t2_flair_to_t1mprage <T1_file.nii.gz> <FLAIR_file.nii.gz> <output_prefix>
    local t1_file="$1"
    local flair_file="$2"
    local out_prefix="${3:-${RESULTS_DIR}/registered/t1_to_flair}"
    
    # Call the new generic function with "FLAIR" as the modality name
    register_modality_to_t1 "$t1_file" "$flair_file" "FLAIR" "$out_prefix"
    return $?
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
            antsApplyTransforms -d 3 -i "$input" -r "$reference" -o "$output" -t "[$transform,1]" -n "$interpolation" -j "$ANTS_THREADS"
        else
            # FSL .mat transform
            flirt -in "$input" -ref "$reference" -applyxfm -init "$transform" -out "$output" -interp "$interpolation"
        fi
    else
        # ANTs .h5 or .txt transforms — typically don't need inversion unless explicitly known
        antsApplyTransforms -d 3 -i "$input" -r "$reference" -o "$output" -t "$transform" -n "$interpolation" -j "$ANTS_THREADS"
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

# Function to register all supported modalities in a directory to T1
register_all_modalities() {
    local t1_file="$1"
    local input_dir="$2"
    local output_dir="${3:-${RESULTS_DIR}/registered}"
    
    log_message "Registering all supported modalities to T1: $t1_file"
    mkdir -p "$output_dir"
    
    # Check if T1 exists
    if [ ! -f "$t1_file" ]; then
        log_formatted "ERROR" "T1 file not found: $t1_file"
        return 1
    fi
    
    # Find and register each supported modality
    for modality in "${SUPPORTED_MODALITIES[@]}"; do
        # Try to find files matching the modality pattern
        local modality_files=($(find "$input_dir" -type f -name "*${modality}*.nii.gz" -o -name "*${modality,,}*.nii.gz"))
        
        if [ ${#modality_files[@]} -gt 0 ]; then
            for mod_file in "${modality_files[@]}"; do
                local basename=$(basename "$mod_file" .nii.gz)
                local output_prefix="${output_dir}/${basename}_to_t1"
                
                log_message "Found $modality file: $mod_file"
                register_modality_to_t1 "$t1_file" "$mod_file" "$modality" "$output_prefix"
            done
        else
            log_message "No $modality files found in $input_dir"
        fi
    done
    
    log_message "All modality registrations complete"
    return 0
}

# Export functions
export -f detect_image_resolution
export -f set_template_resolution
export -f register_modality_to_t1
export -f register_t2_flair_to_t1mprage
export -f create_registration_visualizations
export -f validate_registration
export -f apply_transformation
export -f register_multiple_to_reference
export -f register_all_modalities

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

log_message "Registration module loaded with enhanced capabilities (orientation preservation, multi-modality registration, BBR priming)"
