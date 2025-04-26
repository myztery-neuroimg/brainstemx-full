#!/usr/bin/env bash
#
# qa.sh - QA/Validation functions for the brain MRI processing pipeline
#
# This module contains:
# - Image quality checks
# - Registration validation
# - Segmentation validation
# - Hyperintensity validation
# - Pipeline progress tracking
#

# Function to track pipeline progress and quality
track_pipeline_progress() {
    local subject_id="$1"
    local output_dir="$2"
    local log_file="${output_dir}/progress_log.txt"
    
    echo "Tracking progress for subject: $subject_id"
    mkdir -p "$output_dir"
    
    # Initialize log if it doesn't exist
    if [ ! -f "$log_file" ]; then
        echo "Pipeline Progress Log for $subject_id" > "$log_file"
        echo "Created: $(date)" >> "$log_file"
        echo "----------------------------------------" >> "$log_file"
    fi
    
    # Check for expected output files
    echo "Checking for expected outputs..." | tee -a "$log_file"
    
    # Define expected outputs and their quality metrics
    declare -A expected_outputs
    expected_outputs["T1_brain.nii.gz"]="check_image_statistics:min_nonzero=10000"
    expected_outputs["T2_FLAIR_registered.nii.gz"]="calculate_cc:threshold=0.5"
    expected_outputs["brainstem_mask.nii.gz"]="check_image_statistics:min_nonzero=1000,max_nonzero=50000"
    expected_outputs["pons_mask.nii.gz"]="check_image_statistics:min_nonzero=500,max_nonzero=20000"
    expected_outputs["dorsal_pons_mask.nii.gz"]="check_image_statistics:min_nonzero=200,max_nonzero=10000"
    
    # Check each expected output
    local all_present=true
    local all_valid=true
    
    for output in "${!expected_outputs[@]}"; do
        local file_path="${output_dir}/$output"
        local check_cmd="${expected_outputs[$output]}"
        
        echo -n "  $output: " | tee -a "$log_file"
        
        if [ -f "$file_path" ]; then
            echo -n "PRESENT - " | tee -a "$log_file"
            
            # Parse and run the check command
            local cmd_name=$(echo "$check_cmd" | cut -d':' -f1)
            local cmd_args=$(echo "$check_cmd" | cut -d':' -f2)
            
            # Convert cmd_args to array
            local args_array=()
            IFS=',' read -ra arg_pairs <<< "$cmd_args"
            for pair in "${arg_pairs[@]}"; do
                local key=$(echo "$pair" | cut -d'=' -f1)
                local value=$(echo "$pair" | cut -d'=' -f2)
                args_array+=("$value")
            done
            
            # Run the appropriate check function
            local check_result=false
            case "$cmd_name" in
                "check_image_statistics")
                    check_image_statistics "$file_path" "" "${args_array[0]}" "${args_array[1]}" > /dev/null 2>&1
                    check_result=$?
                    ;;
                "calculate_cc")
                    local cc=$(calculate_cc "$file_path" "${output_dir}/reference.nii.gz")
                    if (( $(echo "$cc > ${args_array[0]}" | bc -l) )); then
                        check_result=0
                    else
                        check_result=1
                    fi
                    ;;
                *)
                    echo "UNKNOWN CHECK" | tee -a "$log_file"
                    check_result=1
                    ;;
            esac
            
            if [ $check_result -eq 0 ]; then
                echo "VALID" | tee -a "$log_file"
            else
                echo "INVALID" | tee -a "$log_file"
                all_valid=false
            fi
        else
            echo "MISSING" | tee -a "$log_file"
            all_present=false
            all_valid=false
        fi
    done
    
    # Summarize progress
    echo "----------------------------------------" >> "$log_file"
    echo "Progress summary:" | tee -a "$log_file"
    
    if $all_present && $all_valid; then
        echo "  Status: COMPLETE - All outputs present and valid" | tee -a "$log_file"
        return 0
    elif $all_present && ! $all_valid; then
        echo "  Status: INVALID - All outputs present but some are invalid" | tee -a "$log_file"
        return 1
    else
        echo "  Status: INCOMPLETE - Some outputs are missing" | tee -a "$log_file"
        return 2
    fi
}

