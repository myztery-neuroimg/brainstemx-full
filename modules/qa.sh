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

# Function to validate a transformation comprehensively
validate_transformation() {
    local fixed="$1"           # Fixed/reference image
    local moving="$2"          # Moving image
    local transform="$3"       # Transformation file
    local fixed_mask="${4:-}"      # Optional: mask in fixed space
    local moving_mask="${5:-}"     # Optional: mask in moving space
    local output_dir="$6"      # Directory for outputs
    local threshold="$7"       # Optional: threshold for binary metrics
    
    echo "Validating transformation from $moving to $fixed"
    mkdir -p "$output_dir"
    
    # Apply transformation to moving image
    local transformed_img="${output_dir}/transformed.nii.gz"
    if [[ "$transform" == *".mat" ]]; then
        # FSL linear transform
        flirt -in "$moving" -ref "$fixed" -applyxfm -init "$transform" -out "$transformed_img"
    else
        # ANTs transform
        antsApplyTransforms -d 3 -i "$moving" -r "$fixed" -o "$transformed_img" -t "$transform" -n Linear
    fi
    
    # Apply transformation to moving mask if provided
    local transformed_mask=""
    if [ -n "$moving_mask" ] && [ -f "$moving_mask" ]; then
        transformed_mask="${output_dir}/transformed_mask.nii.gz"
        if [[ "$transform" == *".mat" ]]; then
            flirt -in "$moving_mask" -ref "$fixed" -applyxfm -init "$transform" -out "$transformed_mask" -interp nearestneighbour
        else
            antsApplyTransforms -d 3 -i "$moving_mask" -r "$fixed" -o "$transformed_mask" -t "$transform" -n NearestNeighbor
        fi
        
        # Ensure binary
        fslmaths "$transformed_mask" -bin "$transformed_mask"
    fi
    
    # Calculate intensity-based metrics
    echo "Calculating intensity-based metrics..."
    local cc=$(calculate_cc "$fixed" "$transformed_img" "$fixed_mask")
    local mi=$(calculate_mi "$fixed" "$transformed_img" "$fixed_mask")
    local ncc=$(calculate_ncc "$fixed" "$transformed_img" "$fixed_mask")
    
    echo "  Cross-correlation: $cc"
    echo "  Mutual information: $mi"
    echo "  Normalized cross-correlation: $ncc"
    
    # Calculate overlap metrics if masks are provided
    if [ -n "$transformed_mask" ] && [ -n "$fixed_mask" ] && [ -f "$fixed_mask" ]; then
        echo "Calculating overlap metrics..."
        local dice=$(calculate_dice "$fixed_mask" "$transformed_mask")
        local jaccard=$(calculate_jaccard "$fixed_mask" "$transformed_mask")
        local hausdorff=$(calculate_hausdorff "$fixed_mask" "$transformed_mask")
        
        echo "  Dice coefficient: $dice"
        echo "  Jaccard index: $jaccard"
        echo "  Hausdorff distance: $hausdorff"
    fi
    
    # Create visualization for QC
    echo "Creating visualization for QC..."
    local edge_img="${output_dir}/edge.nii.gz"
    fslmaths "$transformed_img" -edge "$edge_img"
    
    # Create overlay of edges on fixed image
    local overlay_img="${output_dir}/overlay.nii.gz"
    fslmaths "$fixed" -mul 0 -add "$edge_img" "$overlay_img"
    
    # Save report
    echo "Saving validation report..."
    {
        echo "Transformation Validation Report"
        echo "================================"
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Transform: $transform"
        echo ""
        echo "Intensity-based metrics:"
        echo "  Cross-correlation: $cc"
        echo "  Mutual information: $mi"
        echo "  Normalized cross-correlation: $ncc"
        
        if [ -n "$transformed_mask" ] && [ -n "$fixed_mask" ] && [ -f "$fixed_mask" ]; then
            echo ""
            echo "Overlap metrics:"
            echo "  Dice coefficient: $dice"
            echo "  Jaccard index: $jaccard"
            echo "  Hausdorff distance: $hausdorff"
        fi
        
        echo ""
        echo "Validation completed: $(date)"
    } > "${output_dir}/validation_report.txt"
    
    # Determine overall quality
    local quality="UNKNOWN"
    if [ -n "$dice" ]; then
        if (( $(echo "$dice > 0.8" | bc -l) )); then
            quality="EXCELLENT"
        elif (( $(echo "$dice > 0.7" | bc -l) )); then
            quality="GOOD"
        elif (( $(echo "$dice > 0.5" | bc -l) )); then
            quality="ACCEPTABLE"
        else
            quality="POOR"
        fi
    elif [ -n "$cc" ]; then
        if (( $(echo "$cc > 0.7" | bc -l) )); then
            quality="GOOD"
        elif (( $(echo "$cc > 0.5" | bc -l) )); then
            quality="ACCEPTABLE"
        else
            quality="POOR"
        fi
    fi
    
    echo "Overall quality assessment: $quality"
    echo "$quality" > "${output_dir}/quality.txt"
    
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

log_message "QA module loaded"