# Function to calculate Dice coefficient between two binary masks
calculate_dice() {
    local mask1="$1"
    local mask2="$2"
    local temp_dir=$(mktemp -d)
    
    # Ensure masks are binary
    fslmaths "$mask1" -bin "${temp_dir}/mask1_bin.nii.gz"
    fslmaths "$mask2" -bin "${temp_dir}/mask2_bin.nii.gz"
    
    # Calculate intersection
    fslmaths "${temp_dir}/mask1_bin.nii.gz" -mul "${temp_dir}/mask2_bin.nii.gz" "${temp_dir}/intersection.nii.gz"
    
    # Get volumes
    local vol1=$(fslstats "${temp_dir}/mask1_bin.nii.gz" -V | awk '{print $1}')
    local vol2=$(fslstats "${temp_dir}/mask2_bin.nii.gz" -V | awk '{print $1}')
    local vol_intersection=$(fslstats "${temp_dir}/intersection.nii.gz" -V | awk '{print $1}')
    
    # Calculate Dice
    local dice=$(echo "scale=4; 2 * $vol_intersection / ($vol1 + $vol2)" | bc)
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "$dice"
}

# Function to check image quality
qa_check_image() {
    local file="$1"
    [ ! -f "$file" ] && { echo "[ERROR] $file not found!" >&2; return 1; }

    echo "=== QA for $file ==="

    # 1) fslinfo: dims, data type, pixdims
    local info
    info=$(fslinfo "$file")
    echo "$info"

    # You might parse out dimension lines or pixdim lines if you want automated checks:
    local dim1 dim2 dim3 dt
    dim1=$(echo "$info" | awk '/dim1/ {print $2}')
    dim2=$(echo "$info" | awk '/dim2/ {print $2}')
    dim3=$(echo "$info" | awk '/dim3/ {print $2}')
    dt=$(echo "$info"  | awk '/datatype/ {print $2}')
    
    # Check for suspicious dimension (like 0 or 1)
    if [ "$dim1" -le 1 ] || [ "$dim2" -le 1 ] || [ "$dim3" -le 1 ]; then
        echo "[WARNING] $file has suspicious dimension(s)!"
    fi

    # 2) fslstats: intensity range, mean, std
    local stats
    stats=$(fslstats "$file" -R -M -S -V)
    echo "Stats: min max mean sd volume => $stats"

    # Extract them individually
    local minval maxval meanval sdval vox
    minval=$(echo "$stats" | awk '{print $1}')
    maxval=$(echo "$stats" | awk '{print $2}')
    meanval=$(echo "$stats"| awk '{print $3}')
    sdval=$(echo "$stats"  | awk '{print $4}')
    vox=$(echo "$stats"     | awk '{print $5}')  # number of voxels (if -V used)

    # Simple checks
    if (( $(echo "$minval == 0 && $maxval == 0" | bc -l) )); then
        echo "[WARNING] All intensities are zero in $file."
    fi
    if (( $(echo "$sdval < 0.0001" | bc -l) )); then
        echo "[WARNING] Very low standard deviation. Possibly uniform or empty volume."
    fi
    if [ "$vox" -le 0 ]; then
        echo "[WARNING] Zero voxels? Possibly corrupted image."
    fi

    echo "=== End QA for $file ==="
    echo
}

# Function to check registration dimensions
qa_check_registration_dims() {
    local warped="$1"
    local reference="$2"

    # Extract dims from fslinfo
    local w_info=$(fslinfo "$warped")
    local r_info=$(fslinfo "$reference")

    # Compare dimension lines
    local w_dim1=$(echo "$w_info" | awk '/dim1/ {print $2}')
    local r_dim1=$(echo "$r_info" | awk '/dim1/ {print $2}')

    # Check if they differ by more than some threshold
    if [ "$w_dim1" -ne "$r_dim1" ]; then
        echo "[WARNING] Warped image dimension doesn't match reference. Possibly reformat needed."
    fi

    # Similarly compare orientation or sform / qform codes using fslhd
}

# Function to check image correlation
qa_check_image_correlation() {
    local image1="$1"
    local image2="$2"

    # 'fslcc' computes correlation coefficient (Pearson's r) in the region where both images have data
    # if not installed, you might use c3d or '3dTcorrelate' from AFNI
    if ! command -v fslcc &>/dev/null; then
        echo "fslcc not found. Install from FSL 6.0.4+ or see alternative correlation methods."
        return
    fi

    local cc=$(fslcc -p 100 "$image1" "$image2" | tail -1 | awk '{print $7}')
    echo "Correlation between $image1 and $image2 = $cc"

    # If correlation < 0.2 => suspicious
    if (( $(echo "$cc < 0.2" | bc -l) )); then
        echo "[WARNING] Very low correlation. Registration may have failed."
    fi
}

# Function to check mask quality
qa_check_mask() {
    local mask_file="$1"
    [ ! -f "$mask_file" ] && { echo "[ERROR] Mask $mask_file not found!"; return 1; }

    # Count the number of non-zero voxels
    local nonzero_vox
    nonzero_vox=$(fslstats "$mask_file" -V | awk '{print $1}')
    local total_vox
    total_vox=$(fslstats "$mask_file" -v | awk '{print $1}') # or from `qa_check_image`

    echo "Mask $mask_file => non-zero voxels: $nonzero_vox"

    # Example logic: if mask has fewer than 500 voxels, or more than 95% of total is non-zero => suspicious
    if [ "$nonzero_vox" -lt 500 ]; then
        echo "[WARNING] Mask $mask_file might be too small."
    fi

    # Alternatively, if we know typical volumes in mm^3, we can do a ratio check:
    local fraction
    fraction=$(awk "BEGIN {printf \"%.3f\", ${nonzero_vox}/${total_vox}}")
    if (( $(echo "$fraction > 0.90" | bc -l) )); then
        echo "[WARNING] $mask_file covers > 90% of the brain? Possibly incorrect."
    fi
}

# Function to calculate Jaccard index
calculate_jaccard() {
    local mask1="$1"
    local mask2="$2"
    local temp_dir=$(mktemp -d)
    
    # Ensure masks are binary
    fslmaths "$mask1" -bin "${temp_dir}/mask1_bin.nii.gz"
    fslmaths "$mask2" -bin "${temp_dir}/mask2_bin.nii.gz"
    
    # Calculate intersection and union
    fslmaths "${temp_dir}/mask1_bin.nii.gz" -mul "${temp_dir}/mask2_bin.nii.gz" "${temp_dir}/intersection.nii.gz"
    fslmaths "${temp_dir}/mask1_bin.nii.gz" -add "${temp_dir}/mask2_bin.nii.gz" -bin "${temp_dir}/union.nii.gz"
    
    # Get volumes
    local vol_intersection=$(fslstats "${temp_dir}/intersection.nii.gz" -V | awk '{print $1}')
    local vol_union=$(fslstats "${temp_dir}/union.nii.gz" -V | awk '{print $1}')
    
    # Calculate Jaccard
    local jaccard=$(echo "scale=4; $vol_intersection / $vol_union" | bc)
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "$jaccard"
}

# Function to calculate Hausdorff distance (requires ANTs)
calculate_hausdorff() {
    local mask1="$1"
    local mask2="$2"
    
    # Use ANTs' MeasureImageSimilarity for Hausdorff distance
    local hausdorff=$(MeasureImageSimilarity 3 1 "$mask1" "$mask2" | grep "Hausdorff" | awk '{print $2}')
    
    echo "$hausdorff"
}

# Function to calculate orientation metrics from registration
calculate_orientation_metrics() {
    local fixed="$1"           # Fixed/reference image
    local warped="$2"          # Warped/registered image
    local output_dir="${3:-./}"
    
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
max_dev = np.max(angles[mask])
std_dev = np.std(angles[mask])

print(f'{mean_dev:.6f},{max_dev:.6f},{std_dev:.6f}')
")
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Return metrics as comma-separated values
    echo "${orient_mean_dev}"
}

# Function to analyze shearing distortion in transformation
analyze_shearing_distortion() {
    local fixed="$1"
    local warped="$2"
    local output_dir="$3"
    
    log_message "Analyzing shearing distortion"
    mkdir -p "$output_dir"
    
    # Extract affine matrix from header
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

# Function to analyze orientation within brainstem/pons regions specifically
analyze_brainstem_orientation() {
    local t1_file="$1"
    local flair_file="$2"
    local brainstem_mask="$3"
    local output_dir="$4"
    
    log_message "Analyzing orientation in brainstem regions"
    mkdir -p "$output_dir"
    
    # Create ROI masks for different parts of the brainstem
    local pons_mask="${RESULTS_DIR}/segmentation/pons/${subject_id}_pons.nii.gz"
    local dorsal_pons="${RESULTS_DIR}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz"
    local ventral_pons="${RESULTS_DIR}/segmentation/pons/${subject_id}_ventral_pons.nii.gz"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Extract brainstem from both T1 and FLAIR
    fslmaths "$t1_file" -mas "$brainstem_mask" "${temp_dir}/t1_brainstem.nii.gz"
    fslmaths "$flair_file" -mas "$brainstem_mask" "${temp_dir}/flair_brainstem.nii.gz"
    
    # Calculate gradients for each modality in brainstem
    fslmaths "${temp_dir}/t1_brainstem.nii.gz" -gradient_x "${temp_dir}/t1_grad_x.nii.gz"
    fslmaths "${temp_dir}/t1_brainstem.nii.gz" -gradient_y "${temp_dir}/t1_grad_y.nii.gz"
    fslmaths "${temp_dir}/t1_brainstem.nii.gz" -gradient_z "${temp_dir}/t1_grad_z.nii.gz"
    
    fslmaths "${temp_dir}/flair_brainstem.nii.gz" -gradient_x "${temp_dir}/flair_grad_x.nii.gz"
    fslmaths "${temp_dir}/flair_brainstem.nii.gz" -gradient_y "${temp_dir}/flair_grad_y.nii.gz"
    fslmaths "${temp_dir}/flair_brainstem.nii.gz" -gradient_z "${temp_dir}/flair_grad_z.nii.gz"
    
    # Calculate angle differences
    local regions=("$brainstem_mask" "$pons_mask" "$dorsal_pons" "$ventral_pons")
    local region_names=("brainstem" "pons" "dorsal_pons" "ventral_pons")
    
    # Create output CSV
    echo "Region,Mean_Angular_Diff,Max_Angular_Diff,Std_Angular_Diff" > "${output_dir}/brainstem_orientation.csv"
    
    # Process each region if it exists
    for i in "${!regions[@]}"; do
        local region="${regions[$i]}"
        local name="${region_names[$i]}"
        
        if [ -f "$region" ]; then
            # Calculate angle map within this region
            fslmaths "${temp_dir}/t1_grad_x.nii.gz" -mas "$region" "${temp_dir}/t1_${name}_grad_x.nii.gz"
            fslmaths "${temp_dir}/t1_grad_y.nii.gz" -mas "$region" "${temp_dir}/t1_${name}_grad_y.nii.gz"
            fslmaths "${temp_dir}/t1_grad_z.nii.gz" -mas "$region" "${temp_dir}/t1_${name}_grad_z.nii.gz"
            
            fslmaths "${temp_dir}/flair_grad_x.nii.gz" -mas "$region" "${temp_dir}/flair_${name}_grad_x.nii.gz"
            fslmaths "${temp_dir}/flair_grad_y.nii.gz" -mas "$region" "${temp_dir}/flair_${name}_grad_y.nii.gz"
            fslmaths "${temp_dir}/flair_grad_z.nii.gz" -mas "$region" "${temp_dir}/flair_${name}_grad_z.nii.gz"
            
            # Calculate dot product components
            fslmaths "${temp_dir}/t1_${name}_grad_x.nii.gz" -mul "${temp_dir}/flair_${name}_grad_x.nii.gz" "${temp_dir}/dot_${name}_x.nii.gz"
            fslmaths "${temp_dir}/t1_${name}_grad_y.nii.gz" -mul "${temp_dir}/flair_${name}_grad_y.nii.gz" "${temp_dir}/dot_${name}_y.nii.gz"
            fslmaths "${temp_dir}/t1_${name}_grad_z.nii.gz" -mul "${temp_dir}/flair_${name}_grad_z.nii.gz" "${temp_dir}/dot_${name}_z.nii.gz"
            
            # Sum components
            fslmaths "${temp_dir}/dot_${name}_x.nii.gz" -add "${temp_dir}/dot_${name}_y.nii.gz" -add "${temp_dir}/dot_${name}_z.nii.gz" "${temp_dir}/dot_${name}_sum.nii.gz"
            
            # Calculate magnitude products for normalization
            fslmaths "${temp_dir}/t1_${name}_grad_x.nii.gz" -sqr -add "${temp_dir}/t1_${name}_grad_y.nii.gz" -sqr -add "${temp_dir}/t1_${name}_grad_z.nii.gz" -sqr -sqrt "${temp_dir}/t1_${name}_mag.nii.gz"
            fslmaths "${temp_dir}/flair_${name}_grad_x.nii.gz" -sqr -add "${temp_dir}/flair_${name}_grad_y.nii.gz" -sqr -add "${temp_dir}/flair_${name}_grad_z.nii.gz" -sqr -sqrt "${temp_dir}/flair_${name}_mag.nii.gz"
            
            # Normalized dot product
            fslmaths "${temp_dir}/dot_${name}_sum.nii.gz" -div "${temp_dir}/t1_${name}_mag.nii.gz" -div "${temp_dir}/flair_${name}_mag.nii.gz" "${temp_dir}/dot_${name}_norm.nii.gz"
            
            # Clamp values for acos
            fslmaths "${temp_dir}/dot_${name}_norm.nii.gz" -thr -1 -uthr 1 "${temp_dir}/dot_${name}_clamped.nii.gz"
            
            # Use acos approximation for angular difference
            fslmaths "${temp_dir}/dot_${name}_clamped.nii.gz" -mul 100 -div 3.14159 "${output_dir}/${name}_angle_map.nii.gz"
            
            # Calculate statistics
            local mean_diff=$(fslstats "${output_dir}/${name}_angle_map.nii.gz" -M)
            local max_diff=$(fslstats "${output_dir}/${name}_angle_map.nii.gz" -R | awk '{print $2}')
            local std_diff=$(fslstats "${output_dir}/${name}_angle_map.nii.gz" -S)
            
            # Add to CSV
            echo "${name},${mean_diff},${max_diff},${std_diff}" >> "${output_dir}/brainstem_orientation.csv"
        fi
    done
    
    # Clean up
    rm -rf "$temp_dir"
    
    log_message "Brainstem orientation analysis complete, results in ${output_dir}/brainstem_orientation.csv"
    return 0
}

# Function to create orientation distortion visualization
visualize_orientation_distortion() {
    local t1_file="$1"
    local orientation_map="$2"
    local output_dir="$3"
    local mask="${4:-}"
    
    log_message "Creating orientation distortion visualization"
    mkdir -p "$output_dir"
    
    # Create a better visualization with FSLeyes command
    echo "fsleyes $t1_file $orientation_map -cm hot -a 80" > "${output_dir}/view_orientation_distortion.sh"
    chmod +x "${output_dir}/view_orientation_distortion.sh"
    
    # Create slices for quick visual inspection
    slicer "$t1_file" "$orientation_map" -a "${output_dir}/orientation_distortion.png"
    
    # If mask is provided, create a masked version
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        fslmaths "$orientation_map" -mas "$mask" "${output_dir}/masked_orientation_distortion.nii.gz"
        
        # Create command for viewing masked version
        echo "fsleyes $t1_file ${output_dir}/masked_orientation_distortion.nii.gz -cm hot -a 80" > "${output_dir}/view_masked_orientation_distortion.sh"
        chmod +x "${output_dir}/view_masked_orientation_distortion.sh"
        
        # Create slices for quick visual inspection of masked version
        slicer "$t1_file" "${output_dir}/masked_orientation_distortion.nii.gz" -a "${output_dir}/masked_orientation_distortion.png"
    fi
    
    return 0
}

# Function to calculate extended registration metrics including orientation
calculate_extended_registration_metrics() {
    local fixed="$1"
    local moving="$2"
    local warped="$3"
    local output_dir="$4"
    local output_csv="${5:-${output_dir}/registration_metrics.csv}"
    
    log_message "Calculating extended registration metrics"
    mkdir -p "$output_dir"
    
    # Calculate standard metrics
    local cc=$(calculate_cc "$fixed" "$warped")
    local mi=$(calculate_mi "$fixed" "$warped")
    local ncc=$(calculate_ncc "$fixed" "$warped")
    
    # Calculate metrics specific to white matter regions
    local wm_mask="${output_dir}/wm_mask.nii.gz"
    fslmaths "$fixed" -thr 0.8 -bin "$wm_mask"  # Simple WM mask based on intensity
    
    local wm_cc=$(calculate_cc "$fixed" "$warped" "$wm_mask")
    
    # Calculate displacement field statistics
    local disp_field="${output_dir}/displacement_field.nii.gz"
    if command -v ANTSUseDeformationFieldToGetAffineTransform &>/dev/null; then
        # Create displacement field
        CreateDisplacementField 3 "${output_dir}/affine.mat" "$disp_field" "$fixed"
        
        # Calculate statistics
        local mean_disp=$(fslstats "$disp_field" -M)
        local std_disp=$(fslstats "$disp_field" -S)
        local max_disp=$(fslstats "$disp_field" -R | awk '{print $2}')
    else
        local mean_disp="N/A"
        local std_disp="N/A"
        local max_disp="N/A"
    fi
    
    # Calculate Jacobian determinant statistics
    local jacobian="${output_dir}/jacobian.nii.gz"
    if command -v CreateJacobianDeterminantImage &>/dev/null; then
        # Create Jacobian determinant image
        CreateJacobianDeterminantImage 3 "${output_dir}/affine.mat" "$jacobian" "$fixed"
        
        # Calculate statistics
        local jacobian_mean=$(fslstats "$jacobian" -M)
        local jacobian_std=$(fslstats "$jacobian" -S)
        local jacobian_min=$(fslstats "$jacobian" -R | awk '{print $1}')
    else
        local jacobian_mean="N/A"
        local jacobian_std="N/A"
        local jacobian_min="N/A"
    fi
    
    # Create header if file doesn't exist
    if [ ! -f "$output_csv" ]; then
        echo "fixed_image,moving_image,dice_coefficient,wm_cross_correlation,mean_displacement,jacobian_std_dev,orientation_mean_dev,orientation_max_dev,orientation_std_dev,quality_assessment" > "$output_csv"
    fi
    
    # Calculate orientation distortion metrics
    log_message "Calculating orientation distortion metrics"
    local orientation_metrics=$(calculate_orientation_metrics "$fixed" "$warped" "${output_dir}/orientation")
    
    # Parse orientation metrics
    local orient_mean_dev=$(echo "$orientation_metrics" | cut -d',' -f1)
    local orient_max_dev=$(echo "$orientation_metrics" | cut -d',' -f2)
    local orient_std_dev=$(echo "$orientation_metrics" | cut -d',' -f3)
    
    log_message "Orientation mean deviation: $orient_mean_dev"
    log_message "Orientation max deviation: $orient_max_dev"
    log_message "Orientation std deviation: $orient_std_dev"
    
    # Evaluate orientation quality
    local orientation_quality="ACCEPTABLE"
    if (( $(echo "$orient_mean_dev < $ORIENTATION_EXCELLENT_THRESHOLD" | bc -l) )); then
        orientation_quality="EXCELLENT"
    elif (( $(echo "$orient_mean_dev < $ORIENTATION_GOOD_THRESHOLD" | bc -l) )); then
        orientation_quality="GOOD"
    elif (( $(echo "$orient_mean_dev > $ORIENTATION_ACCEPTABLE_THRESHOLD" | bc -l) )); then
        orientation_quality="POOR"
    fi
    
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
    
    # Update the final quality assessment to include orientation
    if [ "$orientation_quality" = "POOR" ] && [ "$quality" != "POOR" ]; then
        quality="ACCEPTABLE"  # Downgrade if orientation is poor
    fi
    
    # Write metrics to CSV
    echo "$(basename "$fixed"),$(basename "$moving"),$dice,$wm_cc,$mean_disp,$jacobian_std,$orient_mean_dev,$orient_max_dev,$orient_std_dev,$quality" >> "$output_csv"
    
    # Save detailed report
    {
        echo "Extended Registration Validation Report"
        echo "======================================"
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Warped image: $warped"
        echo ""
        echo "Intensity-based metrics:"
        echo "  Cross-correlation: $cc"
        echo "  Mutual information: $mi"
        echo "  Normalized cross-correlation: $ncc"
        echo "  White matter cross-correlation: $wm_cc"
        echo ""
        echo "Deformation metrics:"
        echo "  Mean displacement: $mean_disp"
        echo "  Max displacement: $max_disp"
        echo "  Jacobian standard deviation: $jacobian_std"
        echo "  Minimum Jacobian determinant: $jacobian_min"
        echo ""
        echo "Orientation metrics:"
        echo "  Mean angular deviation: $orient_mean_dev"
        echo "  Maximum angular deviation: $orient_max_dev"
        echo "  Angular deviation std: $orient_std_dev"
        echo "  Orientation quality: $orientation_quality"
        echo ""
        echo "Overall quality assessment: $quality"
        echo ""
        echo "Validation completed: $(date)"
    } > "${output_dir}/extended_validation_report.txt"
    
    log_message "Extended registration validation completed"
    return 0
}

# Function to validate a transformation comprehensively
validate_transformation() {
    local fixed="$1"                # Fixed/reference image
    local moving="$2"               # Moving image
    local warped="$3"               # Warped/registered image
    local output_prefix="$4"        # Output prefix for results
    local fixed_mask="${5:-}"       # Optional: mask in fixed space
    local moving_mask="${6:-}"      # Optional: mask in moving space
    local transform="${7:-}"        # Optional: transformation file
    local validation_dir="${output_prefix}_validation"
    
    log_message "Validating transformation with orientation metrics"
    mkdir -p "$validation_dir"
    
    # Apply transformation to moving mask if provided
    local transformed_mask=""
    if [ -n "$transform" ] && [ -n "$moving_mask" ] && [ -f "$moving_mask" ]; then
        transformed_mask="${validation_dir}/transformed_mask.nii.gz"
        log_message "Applying transformation to moving mask..."
        
        if [[ "$transform" == *".mat" ]]; then
            # FSL linear transform
            flirt -in "$moving_mask" -ref "$fixed" -applyxfm -init "$transform" -out "$transformed_mask" -interp nearestneighbour
        else
            # ANTs transform
            antsApplyTransforms -d 3 -i "$moving_mask" -r "$fixed" -o "$transformed_mask" -t "$transform" -n NearestNeighbor
        fi
        
        # Ensure binary
        fslmaths "$transformed_mask" -bin "$transformed_mask"
    fi
    
    # Standard validation metrics
    local cc=$(calculate_cc "$fixed" "$warped")
    local mi=$(calculate_mi "$fixed" "$warped")
    local ncc=$(calculate_ncc "$fixed" "$warped")
    
    log_message "Cross-correlation: $cc"
    log_message "Mutual information: $mi"
    log_message "Normalized cross-correlation: $ncc"
    
    # Calculate orientation metrics
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
    
    # Downgrade overall quality if orientation is poor
    if [ "$orientation_quality" = "POOR" ] && [ "$quality" != "POOR" ]; then
        quality="ACCEPTABLE"
    fi
    
    log_message "Overall registration quality: $quality"
    echo "$quality" > "${validation_dir}/quality.txt"
    
    # Save extended validation report
    {
        echo "Extended Registration Validation Report"
        echo "======================================"
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Warped image: $warped"
        echo ""
        echo "Intensity-based metrics:"
        echo "  Cross-correlation: $cc"
        echo "  Mutual information: $mi"
        echo "  Normalized cross-correlation: $ncc"
        echo ""
        echo "Orientation Metrics:"
        echo "  Mean angular deviation: $orient_mean_dev radians"
        echo "  Orientation quality: $orientation_quality"
        echo ""
        echo "Overall quality assessment: $quality"
        echo ""
        echo "Validation completed: $(date)"
    } > "${validation_dir}/validation_report.txt"
    
    # Create visualization for QC
    visualize_orientation_distortion "$fixed" "${validation_dir}/orientation/orientation_deviation.nii.gz" "${validation_dir}"
    
    return 0
}

# Function to calculate cross-correlation between two images
calculate_cc() {
    local img1="$1"
    local img2="$2"
    local mask="${3:-}"  # empty if not passed

   
    local cc_cmd="fslcc -p 10 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        cc_cmd="$cc_cmd -m $mask"
    fi
    
    local cc=$(eval "$cc_cmd" | tail -1 | awk '{print $7}')
    echo "$cc"
}

# Function to calculate mutual information between two images
calculate_mi() {
    local img1="$1"
    local img2="$2"
    local mask="${3:-}"  # empty if not passed
    
    # Use ANTs' MeasureImageSimilarity for MI
    local mi_cmd="MeasureImageSimilarity 3 1 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        mi_cmd="$mi_cmd -m $mask"
    fi
    
    local mi=$(eval "$mi_cmd" | grep "MI" | awk '{print $2}')
    echo "$mi"
}

# Function to calculate normalized cross-correlation between two images
calculate_ncc() {
    local img1="$1"
    local img2="$2"
    local mask="${3:-}"  # empty if not passed
    
    # Use ANTs' MeasureImageSimilarity for NCC
    local ncc_cmd="MeasureImageSimilarity 3 2 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        ncc_cmd="$ncc_cmd -m $mask"
    fi
    
    local ncc=$(eval "$ncc_cmd" | grep "NCC" | awk '{print $2}')
    echo "$ncc"
}

# Function to check image statistics
check_image_statistics() {
    local image="$1"
    local mask="${2:-}"  # empty if not passed
    local min_nonzero="$3"  # Optional
    local max_nonzero="$4"  # Optional
    
    # Get image statistics
    local stats_cmd="fslstats $image -V"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        stats_cmd="$stats_cmd -k $mask"
    fi
    
    local nonzero_vox=$(eval "$stats_cmd" | awk '{print $1}')
    
    # Check against thresholds
    if [ -n "$min_nonzero" ] && [ "$nonzero_vox" -lt "$min_nonzero" ]; then
        echo "[WARNING] Number of non-zero voxels ($nonzero_vox) is less than minimum threshold ($min_nonzero)"
        return 1
    fi
    
    if [ -n "$max_nonzero" ] && [ "$nonzero_vox" -gt "$max_nonzero" ]; then
        echo "[WARNING] Number of non-zero voxels ($nonzero_vox) is greater than maximum threshold ($max_nonzero)"
        return 1
    fi
    
    return 0
}

# Function to validate DICOM files
qa_validate_dicom_files() {
    local dicom_dir="$1"
    local output_dir="${2:-$RESULTS_DIR/validation/dicom}"
    
    echo "Validating DICOM files in $dicom_dir"
    mkdir -p "$output_dir"
    
    # Count DICOM files using configured patterns
    local dicom_count=$(find "$dicom_dir" -type f -name "${DICOM_PRIMARY_PATTERN:-Image-*}" | wc -l)
    if [ "$dicom_count" -eq 0 ]; then
        echo "No files found with primary pattern '${DICOM_PRIMARY_PATTERN:-Image-*}', trying alternative patterns..."
        # Try additional patterns
        for pattern in ${DICOM_ADDITIONAL_PATTERNS:-"*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"}; do
            local pattern_count=$(find "$dicom_dir" -type f -name "$pattern" | wc -l)
            dicom_count=$((dicom_count + pattern_count))
        done
        
        if [ "$dicom_count" -eq 0 ]; then
            echo "[WARNING] No DICOM files found in $dicom_dir"
            return 1
        fi
    fi
    
    echo "Found $dicom_count DICOM files"
    
    # Check for common DICOM headers
    local sample_dicom=$(find "$dicom_dir" -type f -name "${DICOM_PRIMARY_PATTERN:-Image-*}" | head -1)
    if [ -z "$sample_dicom" ]; then
        sample_dicom=$(find "$dicom_dir" -type f -name "${DICOM_ADDITIONAL_PATTERNS%% *}" | head -1)
    fi
    if [ -n "$sample_dicom" ]; then
        echo "Checking DICOM headers in $sample_dicom"
        command -v dcmdump &>/dev/null && dcmdump "$sample_dicom" > "$output_dir/sample_dicom_headers.txt" || echo "dcmdump not available"
    fi
    
    return 0
}

# Function to validate NIfTI files
qa_validate_nifti_files() {
    local nifti_dir="$1"
    
    # Rest of function remains the same
    local output_dir="${2:-$RESULTS_DIR/validation/nifti}"
    
    echo "Validating NIfTI files in $nifti_dir"
    mkdir -p "$output_dir"
    
    # Count NIfTI files
    local nifti_count=$(find "$nifti_dir" -type f -name "*.nii.gz" | wc -l)
    if [ "$nifti_count" -eq 0 ]; then
        echo "[WARNING] No NIfTI files found in $nifti_dir"
        return 1
    fi
    
    echo "Found $nifti_count NIfTI files"
    
    # Check each NIfTI file
    local all_valid=true
    for nifti_file in $(find "$nifti_dir" -type f -name "*.nii.gz"); do
        echo "Checking $nifti_file"
        
        # Check if file is readable
        if ! fslinfo "$nifti_file" &>/dev/null; then
            echo "[ERROR] Failed to read $nifti_file"
            all_valid=false
            continue
        fi
        
        # Check dimensions
        local dims=$(fslinfo "$nifti_file" | grep -E "^dim[1-3]" | awk '{print $2}')
        for dim in $dims; do
            if [ "$dim" -le 1 ]; then
                echo "[WARNING] $nifti_file has suspicious dimension: $dim"
                all_valid=false
                break
            fi
        done
    done
    
    if $all_valid; then
        echo "All NIfTI files are valid"
        return 0
    else
        echo "[WARNING] Some NIfTI files have issues"
        return 1
    fi
}

# Export functions
export -f track_pipeline_progress
export -f calculate_dice
export -f qa_check_image
export -f qa_check_registration_dims
export -f qa_check_image_correlation
export -f qa_check_mask
export -f calculate_jaccard
export -f calculate_hausdorff
export -f validate_transformation
export -f calculate_cc
export -f calculate_mi
export -f calculate_ncc
export -f check_image_statistics
export -f qa_validate_dicom_files
export -f qa_validate_nifti_files
export -f calculate_orientation_metrics
export -f analyze_shearing_distortion
export -f analyze_brainstem_orientation
export -f visualize_orientation_distortion
export -f calculate_extended_registration_metrics

log_message "QA module loaded with orientation distortion capabilities"
