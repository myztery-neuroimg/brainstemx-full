#!/usr/local/bin/bash

#!/usr/bin/env bash
#
# 00_environment.sh
#
# Master environment script that:
#  1) Sets environment variables and pipeline parameters (SRC_DIR, RESULTS_DIR, etc.)
#  2) Defines all the utility functions originally scattered in the big script
#  3) References the optional Python script (extract_dicom_metadata.py)
#
# Each step's sub-script will do:
#    source 00_environment.sh
# and can then call any function or use any variable below.
#
# If any portion of logic (e.g., metadata Python code) is too large, we
# might place it in "01_environment_setup_2.sh" or another file, referencing it here.

set -e
set -u
set -o pipefail


# Process DiCOM MRI images into NiFTi files appropriate for use in FSL/freeview
# My intention is to try to use the `ants` library as well where it can optimise conversions etc.. this is a second attempt only

# Function for logging with timestamps
log_message() {
  local text="$1"
  # Write to both stderr and the LOG_FILE
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" | tee -a "$LOG_FILE" >&2
}

export HISTTIMEFORMAT='%d/%m/%y %T'
# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="../DiCOM"          # DICOM input directory
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix
export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
export ANTS_PATH="~/ants"
export PATH="$PATH:${ANTS_PATH}/bin"
export LOG_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOG_DIR"

# Log file capturing pipeline-wide logs
export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# ------------------------------------------------------------------------------
# Logging & Color Setup
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_formatted() {
  local level=$1
  local message=$2
  case $level in
    "INFO")    echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR")   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
    *)         echo -e "[LOG] $message" >&2 ;;
  esac
}


export log_message

# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
PROCESSING_DATATYPE="float"  # internal float
OUTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # override if needed

# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi

# Parse out the fields for general sequences
N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
TEMPLATE_ITERATIONS=2
TEMPLATE_GRADIENT_STEP=0.2
TEMPLATE_TRANSFORM_MODEL="SyN"
TEMPLATE_SIMILARITY_METRIC="CC"
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
TEMPLATE_WEIGHTS="100x50x50x10"

# Registration & motion correction
REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
REG_METRIC_CROSS_MODALITY="MI"
REG_METRIC_SAME_MODALITY="CC"
ANTS_THREADS=12
REG_PRECISION=1

# Hyperintensity detection
THRESHOLD_WM_SD_MULTIPLIER=2.3
MIN_HYPERINTENSITY_SIZE=4

# Tissue segmentation parameters
ATROPOS_T1_CLASSES=3
ATROPOS_FLAIR_CLASSES=4
ATROPOS_CONVERGENCE="5,0.0"
ATROPOS_MRF="[0.1,1x1x1]"
ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
PADDING_X=5
PADDING_Y=5
PADDING_Z=5
C3D_CROP_THRESHOLD=0.1
C3D_PADDING_MM=5

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

qa_check_image_correlation() {
  local image1="$1"
  local image2="$2"

  # 'fslcc' computes correlation coefficient (Pearson’s r) in the region where both images have data
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
    local fixed_mask="$4"      # Optional: mask in fixed space
    local moving_mask="$5"     # Optional: mask in moving space
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
    if [ -n "$transformed_mask" ] && [ -n "$fixed_mask" ] && [ -f "$fixed_mask"]; then
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
    local mask="$3"  # Optional
    
    local cc_cmd="fslcc -p 10 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        cc_cmd="$cc_cmd -m $mask"
    fi
    
    local cc=$($cc_cmd | tail -n 1)
    
    echo "$cc"
}

# Function to calculate mutual information (using ANTs)
calculate_mi() {
    local img1="$1"
    local img2="$2"
    local mask="$3"  # Optional
    
    local mi_cmd="MeasureImageSimilarity 3 2 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        mi_cmd="$mi_cmd -x $mask"
    fi
    
    local mi=$($mi_cmd | grep -oP 'MI: \K[0-9.-]+')
    
    echo "$mi"
}

# Function to calculate normalized cross-correlation (using ANTs)
calculate_ncc() {
    local img1="$1"
    local img2="$2"
    local mask="$3"  # Optional
    
    local ncc_cmd="MeasureImageSimilarity 3 0 $img1 $img2"
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        ncc_cmd="$ncc_cmd -x $mask"
    fi
    
    local ncc=$($ncc_cmd | grep -oP 'NCC: \K[0-9.-]+')
    
    echo "$ncc"
}
# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Template references may fail."
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"

# ------------------------------------------------------------------------------
# Dependency Checks
# ------------------------------------------------------------------------------
check_command() {
  local cmd=$1
  local package=$2
  local hint=${3:-""}

  if command -v "$cmd" &> /dev/null; then
    log_formatted "SUCCESS" "✓ $package is installed ($(command -v "$cmd"))"
    return 0
  else
    log_formatted "ERROR" "✗ $package is not installed or not in PATH"
    [ -n "$hint" ] && log_formatted "INFO" "$hint"
    return 1
  fi
}

check_ants() {
  log_formatted "INFO" "Checking ANTs tools..."
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" \
                    "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_fsl() {
  log_formatted "INFO" "Checking FSL..."
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_freesurfer() {
  log_formatted "INFO" "Checking FreeSurfer..."
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

# For convenience, run them here (or comment out if you have a separate script)
check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix"
check_ants
check_fsl
check_freesurfer

# ------------------------------------------------------------------------------
# Shared Helper Functions (From the Large Script)
# ------------------------------------------------------------------------------
standardize_datatype() {
  local input=$1
  local output=$2
  local dtype=${3:-"float"}
  fslmaths "$input" "$output" -odt "$dtype"
  log_message "Standardized $input to $dtype"
}

set_sequence_params() {
  # Quick function if you want to parse filename and set custom logic
  local file="$1"
  log_message "Analyzing sequence type from $file"
  if [[ "$file" == *"FLAIR"* ]]; then
    log_message "It’s a FLAIR sequence"
    # e.g. apply FLAIR overrides here if needed
  elif [[ "$file" == *"DWI"* || "$file" == *"ADC"* ]]; then
    log_message "It’s a DWI sequence"
  elif [[ "$file" == *"SWI"* ]]; then
    log_message "It’s an SWI sequence"
  else
    log_message "Defaulting to T1"
  fi
}

deduplicate_identical_files() {
  local dir="$1"
  log_message "==== Deduplicating identical files in $dir ===="
  [ -d "$dir" ] || return 0

  mkdir -p "${dir}/tmp_checksums"

  # Symlink checksums
  find "$dir" -name "*.nii.gz" -type f | while read file; do
    local base=$(basename "$file" .nii.gz)
    local checksum=$(md5 -q "$file")
    ln -sf "$file" "${dir}/tmp_checksums/${checksum}_${base}.link"
  done

  # For each unique checksum, keep only one
  find "${dir}/tmp_checksums" -name "*.link" | sort | \
  awk -F'_' '{print $1}' | uniq | while read csum; do
    local allfiles=($(find "${dir}/tmp_checksums" -name "${csum}_*.link" -exec readlink {} \;))
    if [ ${#allfiles[@]} -gt 1 ]; then
      local kept="${allfiles[0]}"
      log_message "Keeping representative file: $(basename "$kept")"
      for ((i=1; i<${#allfiles[@]}; i++)); do
        local dup="${allfiles[$i]}"
        if [ -f "$dup" ]; then
          log_message "Replacing duplicate: $(basename "$dup") => $(basename "$kept")"
          rm "$dup"
          ln "$kept" "$dup"
        fi
      done
    fi
  done
  rm -rf "${dir}/tmp_checksums"
  log_message "Deduplication complete"
}

run_pipeline_batch() {
    local subject_list="$1"
    local base_dir="$2"
    local output_base="$3"
    
    echo "Running brainstem analysis pipeline on subject list: $subject_list"
    
    # Create summary directory
    local summary_dir="${output_base}/summary"
    mkdir -p "$summary_dir"
    
    # Initialize summary report
    local summary_file="${summary_dir}/batch_summary.csv"
    echo "Subject,Status,BrainstemVolume,PonsVolume,DorsalPonsVolume,HyperintensityVolume,LargestClusterVolume,RegistrationQuality" > "$summary_file"
    
    # Process each subject
    while read -r subject_id t2_flair t1; do
        echo "Processing subject: $subject_id"
        
        # Create subject output directory
        local subject_dir="${output_base}/${subject_id}"
        
        # Run processing with validation
        process_subject_with_validation "$t2_flair" "$t1" "$subject_dir" "$subject_id"
        local status=$?
        
        # Determine status text
        local status_text="FAILED"
        if [ $status -eq 0 ]; then
            status_text="COMPLETE"
        elif [ $status -eq 2 ]; then
            status_text="INCOMPLETE"
        fi
        
        # Extract key metrics for summary
        local brainstem_vol="N/A"
        local pons_vol="N/A"
        local dorsal_pons_vol="N/A"
        local hyperintensity_vol="N/A"
        local largest_cluster_vol="N/A"
        local reg_quality="N/A"
        
        if [ -f "${subject_dir}/brainstem/${subject_id}_brainstem.nii.gz" ]; then
            brainstem_vol=$(fslstats "${subject_dir}/brainstem/${subject_id}_brainstem.nii.gz" -V | awk '{print $1}')
        fi
        
        if [ -f "${subject_dir}/brainstem/${subject_id}_pons.nii.gz" ]; then
            pons_vol=$(fslstats "${subject_dir}/brainstem/${subject_id}_pons.nii.gz" -V | awk '{print $1}')
        fi
        
        if [ -f "${subject_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" ]; then
            dorsal_pons_vol=$(fslstats "${subject_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" -V | awk '{print $1}')
        fi
        
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
            hyperintensity_vol=$(fslstats "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -V | awk '{print $1}')
            
            # Get largest cluster size if clusters file exists
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0_clusters.txt" ]; then
                largest_cluster_vol=$(sort -k2,2nr "${subject_dir}/hyperintensities/${subject_id}_dorsal_p
ons_thresh2.0_clusters.txt" | head -2 | tail -1 | awk '{print $2}')
            fi
        fi
        
        if [ -f "${subject_dir}/validation/t1_to_flair/quality.txt" ]; then
            reg_quality=$(cat "${subject_dir}/validation/t1_to_flair/quality.txt")
        fi
        
        # Add to summary
        echo "${subject_id},${status_text},${brainstem_vol},${pons_vol},${dorsal_pons_vol},${hyperintensity_vol},${largest_cluster_vol},${reg_quality}" >> "$summary_file"
        
    done < "$subject_list"
    
    echo "Batch processing complete. Summary available at: $summary_file"
    return 0
}

# Function to generate QC visualizations for a subject
generate_qc_visualizations() {
    local subject_id="$1"
    local subject_dir="$2"
    local output_dir="${subject_dir}/qc_visualizations"
    
    echo "Generating QC visualizations for subject $subject_id"
    mkdir -p "$output_dir"
    
    # Get input files
    local t2_flair=$(find "${subject_dir}" -name "*T2_FLAIR*.nii.gz" | head -1)
    local t1=$(find "${subject_dir}" -name "*T1*.nii.gz" | head -1)
    
    # Create edge overlays for segmentation validation
    for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
        local mask="${subject_dir}/brainstem/${subject_id}_${region}.nii.gz"
        local t2flair="${subject_dir}/brainstem/${subject_id}_${region}_t2flair.nii.gz"
        
        if [ -f "$mask" ] && [ -f "$t2flair" ]; then
            echo "Creating edge overlay for $region..."
            
            # Create edge of mask
            fslmaths "$mask" -edge -bin "${output_dir}/${region}_edge.nii.gz"
            
            # Create RGB overlay for better visualization
            local overlay="${output_dir}/${region}_overlay.nii.gz"
            
            # Create a 3-volume RGB image
            # Red channel: Edge of mask
            # Green channel: Empty
            # Blue channel: Empty
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 1 "${output_dir}/r.nii.gz"
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 0 "${output_dir}/g.nii.gz"
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 0 "${output_dir}/b.nii.gz"
            
            # Merge channels
            fslmerge -t "$overlay" "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Clean up temporary files
            rm "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Create overlay command for fsleyes
            echo "fsleyes $t2flair ${output_dir}/${region}_edge.nii.gz -cm red -a 80" > "${output_dir}/view_${region}_overlay.sh"
            chmod +x "${output_dir}/view_${region}_overlay.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/${region}_edge.nii.gz" -a "${output_dir}/${region}_overlay.png"
        fi
    done
    
    # Create hyperintensity overlays at different thresholds
    for mult in 1.5 2.0 2.5 3.0; do
        local hyper="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
        local t2flair="${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
        
        if [ -f "$hyper" ] && [ -f "$t2flair" ]; then
            echo "Creating hyperintensity overlay for threshold ${mult}..."
            
            # Create binary mask of hyperintensities
            fslmaths "$hyper" -bin "${output_dir}/hyper_${mult}_bin.nii.gz"
            
            # Create RGB overlay
            # Red channel: Hyperintensity
            # Green channel: Empty
            # Blue channel: Empty
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 1 "${output_dir}/r.nii.gz"
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 0 "${output_dir}/g.nii.gz"
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 0 "${output_dir}/b.nii.gz"
            
            # Merge channels
            fslmerge -t "${output_dir}/hyper_${mult}_overlay.nii.gz" "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Clean up temporary files
            rm "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Create overlay command for fsleyes
            echo "fsleyes $t2flair $hyper -cm hot -a 80" > "${output_dir}/view_hyperintensity_${mult}.sh"
            chmod +x "${output_dir}/view_hyperintensity_${mult}.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/hyper_${mult}_bin.nii.gz" -a "${output_dir}/hyperintensity_${mult}.png"
        fi
    done
    
    # Create registration check visualization
    if [ -f "$t2_flair" ] && [ -f "${subject_dir}/t1_to_flair_Warped.nii.gz" ]; then
        echo "Creating registration check visualization..."
        
        local fixed="$t2_flair"
        local moving_reg="${subject_dir}/t1_to_flair_Warped.nii.gz"
        
        # Create checkerboard pattern for registration check
        local checker="${output_dir}/t1_t2_checkerboard.nii.gz"
        
        # Use FSL's checkerboard function
        fslcpgeom "$fixed" "$moving_reg"  # Ensure geometry is identical
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
                        fslmaths "$moving_reg" -roi $((x*block_x)) $block_x $((y*block_y)) $block_y $((z*block_z)) $block_z 0 1 \
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
    fi
    
    # Create difference map for registration quality assessment
    if [ -f "$t2_flair" ] && [ -f "${subject_dir}/t1_to_flair_Warped.nii.gz" ]; then
        echo "Creating registration difference map..."
        
        local fixed="$t2_flair"
        local moving_reg="${subject_dir}/t1_to_flair_Warped.nii.gz"
        
        # Normalize both images to 0-1 range for comparable intensity
        fslmaths "$fixed" -inm 1 "${output_dir}/fixed_norm.nii.gz"
        fslmaths "$moving_reg" -inm 1 "${output_dir}/moving_norm.nii.gz"
        
        # Calculate absolute difference
        fslmaths "${output_dir}/fixed_norm.nii.gz" -sub "${output_dir}/moving_norm.nii.gz" -abs "${output_dir}/reg_diff.nii.gz"
        
        # Create overlay command for fsleyes
        echo "fsleyes $fixed ${output_dir}/reg_diff.nii.gz -cm hot -a 80" > "${output_dir}/view_reg_diff.sh"
        chmod +x "${output_dir}/view_reg_diff.sh"
        
        # Create slices for quick visual inspection
        slicer "${output_dir}/reg_diff.nii.gz" -a "${output_dir}/registration_diff.png"
        
        # Clean up temporary files
        rm "${output_dir}/fixed_norm.nii.gz" "${output_dir}/moving_norm.nii.gz"
    fi
    
    # Create multi-threshold comparison for hyperintensities
    if [ -f "${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz" ]; then
        echo "Creating multi-threshold comparison for hyperintensities..."
        
        local t2flair="${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
        local thresholds=(1.5 2.0 2.5 3.0)
        local colors=("red" "orange" "yellow" "green")
        
        # Create command for viewing all thresholds together
        local fsleyes_cmd="fsleyes $t2flair"
        
        for i in "${!thresholds[@]}"; do
            local mult="${thresholds[$i]}"
            local color="${colors[$i]}"
            local hyper="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
            
            if [ -f "$hyper" ]; then
                fsleyes_cmd="$fsleyes_cmd $hyper -cm $color -a 50"
            fi
        done
        
        echo "$fsleyes_cmd" > "${output_dir}/view_all_thresholds.sh"
        chmod +x "${output_dir}/view_all_thresholds.sh"
        
        # Create a composite image showing all thresholds
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" ]; then
            # Start with lowest threshold
            fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" -bin -mul 1 "${output_dir}/multi_thresh.nii.gz"
            
            # Add higher thresholds with increasing values
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -bin -mul 2 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
           # Add higher thresholds with increasing values
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -bin -mul 2 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" -bin -mul 3 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" -bin -mul 4 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            # Create overlay command for multi-threshold visualization
            echo "fsleyes $t2flair ${output_dir}/multi_thresh.nii.gz -cm hot -a 80" > "${output_dir}/view_multi_thresh.sh"
            chmod +x "${output_dir}/view_multi_thresh.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/multi_thresh.nii.gz" -a "${output_dir}/multi_threshold.png"
        fi
    fi
    
    # Create 3D rendering of hyperintensities for visualization
    if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ] && \
       [ -f "${subject_dir}/brainstem/${subject_id}_pons.nii.gz" ]; then
        echo "Creating 3D rendering of hyperintensities..."
        
        # Create binary mask of hyperintensities
        fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -bin "${output_dir}/hyper_bin.nii.gz"
        
        # Create binary mask of pons
        fslmaths "${subject_dir}/brainstem/${subject_id}_pons.nii.gz" -bin "${output_dir}/pons_bin.nii.gz"
        
        # Create surface meshes if FreeSurfer is available
        if command -v mris_convert &> /dev/null; then
            # Convert binary volumes to surface meshes
            mri_tessellate "${output_dir}/pons_bin.nii.gz" 1 "${output_dir}/pons.stl"
            mri_tessellate "${output_dir}/hyper_bin.nii.gz" 1 "${output_dir}/hyper.stl"
            
            # Create command for viewing in FreeView
            echo "freeview -v ${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz \
                 -f ${output_dir}/pons.stl:edgecolor=blue:color=blue:opacity=0.3 \
                 -f ${output_dir}/hyper.stl:edgecolor=red:color=red:opacity=0.8" > "${output_dir}/view_3d.sh"
            chmod +x "${output_dir}/view_3d.sh"
        fi
    fi

    # Create intensity profile plots along key axes
    if [ -f "${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz" ]; then
        echo "Creating intensity profile plots..."
        
        local t2flair="${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
        
        # Get dimensions
        local dims=($(fslinfo "$t2flair" | grep ^dim | awk '{print $2}'))
        local center_x=$((dims[0] / 2))
        local center_y=$((dims[1] / 2))
        local center_z=$((dims[2] / 2))
        
        # Create directory for intensity profiles
        mkdir -p "${output_dir}/intensity_profiles"
        
        # Extract intensity profiles along three principal axes
        # X-axis profile (sagittal)
        fslroi "$t2flair" "${output_dir}/intensity_profiles/x_line.nii.gz" \
               0 ${dims[0]} $center_y 1 $center_z 1
        
        # Y-axis profile (coronal)
        fslroi "$t2flair" "${output_dir}/intensity_profiles/y_line.nii.gz" \
               $center_x 1 0 ${dims[1]} $center_z 1
        
        # Z-axis profile (axial)
        fslroi "$t2flair" "${output_dir}/intensity_profiles/z_line.nii.gz" \
               $center_x 1 $center_y 1 0 ${dims[2]}
        
        # Extract intensity values along each axis
        for axis in "x" "y" "z"; do
            # Get values using fslmeants
            fslmeants -i "${output_dir}/intensity_profiles/${axis}_line.nii.gz" \
                      > "${output_dir}/intensity_profiles/${axis}_profile.txt"
            
            # Create simple plot script using gnuplot if available
            if command -v gnuplot &> /dev/null; then
                {
                    echo "set terminal png size 800,600"
                    echo "set output '${output_dir}/intensity_profiles/${axis}_profile.png'"
                    echo "set title 'Intensity Profile Along ${axis}-axis'"
                    echo "set xlabel 'Position'"
                    echo "set ylabel 'Intensity'"
                    echo "set grid"
                    echo "plot '${output_dir}/intensity_profiles/${axis}_profile.txt' with lines title '${axis}-axis profile'"
                } > "${output_dir}/intensity_profiles/${axis}_plot.gnuplot"
                
                # Generate the plot
                gnuplot "${output_dir}/intensity_profiles/${axis}_plot.gnuplot"
            fi
        done
    fi
    
    # Create cluster analysis visualization
    if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0_clusters.nii.gz" ]; then
        echo "Creating cluster analysis visualization..."
        
        local clusters="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0_clusters.nii.gz"
        local t2flair="${subject_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
        
        # Create a colorful visualization of clusters
        # Each cluster gets a different color
        fslmaths "$clusters" -bin "${output_dir}/clusters_bin.nii.gz"
        
        # Create overlay command for fsleyes
        echo "fsleyes $t2flair $clusters -cm random -a 80" > "${output_dir}/view_clusters.sh"
        chmod +x "${output_dir}/view_clusters.sh"
        
        # Create slices for quick visual inspection
        slicer "$t2flair" "$clusters" -a "${output_dir}/clusters.png"
    fi

    # Create a comprehensive HTML report
    echo "Creating HTML report..."
    
    {
        echo "<!DOCTYPE html>"
        echo "<html lang='en'>"
        echo "<head>"
        echo "  <meta charset='UTF-8'>"
        echo "  <meta name='viewport' content='width=device-width, initial-scale=1.0'>"
        echo "  <title>Brainstem Analysis QC Report - Subject ${subject_id}</title>"
        echo "  <style>"
        echo "    body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; color: #333; }"
        echo "    h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }"
        echo "    h2 { color: #2980b9; margin-top: 30px; }"
        echo "    h3 { color: #3498db; }"
        echo "    .container { max-width: 1200px; margin: 0 auto; }"
        echo "    .section { margin-bottom: 40px; }"
        echo "    .image-container { display: flex; flex-wrap: wrap; gap: 20px; margin: 20px 0; }"
        echo "    .image-box { border: 1px solid #ddd; padding: 10px; border-radius: 5px; }"
        echo "    .image-box img { max-width: 100%; height: auto; }"
        echo "    .image-box p { margin: 10px 0 0; font-weight: bold; text-align: center; }"
        echo "    table { width: 100%; border-collapse: collapse; margin: 20px 0; }"
        echo "    th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #ddd; }"
        echo "    th { background-color: #f8f9fa; }"
        echo "    tr:hover { background-color: #f1f1f1; }"
        echo "    .metric-good { color: green; }"
        echo "    .metric-warning { color: orange; }"
        echo "    .metric-bad { color: red; }"
        echo "    .summary-box { background-color: #f8f9fa; border-left: 4px solid #3498db; padding: 15px; margin: 20px 0; }"
        echo "  </style>"
        echo "</head>"
        echo "<body>"
        echo "  <div class='container'>"
        echo "    <h1>Brainstem Analysis QC Report</h1>"
        echo "    <div class='summary-box'>"
        echo "      <h2>Subject: ${subject_id}</h2>"
        echo "      <p>Report generated: $(date)</p>"
        
        # Add overall quality assessment if available
        if [ -f "${subject_dir}/validation/t1_to_flair/quality.txt" ]; then
            local reg_quality=$(cat "${subject_dir}/validation/t1_to_flair/quality.txt")
            local quality_class="metric-warning"
            
            if [ "$reg_quality" == "EXCELLENT" ] || [ "$reg_quality" == "GOOD" ]; then
                quality_class="metric-good"
            elif [ "$reg_quality" == "POOR" ]; then
                quality_class="metric-bad"
            fi
            
            echo "      <p>Registration Quality: <span class='${quality_class}'>${reg_quality}</span></p>"
        fi
        
        echo "    </div>"
        
         # Section 1: Segmentation Results
        echo "    <div class='section'>"
        echo "      <h2>1. Brainstem Segmentation</h2>"
        
        # Add segmentation statistics if available
        echo "      <h3>Volumetric Analysis</h3>"
        echo "      <table>"
        echo "        <tr><th>Region</th><th>Volume (mm³)</th></tr>"
        
        for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
            local mask="${subject_dir}/brainstem/${subject_id}_${region}.nii.gz"
            if [ -f "$mask" ]; then
                local volume=$(fslstats "$mask" -V | awk '{print $1}')
                echo "        <tr><td>${region}</td><td>${volume}</td></tr>"
            fi
        done
        
        echo "      </table>"
        
        # Add segmentation visualizations
        echo "      <h3>Segmentation Visualization</h3>"
        echo "      <div class='image-container'>"
        
        for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
            if [ -f "${output_dir}/${region}_overlay.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='${region}_overlay.png' alt='${region} segmentation'>"
                echo "          <p>${region} Segmentation</p>"
                echo "        </div>"
            fi
        done
        
        echo "      </div>"
        echo "    </div>"
        
        # Section 2: Registration Quality
        echo "    <div class='section'>"
        echo "      <h2>2. Registration Quality</h2>"
        
        # Add registration visualizations
        if [ -f "${output_dir}/registration_check.png" ]; then
            echo "      <div class='image-container'>"
            echo "        <div class='image-box'>"
            echo "          <img src='registration_check.png' alt='Registration Checkerboard'>"
            echo "          <p>T1-T2 Registration Checkerboard</p>"
            echo "        </div>"
            
            if [ -f "${output_dir}/registration_diff.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='registration_diff.png' alt='Registration Difference Map'>"
                echo "          <p>Registration Difference Map</p>"
                echo "        </div>"
            fi
            
            echo "      </div>"
        fi
        
        # Add registration metrics if available
        if [ -f "${subject_dir}/validation/t1_to_flair/validation_report.txt" ]; then
            echo "      <h3>Registration Metrics</h3>"
            echo "      <pre>"
            cat "${subject_dir}/validation/t1_to_flair/validation_report.txt" | grep -E "Cross-correlation|Mutual information|Normalized cross-correlation|Dice coefficient|Jaccard index"
            echo "      </pre>"
        fi
        
        echo "    </div>"
        
        # Section 3: Hyperintensity Analysis
        echo "    <div class='section'>"
        echo "      <h2>3. Hyperintensity Analysis</h2>"
        
        # Add hyperintensity visualizations
        echo "      <h3>Threshold Comparison</h3>"
        echo "      <div class='image-container'>"
        
        for mult in 1.5 2.0 2.5 3.0; do
            if [ -f "${output_dir}/hyperintensity_${mult}.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='hyperintensity_${mult}.png' alt='Hyperintensity Threshold ${mult}'>"
                echo "          <p>Threshold: ${mult} × SD</p>"
                echo "        </div>"
            fi
        done
        
        if [ -f "${output_dir}/multi_threshold.png" ]; then
            echo "        <div class='image-box'>"
            echo "          <img src='multi_threshold.png' alt='Multi-threshold Comparison'>"
            echo "          <p>Multi-threshold Comparison</p>"
            echo "        </div>"
        fi
        # Add cluster visualization if available
        if [ -f "${output_dir}/clusters.png" ]; then
            echo "      <h3>Cluster Analysis</h3>"
            echo "      <div class='image-container'>"
            echo "        <div class='image-box'>"
            echo "          <img src='clusters.png' alt='Cluster Analysis'>"
            echo "          <p>Cluster Analysis (2.0 × SD threshold)</p>"
            echo "        </div>"
            echo "      </div>"
        fi
        
        echo "    </div>"
        
        # Section 4: Intensity Profiles
        if [ -d "${output_dir}/intensity_profiles" ]; then
            echo "    <div class='section'>"
            echo "      <h2>4. Intensity Profiles</h2>"
            echo "      <div class='image-container'>"
            
            for axis in "x" "y" "z"; do
                if [ -f "${output_dir}/intensity_profiles/${axis}_profile.png" ]; then
                    echo "        <div class='image-box'>"
                    echo "          <img src='intensity_profiles/${axis}_profile.png' alt='${axis}-axis Intensity Profile'>"
                    echo "          <p>${axis}-axis Intensity Profile</p>"
                    echo "        </div>"
                fi
            done
            
            echo "      </div>"
            echo "    </div>"
        fi
        
        # Section 5: 3D Visualization
        if [ -f "${output_dir}/view_3d.sh" ]; then
            echo "    <div class='section'>"
            echo "      <h2>5. 3D Visualization</h2>"
            echo "      <p>3D visualization is available. Run the following command to view:</p>"
            echo "      <pre>cd ${output_dir} && ./view_3d.sh</pre>"
            echo "    </div>"
        fi
        
        # Footer
        echo "    <div class='section'>"
        echo "      <p>For more detailed analysis, please use the provided visualization scripts in the QC directory.</p>"
        echo "    </div>"
        
        echo "  </div>"
        echo "</body>"
    fi
}
# Example usage:
# run_pipeline_batch "subject_list.txt" "/data/raw" "/data/processed"

combine_multiaxis_images() {
  local sequence_type="$1"
  local output_dir="$2"
  mkdir -p "$output_dir"
  log_message "Combining multi-axis images for $sequence_type"

  # Find SAG, COR, AX
  local sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  local ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # pick best resolution from each orientation
  local best_sag="" best_cor="" best_ax=""
  local best_sag_res=0 best_cor_res=0 best_ax_res=0

  for file in "${sag_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_sag_res ]; then
      best_sag="$file"; best_sag_res=$res
    fi
  done
  for file in "${cor_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_cor_res ]; then
      best_cor="$file"; best_cor_res=$res
    fi
  done
  for file in "${ax_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_ax_res ]; then
      best_ax="$file"; best_ax_res=$res
    fi
  done

  local out_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"

  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG, COR, AX with antsMultivariateTemplateConstruction2.sh"
    antsMultivariateTemplateConstruction2.sh \
      -d 3 \
      -o "${output_dir}/${sequence_type}_template_" \
      -i $TEMPLATE_ITERATIONS \
      -g $TEMPLATE_GRADIENT_STEP \
      -j $ANTS_THREADS \
      -f $TEMPLATE_SHRINK_FACTORS \
      -s $TEMPLATE_SMOOTHING_SIGMAS \
      -q $TEMPLATE_WEIGHTS \
      -t $TEMPLATE_TRANSFORM_MODEL \
      -m $TEMPLATE_SIMILARITY_METRIC \
      -c 0 \
      "$best_sag" "$best_cor" "$best_ax"

    mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$out_file"
    standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
    log_formatted "SUCCESS" "Created high-res combined: $out_file"

  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    if [ -n "$best_sag" ]; then best_file="$best_sag"
    elif [ -n "$best_cor" ]; then best_file="$best_cor"
    elif [ -n "$best_ax" ]; then best_file="$best_ax"
    fi
    if [ -n "$best_file" ]; then
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_message "Used single orientation: $best_file"
    else
      log_formatted "ERROR" "No $sequence_type files found"
    fi
  fi
}

get_n4_parameters() {
  local file="$1"
  local iters="$N4_ITERATIONS"
  local conv="$N4_CONVERGENCE"
  local bspl="$N4_BSPLINE"
  local shrk="$N4_SHRINK"

  if [[ "$file" == *"FLAIR"* ]]; then
    iters="$N4_ITERATIONS_FLAIR"
    conv="$N4_CONVERGENCE_FLAIR"
    bspl="$N4_BSPLINE_FLAIR"
    shrk="$N4_SHRINK_FLAIR"
  fi
  echo "$iters" "$conv" "$bspl" "$shrk"
}

extract_siemens_metadata() {
  local dicom_dir="$1"
  log_message "dicom_dir: $dicom_dir"
  [ -e "$dicom_dir" ] || return 0

  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"

  log_message "Extracting Siemens MAGNETOM Sola metadata..."

  local first_dicom
  first_dicom=$(find "$dicom_dir" -name "Image*" -type f | head -1)
  if [ -z "$first_dicom" ]; then
    log_message "No DICOM files found for metadata extraction."
    return 1
  fi

  mkdir -p "$(dirname "$metadata_file")"
  echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file"

  # Path to the external Python script
  local python_script="./extract_dicom_metadata.py"
  if [ ! -f "$python_script" ]; then
    log_message "Python script not found at: $python_script"
    return 1
  fi
  chmod +x "$python_script"

  log_message "Extracting metadata with Python script..."
  if command -v timeout &> /dev/null; then
    timeout 30s python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log"
    local exit_code=$?
    if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
      log_message "Python script timed out. Using default values."
    elif [ $exit_code -ne 0 ]; then
      log_message "Python script failed (exit $exit_code). See python_error.log"
    else
      mv "$metadata_file".tmp "$metadata_file"
      log_message "Metadata extracted successfully"
    fi
  else
    # If 'timeout' isn't available, do a manual background kill approach
    python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log" &
    local python_pid=$!
    for i in {1..30}; do
      if ! kill -0 $python_pid 2>/dev/null; then
        # Process finished
        wait $python_pid
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
          mv "$metadata_file".tmp "$metadata_file"
          log_message "Metadata extracted successfully"
        else
          log_message "Python script failed (exit $exit_code)."
        fi
        break
      fi
      sleep 1
      if [ $i -eq 30 ]; then
        kill $python_pid 2>/dev/null || true
        log_message "Script took too long. Using default values."
      fi
    done
  fi
  log_message "Metadata extraction complete"
  return 0
}

optimize_ants_parameters() {
  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"
  if [ ! -f "$metadata_file" ]; then
    log_message "No metadata found. Using default ANTs parameters."
    return
  fi

  if command -v python3 &> /dev/null; then
    # Python script to parse JSON fields
    cat > "${RESULTS_DIR}/metadata/parse_json.py" <<EOF
import json, sys
try:
    with open(sys.argv[1],'r') as f:
        data = json.load(f)
    field_strength = data.get('fieldStrength',3)
    print(f"FIELD_STRENGTH={field_strength}")
    model = data.get('modelName','')
    print(f"MODEL_NAME={model}")
    is_sola = ('MAGNETOM Sola' in model)
    print(f"IS_SOLA={'1' if is_sola else '0'}")
except:
    print("FIELD_STRENGTH=3")
    print("MODEL_NAME=Unknown")
    print("IS_SOLA=0")
EOF
    eval "$(python3 "${RESULTS_DIR}/metadata/parse_json.py" "$metadata_file")"
  else
    FIELD_STRENGTH=3
    MODEL_NAME="Unknown"
    IS_SOLA=0
  fi

  if (( $(echo "$FIELD_STRENGTH > 2.5" | bc -l) )); then
    log_message "Optimizing for 3T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
    N4_CONVERGENCE="0.000001"
    REG_METRIC_CROSS_MODALITY="MI"
  else
    log_message "Optimizing for 1.5T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
    # 1.5T adjustments
    N4_CONVERGENCE="0.0000005"
    N4_BSPLINE=200
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.3]"
    ATROPOS_MRF="[0.15,1x1x1]"
  fi

  if [ "$IS_SOLA" = "1" ]; then
    log_message "Applying specific optimizations for MAGNETOM Sola"
    REG_TRANSFORM_TYPE=3
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"
    N4_BSPLINE=200
  fi
  log_message "ANTs parameters optimized from metadata"
}

process_n4_correction() {
  local file="$1"
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"

  log_message "N4 bias correction: $file"
  # Brain extraction for a better mask
  antsBrainExtraction.sh -d 3 \
    -a "$file" \
    -k 1 \
    -o "${RESULTS_DIR}/bias_corrected/${basename}_" \
    -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
    -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
    -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

  local params=($(get_n4_parameters "$file"))
  local iters=${params[0]}
  local conv=${params[1]}
  local bspl=${params[2]}
  local shrk=${params[3]}

  N4BiasFieldCorrection -d 3 \
    -i "$file" \
    -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
    -o "$output_file" \
    -b "[$bspl]" \
    -s "$shrk" \
    -c "[$iters,$conv]"

  log_message "Saved bias-corrected image: $output_file"
}

standardize_dimensions() {
  local input_file="$1"
  local basename=$(basename "$input_file" .nii.gz)
  local output_file="${RESULTS_DIR}/standardized/${basename}_std.nii.gz"

  log_message "Standardizing dimensions for $basename"

  # Example dimension approach from big script
  local x_dim=$(fslval "$input_file" dim1)
  local y_dim=$(fslval "$input_file" dim2)
  local z_dim=$(fslval "$input_file" dim3)
  local x_pix=$(fslval "$input_file" pixdim1)
  local y_pix=$(fslval "$input_file" pixdim2)
  local z_pix=$(fslval "$input_file" pixdim3)

  # Then the script picks a resolution logic based on filename
  # For brevity, we replicate it or do a single fallback approach.
  # If you want the entire table from your big script, copy that logic here
  # e.g. T1 => 1mm isotropic, FLAIR => 512,512,keep, etc.

  cp "$input_file" "$output_file"
  # Possibly call c3d or ResampleImage to do a real resample
  # e.g.:
  # ResampleImage 3 "$input_file" "$output_file" 256x256x192 0 3

  log_message "Saved standardized image: $output_file"
}

process_cropping_with_padding() {
  local file="$1"
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"

  mkdir -p "${RESULTS_DIR}/cropped"
  log_message "Cropping w/ padding: $file"

  # c3d approach from the big script
  c3d "$file" -as S \
    "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" \
    -push S \
    -thresh $C3D_CROP_THRESHOLD 1 1 0 \
    -trim ${C3D_PADDING_MM}mm \
    -o "$output_file"

  log_message "Saved cropped file: $output_file"
}

# If you also want a function to run morphological hyperintensity detection,
# Atropos-based segmentation, etc., you can copy that entire block from the big script
# and wrap it in a function here (e.g. "detect_hyperintensities()"). The same applies
# for "registration" steps or "quality checks." Put them all here so sub-scripts
# only do calls, not define them.
mkdir -p "$EXTRACT_DIR"
mkdir -p "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR/metadata"
mkdir -p "$RESULTS_DIR/cropped"
mkdir -p "$RESULTS_DIR/standardized"
mkdir -p "$RESULTS_DIR/bias_corrected"

detect_hyperintensities() {
    # Usage: detect_hyperintensities <FLAIR_input.nii.gz> <output_prefix> [<T1_input.nii.gz>]
    #
    # 1) Brain-extract the FLAIR
    # 2) Optional: If T1 provided, use Atropos segmentation from T1 or cross-modality
    # 3) Threshold + morphological operations => final hyperintensity mask
    # 4) Produce .mgz overlays for quick Freeview
    #
    # Example:
    # detect_hyperintensities T2_SPACE_FLAIR_Sag.nii.gz results/hyper_flair T1_MPRAGE_SAG.nii.gz

    local flair_file="$1"
    local out_prefix="$2"
    local t1_file="${3}"   # optional

    if [ ! -f "$flair_file" ]; then
        log_message "Error: FLAIR file not found: $flair_file"
        return 1
    fi

    mkdir -p "$(dirname "$out_prefix")"

    log_message "=== Hyperintensity Detection ==="
    log_message "FLAIR input: $flair_file"
    if [ -n "$t1_file" ]; then
        log_message "Using T1 for segmentation: $t1_file"
    else
        log_message "No T1 file provided, will fallback to intensity-based segmentation"
    fi

    # 1) Brain extraction for the FLAIR
    local flair_basename
    flair_basename=$(basename "$flair_file" .nii.gz)
    local brainextr_dir
    brainextr_dir="$(dirname "$out_prefix")/${flair_basename}_brainextract"

    mkdir -p "$brainextr_dir"

    antsBrainExtraction.sh \
      -d 3 \
      -a "$flair_file" \
      -o "${brainextr_dir}/" \
      -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
      -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
      -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
      -k 1

    local flair_brain="${brainextr_dir}/BrainExtractionBrain.nii.gz"
    local flair_mask="${brainextr_dir}/BrainExtractionMask.nii.gz"

    # 2) Tissue Segmentation
    # If T1 is provided, you can do cross-modality with Atropos
    local segmentation_out="${out_prefix}_atropos_seg.nii.gz"
    local wm_mask="${out_prefix}_wm_mask.nii.gz"
    local gm_mask="${out_prefix}_gm_mask.nii.gz"

    if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
        # Register T1 to FLAIR or vice versa, or assume they match dimensions
        log_message "Registering ${flair_brain} to ${t1_file}"
        #flirt -in "$t1_file" -ref "$flair_brain" -omat "t1_to_flair.mat"

        ## If misaligned, register
        #flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -applyxfm -init t1_to_flair.mat


    t1_registered="${out_prefix}_T1_registered.nii.gz"

    # Verify alignment: Check if T1 and FLAIR have identical headers
    #if fslinfo "$t1_file" | grep -q "$(fslinfo "$flair_brain" | grep 'dim1')"; then
        echo "T1 and FLAIR appear to have matching dimensions. Skipping registration."
        cp "$t1_file" "$t1_registered"  # Just copy it if already aligned
    #else
    #    echo "Registering T1 to FLAIR..."
    #    flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -omat "t1_to_flair.mat" -dof 6
    #fi

        # Then run Atropos on FLAIR using T1 as additional input if needed, or just on FLAIR alone.

        Atropos -d 3 \
          -a "$flair_brain" \
          -a "$t1_file" \
          -s 2 \
          -x "$flair_mask" \
          -o "[$segmentation_out,${out_prefix}_atropos_prob%02d.nii.gz]" \
          -c "[${ATROPOS_CONVERGENCE}]" \
          -m "${ATROPOS_MRF}" \
          -i "${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}]" \
          -k Gaussian

        # Typical labeling: 1=CSF, 2=GM, 3=WM, 4=Lesion? (depends on your config)

        # Verify which label is which
        fslstats "$segmentation_out" -R

        ThresholdImage 3 "$segmentation_out" "$wm_mask" 3 3
        ThresholdImage 3 "$segmentation_out" "$gm_mask" 2 2

    else
        # Fallback to intensity-based segmentation (Otsu or simple approach)
        log_message "No T1 provided; using Otsu-based 3-class segmentation"

        ThresholdImage 3 "$flair_brain" "${out_prefix}_otsu.nii.gz" Otsu 3 "$flair_mask"
        # Typically label 3 => brightest intensities => approximate WM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$wm_mask" 3 3
        # Label 2 => GM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$gm_mask" 2 2
    fi

    # 3) Compute WM stats to define threshold
    local mean_wm
    local sd_wm
    mean_wm=$(fslstats "$flair_brain" -k "$wm_mask" -M)
    sd_wm=$(fslstats "$flair_brain" -k "$wm_mask" -S)
    log_message "WM mean: $mean_wm   WM std: $sd_wm"

    # You can define a multiplier or use the global THRESHOLD_WM_SD_MULTIPLIER
    local threshold_multiplier="$THRESHOLD_WM_SD_MULTIPLIER"
    local thr_val
    thr_val=$(echo "$mean_wm + $threshold_multiplier * $sd_wm" | bc -l)
    log_message "Threshold = WM_mean + $threshold_multiplier * WM_SD = $thr_val"

    # 4) Threshold + morphological operations
    local init_thr="${out_prefix}_init_thr.nii.gz"
    ThresholdImage 3 "$flair_brain" "$init_thr" "$thr_val" 999999 "$flair_mask"

    # Combine with WM + GM if you want to exclude CSF
    local tissue_mask="${out_prefix}_brain_tissue.nii.gz"
    ImageMath 3 "$tissue_mask" + "$wm_mask" "$gm_mask"

    local combined_thr="${out_prefix}_combined_thr.nii.gz"
    ImageMath 3 "$combined_thr" m "$init_thr" "$tissue_mask"

    # Morphological cleanup
    local eroded="${out_prefix}_eroded.nii.gz"
    local eroded_dilated="${out_prefix}_eroded_dilated.nii.gz"
    ImageMath 3 "$eroded" ME "$combined_thr" 1
    ImageMath 3 "$eroded_dilated" MD "$eroded" 1

    # Remove small islands with connected components
    local final_mask="${out_prefix}_T1_registered.nii.gz"
    #ImageMath 3 "$final_mask" GetLargestComponents "$eroded_dilated" $MIN_HYPERINTENSITY_SIZE

    c3d "$eroded_dilated" \
     -connected-components 26 \
     -threshold $MIN_HYPERINTENSITY_SIZE inf 1 0 \
     -o "$final_mask"

    log_message "Final hyperintensity mask saved to: $final_mask"

    # 5) Optional: Convert to .mgz or create a freeview script
    local flair_norm_mgz="${out_prefix}_flair.mgz"
    local hyper_clean_mgz="${out_prefix}_hyper.mgz"
    mri_convert "$flair_brain" "$flair_norm_mgz"
    mri_convert "$final_mask" "$hyper_clean_mgz"

    cat > "${out_prefix}_view_in_freeview.sh" << EOC
#!/usr/bin/env bash
freeview -v "$flair_norm_mgz" \\
         -v "$hyper_clean_mgz":colormap=heat:opacity=0.5
EOC
    chmod +x "${out_prefix}_view_in_freeview.sh"

    log_message "Hyperintensity detection complete. To view in freeview, run: ${out_prefix}_view_in_freeview.sh"
}

registration_flair_to_t1() {
    # Usage: registration_flair_to_t1 <T1_file.nii.gz> <FLAIR_file.nii.gz> <output_prefix>
    #
    # If T1 and FLAIR have identical dimensions & orientation, you might only need a
    # simple identity transform or a short rigid alignment.
    # This snippet uses antsRegistrationSyN for a minimal transformation.

    local t1_file="$1"
    local flair_file="$2"
    local out_prefix="$3"

    if [ ! -f "$t1_file" ] || [ ! -f "$flair_file" ]; then
        log_message "Error: T1 or FLAIR file not found"
        return 1
    fi

    log_message "=== Registering FLAIR to T1 ==="
    log_message "T1: $t1_file"
    log_message "FLAIR: $flair_file"
    log_message "Output prefix: $out_prefix"

    # If T1 & FLAIR are from the same 3D session, we can use a simpler transform
    # -t r => rigid. For cross-modality, we can specify 'MI' or 'CC'.
    # antsRegistrationSyN.sh defaults to 's' (SyN) with reg type 'r' or 'a'.
    # Let's do a short approach:
    
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
}

log_message "Done loading all environment variables & functions in 00_environment.sh"

extract_brainstem_standardspace() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
    
    # Path to Harvard-Oxford Subcortical atlas (more reliable than Talairach for this task)
    harvard_subcortical="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-2mm.nii.gz"
    
    if [ ! -f "$standard_template" ]; then
        echo "Error: Standard template not found at $standard_template"
        return 1
    fi
    
    if [ ! -f "$harvard_subcortical" ]; then
        echo "Error: Harvard-Oxford subcortical atlas not found at $harvard_subcortical"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Step 1: Register input to standard space
    echo "Registering input to standard space..."
    flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
    
    # Step 2: Generate inverse transformation matrix
    echo "Generating inverse transformation..."
    convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
    
    # Step 3: Extract brainstem from Harvard-Oxford subcortical atlas
    echo "Extracting brainstem mask from Harvard-Oxford atlas..."
    # In Harvard-Oxford subcortical atlas, brainstem is index 16
    fslmaths "$harvard_subcortical" -thr 16 -uthr 16 -bin "${temp_dir}/brainstem_mask_std.nii.gz"
    
    # Step 4: Apply mask to input in standard space
    echo "Applying mask in standard space..."
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/brainstem_mask_std.nii.gz" "${temp_dir}/brainstem_std.nii.gz"
    
    # Step 5: Transform masked image back to original space
    echo "Transforming back to original space..."
    flirt -in "${temp_dir}/brainstem_std.nii.gz" -ref "$input_file" -out "$output_file" -applyxfm -init "${temp_dir}/std2input.mat"
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "Completed. Brainstem extracted to: $output_file"
    return 0
}


extract_brainstem_talairach() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz"

    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-1mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    log_message "Processing $input_file..."
    
    # Talairach indices based on your output
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # Extract each region and combine
    echo "Extracting brainstem regions..."
    
    # Step 1: Register input to standard space
    echo "Registering input to standard space..."
    flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
    
    # Step 2: Generate inverse transformation matrix
    echo "Generating inverse transformation..."
    convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
    
    # Step 3: Extract each region from Talairach atlas
    echo "Extracting brainstem regions from Talairach atlas..."
    
    # Medulla
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    
    # Pons
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    
    # Midbrain
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all regions for full brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/brainstem_mask_std.nii.gz"
    
    # Step 4: Apply masks to input in standard space
    echo "Applying masks in standard space..."
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/brainstem_mask_std.nii.gz" "${temp_dir}/brainstem_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/medulla.nii.gz" "${temp_dir}/medulla_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/pons.nii.gz" "${temp_dir}/pons_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/midbrain.nii.gz" "${temp_dir}/midbrain_std.nii.gz"
    
    # Step 5: Transform masked images back to original space
    echo "Transforming back to original space..."
    flirt -in "${temp_dir}/brainstem_std.nii.gz" -ref "$input_file" -out "$output_file" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/medulla_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_medulla.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/pons_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_pons.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/midbrain_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_midbrain.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    

    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

extract_brainstem_final() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Talairach indices
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # First, get dimensions of both images
    echo "Checking image dimensions..."
    fslinfo "$input_file" > "${temp_dir}/input_info.txt"
    fslinfo "$talairach_atlas" > "${temp_dir}/atlas_info.txt"
    
    # Create a proper mask of each region in Talairach space
    echo "Creating masks in Talairach space..."
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    
    # Combine regions
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all for complete brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/talairach_brainstem.nii.gz"
    
    echo "Direct registration from Talairach to input space..."
    
    # Register atlas to input space directly
    flirt -in "$talairach_atlas" -ref "$input_file" -out "${temp_dir}/talairach_in_input_space.nii.gz" -omat "${temp_dir}/tal2input.mat" -dof 12
    
    # Use the same transformation to bring the masks to input space
    flirt -in "${temp_dir}/talairach_brainstem.nii.gz" -ref "$input_file" -out "${temp_dir}/brainstem_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/medulla.nii.gz" -ref "$input_file" -out "${temp_dir}/medulla_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/pons.nii.gz" -ref "$input_file" -out "${temp_dir}/pons_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/midbrain.nii.gz" -ref "$input_file" -out "${temp_dir}/midbrain_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    
    # Ensure masks are binary after transformation
    fslmaths "${temp_dir}/brainstem_mask.nii.gz" -bin "${temp_dir}/brainstem_mask.nii.gz"
    fslmaths "${temp_dir}/medulla_mask.nii.gz" -bin "${temp_dir}/medulla_mask.nii.gz"
    fslmaths "${temp_dir}/pons_mask.nii.gz" -bin "${temp_dir}/pons_mask.nii.gz"
    fslmaths "${temp_dir}/midbrain_mask.nii.gz" -bin "${temp_dir}/midbrain_mask.nii.gz"
    
    echo "Applying masks to input image..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask.nii.gz" "$output_file"
    fslmaths "$input_file" -mas "${temp_dir}/medulla_mask.nii.gz" "${input_dir}/${input_basename}_medulla.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/pons_mask.nii.gz" "${input_dir}/${input_basename}_pons.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/midbrain_mask.nii.gz" "${input_dir}/${input_basename}_midbrain.nii.gz"
    
    # Clean up
    #rm -rf "$temp_dir"
    
    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

extract_brainstem_ants() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if ANTs is installed
    if ! command -v antsRegistration &> /dev/null; then
        echo "Error: ANTs is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Talairach indices
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # Create masks in Talairach space
    echo "Creating masks in Talairach space..."
    
    # Extract each region
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    
    # Combine regions
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all for complete brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/talairach_brainstem.nii.gz"
    
    # Register atlas to input space using ANTs
    echo "Registering atlas to input space using ANTs..."
    
    # First, create a reference image from the atlas for registration
    # This prevents misinterpretation of the label values during registration
    fslmaths "$talairach_atlas" -bin "${temp_dir}/talairach_ref.nii.gz"
    
    # Perform ANTs registration
    antsRegistration --dimensionality 3 \
                     --float 0 \
                     --output "${temp_dir}/atlas2input" \
                     --interpolation Linear \
                     --use-histogram-matching 0 \
                     --initial-moving-transform [${input_file},${temp_dir}/talairach_ref.nii.gz,1] \
                     --transform Affine[0.1] \
                     --metric MI[${input_file},${temp_dir}/talairach_ref.nii.gz,1,32,Regular,0.25] \
                     --convergence [1000x500x250x100,1e-6,10] \
                     --shrink-factors 8x4x2x1 \
                     --smoothing-sigmas 3x2x1x0vox
    
    # Apply the transformation to the masks
    echo "Applying transformation to masks..."
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/talairach_brainstem.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/brainstem_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/medulla.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/medulla_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/pons.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/pons_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/midbrain.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/midbrain_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    # Ensure masks are binary after transformation
    fslmaths "${temp_dir}/brainstem_mask.nii.gz" -bin "${temp_dir}/brainstem_mask.nii.gz"
    fslmaths "${temp_dir}/medulla_mask.nii.gz" -bin "${temp_dir}/medulla_mask.nii.gz"
    fslmaths "${temp_dir}/pons_mask.nii.gz" -bin "${temp_dir}/pons_mask.nii.gz"
    fslmaths "${temp_dir}/midbrain_mask.nii.gz" -bin "${temp_dir}/midbrain_mask.nii.gz"
    
    # Apply masks to input image
    echo "Applying masks to input image..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask.nii.gz" "$output_file"
    fslmaths "$input_file" -mas "${temp_dir}/medulla_mask.nii.gz" "${input_dir}/${input_basename}_medulla.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/pons_mask.nii.gz" "${input_dir}/${input_basename}_pons.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/midbrain_mask.nii.gz" "${input_dir}/${input_basename}_midbrain.nii.gz"
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

combine_multiaxis_images_highres() {
  local sequence_type="$1"
  local output_dir="$2"

  # *** Input Validation ***

  # 1. Check if sequence_type is provided
  if [ -z "$sequence_type" ]; then
    log_formatted "ERROR" "Sequence type not provided."
    return 1
  fi

  # 2. Check if output_dir is provided
  if [ -z "$output_dir" ]; then
    log_formatted "ERROR" "Output directory not provided."
    return 1
  fi

  # 3. Validate output_dir and create it if necessary
  if [ ! -d "$output_dir" ]; then
    log_message "Output directory '$output_dir' does not exist. Creating it..."
    if ! mkdir -p "$output_dir"; then
      log_formatted "ERROR" "Failed to create output directory: $output_dir"
      return 1
    fi
  fi

  # 4. Check write permissions for output_dir
  if [ ! -w "$output_dir" ]; then
    log_formatted "ERROR" "Output directory '$output_dir' is not writable."
    return 1
  fi

  log_message "Combining multi-axis images for $sequence_type"

  # *** Path Handling ***
  # Use absolute paths to avoid ambiguity
  local EXTRACT_DIR_ABS=$(realpath "$EXTRACT_DIR")
  local output_dir_abs=$(realpath "$output_dir")


  # Find SAG, COR, AX files using absolute path
  local sag_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  local ax_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # pick best resolution from each orientation
  local best_sag="" best_cor="" best_ax=""
  local best_sag_res=0 best_cor_res=0 best_ax_res=0

  # Helper function to calculate in-plane resolution
  calculate_inplane_resolution() {
    local file="$1"
    local pixdim1=$(fslval "$file" pixdim1)
    local pixdim2=$(fslval "$file" pixdim2)
    local inplane_res=$(echo "scale=10; sqrt($pixdim1 * $pixdim1 + $pixdim2 * $pixdim2)" | bc -l)
    echo "$inplane_res"
  }

  for file in "${sag_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    # Lower resolution value means higher resolution image
    if [ -z "$best_sag" ] || (( $(echo "$inplane_res < $best_sag_res" | bc -l) )); then
      best_sag="$file"
      best_sag_res="$inplane_res"
    fi
  done

  for file in "${cor_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    if [ -z "$best_cor" ] || (( $(echo "$inplane_res < $best_cor_res" | bc -l) )); then
      best_cor="$file"
      best_cor_res="$inplane_res"
    fi
  done

  for file in "${ax_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    if [ -z "$best_ax" ] || (( $(echo "$inplane_res < $best_ax_res" | bc -l) )); then
      best_ax="$file"
      best_ax_res="$inplane_res"
    fi
  done

  local out_file="${output_dir_abs}/${sequence_type}_combined_highres.nii.gz"

  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG, COR, AX with antsMultivariateTemplateConstruction2.sh"
    antsMultivariateTemplateConstruction2.sh \
      -d 3 \
      -o "${output_dir_abs}/${sequence_type}_template_" \
      -i $TEMPLATE_ITERATIONS \
      -g $TEMPLATE_GRADIENT_STEP \
      -j $ANTS_THREADS \
      -f $TEMPLATE_SHRINK_FACTORS \
      -s $TEMPLATE_SMOOTHING_SIGMAS \
      -q $TEMPLATE_WEIGHTS \
      -t $TEMPLATE_TRANSFORM_MODEL \
      -m $TEMPLATE_SIMILARITY_METRIC \
      -c 0 \
      "$best_sag" "$best_cor" "$best_ax"

    # Ensure the template file is moved to the correct output directory
    local template_file="${output_dir_abs}/${sequence_type}_template_template0.nii.gz"
    if [ -f "$template_file" ]; then
      mv "$template_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_formatted "SUCCESS" "Created high-res combined: $out_file"
    else
      log_formatted "ERROR" "Template file not found: $template_file"
      return 1
    fi


  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    if [ -n "$best_sag" ]; then best_file="$best_sag"
    elif [ -n "$best_cor" ]; then best_file="$best_cor"
    elif [ -n "$best_ax" ]; then best_file="$best_ax"
    fi
    if [ -n "$best_file" ]; then
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_message "Used single orientation: $best_file"
    else
      log_formatted "ERROR" "No $sequence_type files found"
    fi
  fi
}


export SRC_DIR="../DiCOM"
export EXTRACT_DIR="../extracted"
export RESULTS_DIR="../mri_results"
# N4 Bias Field Correction parameters
export N4_ITERATIONS="50x50x50x50"
export N4_CONVERGENCE="0.0001"

# Configuration parameters for MRI processing pipeline
# Optimized for high-quality processing (512x512 resolution)

#############################################
# General processing parameters
#############################################

# Logging
export LOG_DIR="${RESULTS_DIR}/logs"
export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# Data type for processing (float32 for processing, int16 for storage)
PROCESSING_DATATYPE="float" #set back to float
OUTPUT_DATATYPE="int"

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="LOW"

# Template creation options

# Number of iterations for template creation
TEMPLATE_ITERATIONS=2
# Gradient step size
TEMPLATE_GRADIENT_STEP=0.2
# Transformation model: Rigid, Affine, SyN
TEMPLATE_TRANSFORM_MODEL="SyN"
# Similarity metric: CC, MI, MSQ
TEMPLATE_SIMILARITY_METRIC="CC"
# Registration shrink factors
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
# Smoothing sigmas
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
# Similarity metric weights
TEMPLATE_WEIGHTS="100x50x50x10"


process_subject_with_validation() {
    local t2_flair="$1"
    local t1="$2"
    local output_dir="$3"
    local subject_id="$4"
    
    echo "Processing subject $subject_id with validation"
    mkdir -p "$output_dir"
    local validation_dir="${output_dir}/validation"
    mkdir -p "$validation_dir"
    
    # Step 1: Extract brainstem using Talairach atlas with validation
    echo "Step 1: Extracting brainstem with validation..."
    
    # Run extraction
    extract_brainstem_talairach_1mm "$t2_flair" "${output_dir}/brainstem"
    
    # Validate output exists and has reasonable properties
    if [ ! -f "${output_dir}/brainstem/${subject_id}_brainstem.nii.gz" ]; then
        echo "ERROR: Brainstem extraction failed - output file not found"
        return 1
    fi
    
    # Check brainstem mask properties
    check_image_statistics "${output_dir}/brainstem/${subject_id}_brainstem.nii.gz" "" "0.1" ""
    if [ $? -ne 0 ]; then
        echo "WARNING: Brainstem mask has suspicious statistics"
    fi
    
    # Step 2: Register T1 to T2-FLAIR with validation
    echo "Step 2: Registering T1 to T2-FLAIR with validation..."
    
    # Run registration
    antsRegistrationSyN.sh -d 3 \
        -f "$t2_flair" \
        -m "$t1" \
        -o "${output_dir}/t1_to_flair_" \
        -t s \
        -n 4
    
    # Validate registration quality
    validate_transformation \
        "$t2_flair" \
        "$t1" \
        "${output_dir}/t1_to_flair_1Warp.nii.gz" \
        "${output_dir}/brainstem/${subject_id}_brainstem.nii.gz" \
        "" \
        "${validation_dir}/t1_to_flair"
    
    # Check registration quality
    local reg_quality=$(cat "${validation_dir}/t1_to_flair/quality.txt")
    if [ "$reg_quality" == "POOR" ]; then
        echo "WARNING: T1 to T2-FLAIR registration quality is poor"
    fi
    
    # Step 3: Segment pons with validation
    echo "Step 3: Segmenting pons with validation..."
    
    # Check if pons segmentation exists
    if [ ! -f "${output_dir}/brainstem/${subject_id}_pons.nii.gz" ]; then
        echo "ERROR: Pons segmentation failed - output file not found"
        return 1
    fi
    
    # Check pons mask properties
    check_image_statistics "${output_dir}/brainstem/${subject_id}_pons.nii.gz" "" "0.05" ""
    if [ $? -ne 0 ]; then
        echo "WARNING: Pons mask has suspicious statistics"
    fi
    
    # Step 4: Create dorsal/ventral pons subdivisions with validation
    echo "Step 4: Creating dorsal/ventral pons subdivisions with validation..."
    
    # Get dimensions of pons mask
    local pons_mask="${output_dir}/brainstem/${subject_id}_pons.nii.gz"
    local dims=($(fslinfo "$pons_mask" | grep ^dim | awk '{print $2}'))
    
    # For axial orientation, divide along z-axis
    # Approximate division: upper 40% = dorsal pons, lower 60% = ventral pons
    local z_size=${dims[2]}
    local dorsal_size=$(echo "$z_size * 0.4" | bc | xargs printf "%.0f")
    local ventral_start=$(echo "$dorsal_size + 1" | bc)
    local ventral_size=$(echo "$z_size - $dorsal_size" | bc)
    
    # Create dorsal pons mask (upper portion)
    fslroi "$pons_mask" "${output_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" \
           0 ${dims[0]} 0 ${dims[1]} 0 $dorsal_size
    
    # Create ventral pons mask (lower portion)
    fslroi "$pons_mask" "${output_dir}/brainstem/${subject_id}_ventral_pons.nii.gz" \
           0 ${dims[0]} 0 ${dims[1]} $ventral_start $ventral_size
    
    # Validate dorsal pons segmentation
    check_image_statistics "${output_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" "" "0.02" ""
    if [ $? -ne 0 ]; then
        echo "WARNING: Dorsal pons mask has suspicious statistics"
    fi
    
    # Step 5: Apply masks to T2-FLAIR with validation
    echo "Step 5: Applying masks to T2-FLAIR with validation..."
    
    # Apply masks
    fslmaths "$t2_flair" -mas "${output_dir}/brainstem/${subject_id}_brainstem.nii.gz" \
             "${output_dir}/brainstem/${subject_id}_brainstem_t2flair.nii.gz"
    
    fslmaths "$t2_flair" -mas "${output_dir}/brainstem/${subject_id}_pons.nii.gz" \
             "${output_dir}/brainstem/${subject_id}_pons_t2flair.nii.gz"
    
    fslmaths "$t2_flair" -mas "${output_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" \
             "${output_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
    
    fslmaths "$t2_flair" -mas "${output_dir}/brainstem/${subject_id}_ventral_pons.nii.gz" \
             "${output_dir}/brainstem/${subject_id}_ventral_pons_t2flair.nii.gz"
    
    # Validate masked images
    for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
        local masked_img="${output_dir}/brainstem/${subject_id}_${region}_t2flair.nii.gz"
        
        # Check if file exists
        if [ ! -f "$masked_img" ]; then
            echo "ERROR: Masked $region T2-FLAIR not found"
            continue
        fi
        
        # Check image statistics
        check_image_statistics "$masked_img" "" "" ""
        
        # Create intensity histogram for QC
        fslstats "$masked_img" -H 100 0 1000 > "${validation_dir}/${region}_histogram.txt"
    done
    
    # Step 6: Hyperintensity detection with validation
    echo "Step 6: Detecting hyperintensities with validation..."
    
    # Create hyperintensity detection directory
    local hyperintensity_dir="${output_dir}/hyperintensities"
    mkdir -p "$hyperintensity_dir"
    
    # Detect hyperintensities in dorsal pons
    # Get mean and standard deviation
    local dorsal_pons_img="${output_dir}/brainstem/${subject_id}_dorsal_pons_t2flair.nii.gz"
    local mean=$(fslstats "$dorsal_pons_img" -M)
    local std=$(fslstats "$dorsal_pons_img" -S)
    
    # Create thresholds at different levels
    local thresholds=(1.5 2.0 2.5 3.0)
    
    for mult in "${thresholds[@]}"; do
        local threshold=$(echo "$mean + $mult * $std" | bc -l)
        local output="${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
        
        # Apply threshold
        fslmaths "$dorsal_pons_img" -thr $threshold "$output"
        
        # Validate threshold result
        check_image_statistics "$output" "" "" ""
        
        # Calculate volume
        local volume=$(fslstats "$output" -V | awk '{print $1}')
        echo "Dorsal pons hyperintensity volume (threshold=${mult}*SD): ${volume}mm³"
        
        # Create binary mask for cluster analysis
        fslmaths "$output" -bin "${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_bin.nii.gz"
        
        # Run cluster analysis
        cluster --in="${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_bin.nii.gz" \
                --thresh=0.5 \
                --oindex="${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_clusters" \
                --connectivity=26 \
                --mm > "${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_clusters.txt"
    done
    
    # Step 7: Generate final QC report
    echo "Step 7: Generating final QC report..."
    
    {
        echo "Brainstem Analysis QC Report for Subject: $subject_id"
        echo "=================================================="
        echo "Generated: $(date)"
        echo ""
        echo "Input Files:"
        echo "  T2-FLAIR: $t2_flair"
        echo "  T1: $t1"
        echo ""
        echo "Segmentation Statistics:"
        echo "  Brainstem volume: $(fslstats "${output_dir}/brainstem/${subject_id}_brainstem.nii.gz" -V | awk '{print $1}')mm³"
        echo "  Pons volume: $(fslstats "${output_dir}/brainstem/${subject_id}_pons.nii.gz" -V | awk '{print $1}')mm³"
        echo "  Dorsal pons volume: $(fslstats "${output_dir}/brainstem/${subject_id}_dorsal_pons.nii.gz" -V | awk '{print $1}')mm³"
        echo "  Ventral pons volume: $(fslstats "${output_dir}/brainstem/${subject_id}_ventral_pons.nii.gz" -V | awk '{print $1}')mm³"
        echo ""
        echo "Registration Quality:"
        echo "  T1 to T2-FLAIR: $reg_quality"
        echo ""
        echo "Hyperintensity Analysis:"
        
        for mult in "${thresholds[@]}"; do
            local volume=$(fslstats "${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}.nii.gz" -V | awk '{print $1}')
            local cluster_count=$(wc -l < "${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_clusters.txt")
            # Subtract header lines
            cluster_count=$((cluster_count - 1))
            
            echo "  Threshold ${mult}*SD:"
            echo "    Volume: ${volume}mm³"
            echo "    Cluster count: $cluster_count"
            
            # Get largest cluster size
            if [ $cluster_count -gt 0 ]; then
                local largest_cluster=$(sort -k2,2nr "${hyperintensity_dir}/${subject_id}_dorsal_pons_thresh${mult}_clusters.txt" | head -2 | tail -1)
                local largest_size=$(echo "$largest_cluster" | awk '{print $2}')
                echo "    Largest cluster: ${largest_size}mm³"
            fi
        done
        
        echo ""
        echo "Validation Checks:"
        echo "  All files present: $(if $all_present; then echo "YES"; else echo "NO"; fi)"
        echo "  All validations passed: $(if $all_valid; then echo "YES"; else echo "NO"; fi)"
        
    } > "${output_dir}/qc_report.txt"
    
    echo "Processing complete for subject $subject_id"
    echo "QC report available at: ${output_dir}/qc_report.txt"
    
    # Track overall pipeline progress
    track_pipeline_progress "$subject_id" "$output_dir"
    
    return 0
}


#############################################
# N4 Bias Field Correction parameters
#############################################

# Presets for different quality levels
# Format: iterations, convergence, b-spline grid resolution, shrink factor
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
#N4_PRESET_FLAIR="75x75x75x75,0.0000001,250,2"
export N4_PRESET_FLAIR="$N4_PRESET_LOW"  #"75x75x75x75,0.0000001,250,2"

# Parse preset into individual parameters
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi

# Parse N4 parameters
N4_ITERATIONS=$(echo $N4_PARAMS | cut -d',' -f1)
N4_CONVERGENCE=$(echo $N4_PARAMS | cut -d',' -f2)
N4_BSPLINE=$(echo $N4_PARAMS | cut -d',' -f3)
N4_SHRINK=$(echo $N4_PARAMS | cut -d',' -f4)

# Set parameters by sequence type
N4_ITERATIONS_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f4)

#############################################
# Registration and motion correction parameters
#############################################

# Registration parameters for antsRegistrationSyN.sh
# Options: 0=rigid, 1=affine, 2=rigid+affine+syn (default), 3=affine+syn
REG_TRANSFORM_TYPE=2

# For cross-modality registration (T2/FLAIR to T1)
# Options: CC=cross-correlation, MI=mutual information, Mattes=Mattes mutual information
REG_METRIC_CROSS_MODALITY="MI"

# For same-modality registration
REG_METRIC_SAME_MODALITY="CC"

# Number of threads for ANTs tools
ANTS_THREADS=11

# Registration precision (0=float, 1=double)
REG_PRECISION=1

#############################################
# Hyperintensity detection parameters
#############################################

# Threshold-based method parameters
# Threshold = WM_mean + (WM_SD * THRESHOLD_WM_SD_MULTIPLIER)
THRESHOLD_WM_SD_MULTIPLIER=2.5

# Minimum hyperintensity cluster size (in voxels)
MIN_HYPERINTENSITY_SIZE=10

# Atropos segmentation parameters
# Number of tissue classes for T1 segmentation
ATROPOS_T1_CLASSES=3

# Number of tissue classes for FLAIR segmentation (including hyperintensities)
ATROPOS_FLAIR_CLASSES=4

# Atropos convergence: max_iterations,convergence_threshold
ATROPOS_CONVERGENCE="5,0.0"

# Atropos smoothing factor: MRF_radius,MRF_strength
ATROPOS_MRF="[0.1,1x1x1]"

# Atropos initialization method: kmeans, otsu, or priorprobabilityimages
ATROPOS_INIT_METHOD="kmeans"

#############################################
# Cropping and padding parameters
#############################################

# Padding in voxels for each dimension
PADDING_X=5
PADDING_Y=5
PADDING_Z=5

# C3D cropping threshold (below this value is considered background)
C3D_CROP_THRESHOLD=0.1

# Padding in mm for C3D cropping
C3D_PADDING_MM=5


# Check if all required tools for MRI processing are installed
# Compatible with macOS/Apple Silicon

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log_formatted() {
  local level=$1
  local message=$2
  
  case $level in
    "INFO") echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR") echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
  esac
}

standardize_datatype() {
  local input=$1
  local output=$2
  local datatype=${3:-"float"}
  
  fslmaths "$input"  "$output" -odt "$datatype"
  log_message "Standardized $input to $datatype datatype"
}

# Function to set sequence-specific parameters
set_sequence_params() {
    local file="$1"
    log_message "Checkign $file" 
    [ -e "$file" ] || return 0
    # Base parameters
    local params=()
    
    if [[ "$file" == *"FLAIR"* ]]; then
        # FLAIR-specific parameters
        params+=("FLAIR")
        params+=("$N4_ITERATIONS_FLAIR")
        params+=("$THRESHOLD_WM_SD_MULTIPLIER")
    elif [[ "$file" == *"DWI"* || "$file" == *"ADC"* ]]; then
        # DWI-specific parameters
        params+=("DWI")
        params+=("$N4_ITERATIONS")
        params+=("2.0") # Different threshold multiplier for DWI
    elif [[ "$file" == *"SWI"* ]]; then
        # SWI-specific parameters
        params+=("SWI")
        params+=("$N4_ITERATIONS")
        params+=("3.0") # Different threshold multiplier for SWI
    else
        # Default parameters
        params+=("T1")
        params+=("$N4_ITERATIONS")
        params+=("$THRESHOLD_WM_SD_MULTIPLIER")
    fi
    
    log_message "${params[@]}"
}




# Function to check if a command exists
check_command() {
  local cmd=$1
  local package=$2
  local install_hint=${3:-""}
  
  if command -v $cmd &> /dev/null; then
     log_formatted "SUCCESS" "✓ $package is installed ($(command -v $cmd))"
    return 0
  else
    log_formatted "ERROR" "✗ $package is not installed or not in PATH"
    if [ -n "$install_hint" ]; then
      log_formatted "INFO"  "$install_hint"
    fi
    return 1
  fi
}

# Function to check for ANTs tools
check_ants() {
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  
  log_formatted "INFO" "Checking ANTs tools..."
  
  # Check for ANTSPATH environment variable
  if [ -z "$ANTSPATH" ]; then
    log_formatted "WARNING" "ANTSPATH environment variable is not set. This may cause issues with some ANTs scripts."
  else
    log_formatted "SUCCESS" "ANTSPATH is set to $ANTSPATH"
  fi
  
  # Check each required ANTs tool
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
   log_formatted  "ERROR" "Some ANTs tools are missing. Install ANTs from:"
    log_formatted "INFO" "  • Using Homebrew: brew install ants"
    log_formatted "INFO" "  • Or from source: https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-MacOS"
    return 1
  else
    return 0
  fi
}

# Function to check for FSL tools
check_fsl() {
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  
  log_formatted "INFO" "Checking FSL tools..."
  
  # Check for FSLDIR environment variable
  if [ -z "$FSLDIR" ]; then
    log_formatted "WARNING" "FSLDIR environment variable is not set. This may cause issues with some FSL scripts."
  else
    log_formatted "SUCCESS" "FSLDIR is set to $FSLDIR"
  fi
  
  # Check each required FSL tool
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log_formatted "ERROR" "Some FSL tools are missing. Install FSL from:"
    log_formatted "INFO" "  • Download from: https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FslInstallation"
    log_formatted "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for FreeSurfer tools
check_freesurfer() {
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  
  log_formatted "INFO" "Checking FreeSurfer tools..."
  
  # Check for FREESURFER_HOME environment variable
  if [ -z "$FREESURFER_HOME" ]; then
    log_formatted "WARNING" "FREESURFER_HOME environment variable is not set. This may cause issues with some FreeSurfer tools."
  else
    log_formatted "SUCCESS" "FREESURFER_HOME is set to $FREESURFER_HOME"
  fi
  
  # Check each required FreeSurfer tool
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log_formatted "ERROR" "Some FreeSurfer tools are missing. Install FreeSurfer from:"
    log_formatted "INFO" "  • Download from: https://surfer.nmr.mgh.harvard.edu/fswiki/DownloadAndInstall"
    log_formatted "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for Convert3D (c3d)
check_c3d() {
  log_formatted "INFO" "Checking Convert3D..."
  
  if ! check_command "c3d" "Convert3D" "Download from: http://www.itksnap.org/pmwiki/pmwiki.php?n=Downloads.C3D"; then
    return 1
  else
    return 0
  fi
}

# Function to check for dcm2niix
check_dcm2niix() {
  log_formatted "INFO" "Checking dcm2niix..."
  
  if ! check_command "dcm2niix" "dcm2niix" "Install with: brew install dcm2niix"; then
    return 1
  else
    # Check version
    local version=$(dcm2niix -v 2>&1 | head -n 1)
    log_formatted "INFO" "  dcm2niix version: $version"
    return 0
  fi
}

# Check if running on macOS
check_os() {
  log_formatted "INFO" "Checking operating system..."
  
  if [[ "$(uname)" == "Darwin" ]]; then
    log_formatted "SUCCESS" "✓ Running on macOS"
    
    # Check if running on Apple Silicon
    if [[ "$(uname -m)" == "arm64" ]]; then
      log_formatted "SUCCESS" "✓ Running on Apple Silicon"
    else
      log_formatted "INFO" "Running on Intel-based Mac"
    fi
    return 0  
  else
    log_formatted "ERROR" "This script is designed for macOS"
    exit 1
  fi
}

error_count=0

log_formatted "INFO" "==== MRI Processing Dependency Checker ===="

check_os || error_count=$((error_count+1))
check_dcm2niix || error_count=$((error_count+1))
check_ants || error_count=$((error_count+1))
check_fsl || error_count=$((error_count+1))
check_freesurfer || error_count=$((error_count+1))
check_c3d || error_count=$((error_count+1))

log_formatted "INFO" "==== Checking optional but recommended tools ===="

# Check for ImageMagick (useful for image manipulation)
check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || log_formatted "WARNING" "ImageMagick is recommended for image conversions"

# Check for parallel (useful for parallel processing)
check_command "parallel" "GNU Parallel" "Install with: brew install parallel" || log_formatted "WARNING" "GNU Parallel is recommended for faster processing"

# Summary
log_formatted "INFO" "==== Dependency Check Summary ===="

if [ $error_count -eq 0 ]; then
  log_formatted "SUCCESS" "All required dependencies are installed!"
else
  log_formatted "ERROR" "$error_count required dependencies are missing."
  log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
  exit 1
fi

# Create directories
mkdir -p "$EXTRACT_DIR"
mkdir -p "$RESULTS_DIR"
mkdir -p "$LOG_DIR"
log_file="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"



# Check for required dependencies
if ! command -v fslstats &> /dev/null || ! command -v fslroi &> /dev/null; then
    log_message "Error: FSL is not installed or not in your PATH."
    exit 1
fi

NUM_SRC_DICOM_FILES=`find ${SRC_DIR} -name Image"*"  | wc -l`

log_message "There are ${NUM_SRC_DICOM_FILES} in ${SRC_DIR}. Going to extract to ${EXTRACT_DIR}"
export EXTRACT_DIR
export RESULTS_DIR
export LOG_DIR

# Function to deduplicate identical NIfTI files
deduplicate_identical_files() {
    local dir="$1"
    log_message "==== Deduplicating identical files in ${dir} ===="
    [ -e "$dir" ] || return 0
    
    # Create temporary directory for checksums
    mkdir -p "${dir}/tmp_checksums"
    
    # Calculate checksums and organize files
    find "${dir}" -name "*.nii.gz" -type f | while read file; do
        # Get base filename without suffix letters
        base=$(echo $(basename "$file" .nii.gz) | sed -E 's/([^_]+)([a-zA-Z]+)$/\1/g')
        
        # Calculate checksum
        checksum=$(md5 -q "$file")
        
        # Create symlink named by checksum for grouping
        ln -sf "$file" "${dir}/tmp_checksums/${checksum}_${base}.link"
    done
    
    # Process each unique checksum
    find "${dir}/tmp_checksums" -name "*.link" | sort | \
    awk -F'_' '{print $1}' | uniq | while read checksum; do
        # Find all files with this checksum
        files=($(find "${dir}/tmp_checksums" -name "${checksum}_*.link" | xargs -I{} readlink {}))
        
        if [ ${#files[@]} -gt 1 ]; then
            # Keep the first file (shortest name usually)
            kept="${files[0]}"
            log_message "Keeping representative file: $(basename "$kept")"
            
            # Create hardlinks to replace duplicates
            for ((i=1; i<${#files[@]}; i++)); do
                if [ -f "${files[$i]}" ]; then
                    log_message "Replacing duplicate: $(basename "${files[$i]}") → $(basename "$kept")"
                    rm "${files[$i]}"
                    ln "$kept" "${files[$i]}"
                fi
            done
        fi
    done
    
    # Clean up
    rm -rf "${dir}/tmp_checksums"
    log_message "Deduplication complete"
}


combine_multiaxis_images() {
    local sequence_type="$1"
    # Handle different naming conventions
    if [ "$sequence_type" = "T1" ]; then
        sequence_type="T1"
    fi
    local output_dir="$2"
    [ -e "$output_dir" ] || return 0
    log_message "output_dir: ${output_dir}"
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Find all matching sequence files
    sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" | egrep -v "^[0-9]" || true))
    cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" | egrep -v "^[0-9]" || true))
    ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "AX" | egrep -v "^[0-9]" || true))
    
    log_formatted "INFO" "Found ${#sag_files[@]} sagittal, ${#cor_files[@]} coronal, and ${#ax_files[@]} axial ${sequence_type} files"
    
    # Skip if no files found
    if [ ${#sag_files[@]} -eq 0 ] && [ ${#cor_files[@]} -eq 0 ] && [ ${#ax_files[@]} -eq 0 ]; then
        log_formatted "WARNING" "No ${sequence_type} files found to combine"
        return 1
    fi
    
    # Find highest resolution file in each orientation
    local best_sag=""
    local best_cor=""
    local best_ax=""
    local best_sag_res=0
    local best_cor_res=0
    local best_ax_res=0
    
    # Process sagittal files
    for file in "${sag_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
        
        if [ $res -gt $best_sag_res ]; then
            best_sag="$file"
            best_sag_res=$res
        fi
    done
    for file in "${ax_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
     
        if [ $res -gt $best_ax_res ]; then 
            best_ax="$file"
            best_ax_res=$res
        fi   
    done 
    for file in "${cor_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
     
        if [ $res -gt $best_cor_res ]; then 
            best_cor="$file"
            best_cor_res=$res
        fi   
    done 

    # Create output filename
    local output_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"
    
    # Register and combine the best files using ANTs
    log_formatted "INFO" "Combining best ${sequence_type} images to create high-resolution volume"
    
    if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
        # Use ANTs multivariate template creation to combine the three views
         antsMultivariateTemplateConstruction2.sh \
             -d 3 \
             -o "${output_dir}/${sequence_type}_template_" \
             -i ${TEMPLATE_ITERATIONS} \
             -g ${TEMPLATE_GRADIENT_STEP} \
             -j ${ANTS_THREADS} \
             -f ${TEMPLATE_SHRINK_FACTORS} \
             -s ${TEMPLATE_SMOOTHING_SIGMAS} \
             -q ${TEMPLATE_WEIGHTS} \
             -t ${TEMPLATE_TRANSFORM_MODEL} \
             -m ${TEMPLATE_SIMILARITY_METRIC} \
             -c 0 \
             "$best_sag" "$best_cor" "$best_ax"


        
        # Move the final template to our desired output
        mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$output_file"
        
        # Ensure INT16 output format
        standardize_datatype "$output_file" "$output_file" "$OUTPUT_DATATYPE"
        
        log_formatted "SUCCESS" "Created high-resolution ${sequence_type} volume: $output_file"
        return 0
    elif [ -n "$best_sag" ] || [ -n "$best_cor" ] || [ -n "$best_ax" ]; then
        # If we have at least one orientation, use that
        local best_file=""
        if [ -n "$best_sag" ]; then
            best_file="$best_sag"
        elif [ -n "$best_cor" ]; then
            best_file="$best_cor"
        else
            best_file="$best_ax"
        fi
        
        # Copy and ensure INT16 format
        cp "$best_file" "$output_file"
        standardize_datatype "$output_file" "$output_file" "$OUTPUT_DATATYPE"
        
        log_formatted "INFO" "Only one orientation available for ${sequence_type}, using: $best_file"
        return 0
    else
        log_formatted "ERROR" "No suitable ${sequence_type} files found"
        return 1
    fi
}



# Get sequence-specific N4 parameters
get_n4_parameters() {
    local file="$1"
    [ -e "$file" ] || return 0
    log_message "Get sequence-specific N4 parameters"
    params=($(set_sequence_params "$file")) 
    local iterations=$N4_ITERATIONS
    local convergence=$N4_CONVERGENCE
    local bspline=$N4_BSPLINE
    local shrink=$N4_SHRINK
    
    # Use FLAIR-specific parameters if it's a FLAIR sequence
    if [[ "$file" == *"FLAIR"* ]]; then
        export iterations="$N4_ITERATIONS_FLAIR"
        export convergence="$N4_CONVERGENCE_FLAIR"
        export bspline="$N4_BSPLINE_FLAIR"
        export shrink="$N4_SHRINK_FLAIR"
    fi
    
    echo "$iterations" "$convergence" "$bspline" "$shrink"
}


log_message "==== Extracting DICOM metadata for processing optimization ===="
mkdir -p "${RESULTS_DIR}/metadata"


extract_siemens_metadata() {
    local dicom_dir="$1"
    log_message "dicom_dir: ${dicom_dir}"
    [ -e "$dicom_dir" ] || return 0
    local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
    mkdir -p "${RESULTS_DIR}/metadata"
    
    log_message "Extracting Siemens MAGNETOM Sola metadata..."
    
    # Find the first DICOM file for metadata extraction
    local first_dicom=$(find "$dicom_dir" -name "Image*" -type f | head -1)
    
    if [ -z "$first_dicom" ]; then
        log_message "⚠️ No DICOM files found for metadata extraction."
        return 1
    fi
    
    # Create metadata directory if it doesn't exist
    mkdir -p "$(dirname \"$metadata_file\")"
    
    # Create default metadata file in case the Python script fails
    echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file"
    
    # Path to the external Python script
    local python_script="./extract_dicom_metadata.py"
    
    # Check if the Python script exists
    if [ ! -f "$python_script" ]; then
        log_message "⚠️ Python script not found at: $python_script"
        return 1
    fi
    
    # Make sure the script is executable
    chmod +x "$python_script"
    
    # Run the Python script with a timeout
    log_message "Extracting metadata with Python script..."
    
    # Try to use timeout command if available
    if command -v timeout &> /dev/null; then
        timeout 30s python3 "$python_script" "$first_dicom" "$metadata_file".tmp 2>"${RESULTS_DIR}/metadata/python_error.log"
        exit_code=$?
        
        if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
            log_message "⚠️ Python script timed out. Using default values."
        elif [ $exit_code -ne 0 ]; then
            log_message "⚠️ Python script failed with exit code $exit_code. See ${RESULTS_DIR}/metadata/python_error.log for details."
        else
            # Only use the output if the script succeeded
            mv "$metadata_file".tmp "$metadata_file"
            log_message "✅ Metadata extracted successfully using Python"
        fi
    else
        # If timeout command is not available, run with background process and kill if it takes too long
        python3 "$python_script" "$first_dicom" "$metadata_file".tmp 2>"${RESULTS_DIR}/metadata/python_error.log" &
        python_pid=$!
        
        # Wait for up to 30 seconds
        for i in {1..30}; do
            # Check if process is still running
            if ! kill -0 $python_pid 2>/dev/null; then
                # Process finished
                wait $python_pid
                exit_code=$?
                
                if [ $exit_code -eq 0 ]; then
                    # Only use the output if the script succeeded
                    mv "$metadata_file".tmp "$metadata_file"
                    log_message "✅ Metadata extracted successfully using Python"
                else
                    log_message "⚠️ Python script failed with exit code $exit_code. See ${RESULTS_DIR}/metadata/python_error.log for details."
                fi
                break
            fi
            
            # Wait 1 second
            sleep 2
            
            # If this is the last iteration, kill the process
            if [ $i -eq 30 ]; then
                kill $python_pid 2>/dev/null || true
                log_message "⚠️ Python script took too long and was terminated. Using default values."
            fi
        done
    fi
    
    log_message "Metadata extraction complete"
    return 0
}

#export TEMPLATE_DIR="${ANTSPATH}/data"
export TEMPLATE_DIR="${FSLDIR}/data/standard"

# Function to optimize ANTs parameters based on scanner metadata
optimize_ants_parameters() {
    local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
    mkdir -p "${RESULTS_DIR}/metadata"
    log_message "metadata_file ${metadata_file}"
    # Default optimized parameters
    log_message "template_dir: ${TEMPLATE_DIR}"

    # MAGNETOM Sola appropriate values 
    export EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
    export PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
    export REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"
    if [[ ! -f "${TEMPLATE_DIR}/${PROBABILITY_MASK}.prob" ]]; then
       fslmaths "${TEMPLATE_DIR}/${PROBABILITY_MASK}" -div 1 "${TEMPLATE_DIR}/${PROBABILITY_MASK}.prob"
       export PROBABILITY_MASK="${PROBABILITY_MASK}.prob"
   fi

    log_message "optimize_ants_parameters: start"
    
    # Check if metadata exists
    if [ ! -f "$metadata_file" ]; then
        log_message "⚠️ No metadata found. Using default ANTs parameters."
        return
    fi
    
    # Try using Python to parse the JSON if available
    if command -v python3 &> /dev/null; then
        # Create a simple Python script to extract key values
cat > "${RESULTS_DIR}/metadata/parse_json.py" << EOF
import json
import sys

try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)
    
    # Get the field strength
    field_strength = data.get('fieldStrength', 3)
    print(f"FIELD_STRENGTH={field_strength}")
    
    # Get the model name
    model = data.get('modelName', '')
    print(f"MODEL_NAME=""{model}""")
    
    # Check if it's a MAGNETOM Sola - convert Python boolean to shell boolean
    is_sola = 'MAGNETOM Sola' in model
    print(f"IS_SOLA={'1' if is_sola else '0'}")
    
except Exception as e:
    print(f"FIELD_STRENGTH=3")
    print(f"MODEL_NAME=Unknown")
    print(f"IS_SOLA=0")
EOF
        # Execute the script and capture its output
        eval "$(python3 "${RESULTS_DIR}/metadata/parse_json.py" "$metadata_file")"
    else
        # Default values if Python is not available
        FIELD_STRENGTH=3
        MODEL_NAME="Unknown"
        IS_SOLA=false
    fi
    
    # Optimize template selection based on field strength
    if (( $(echo "$FIELD_STRENGTH > 2.5" | bc -l) )); then
        log_message "Optimizing for 3T scanner field strength $FIELD_STRENGTH T"
        EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
        # Standard 3T parameters
        N4_CONVERGENCE="0.000001"
        REG_METRIC_CROSS_MODALITY="MI"
    else
        log_message "Optimizing for 1.5T scanner field strength: $FIELD_STRENGTH T"
        
        # Check if a specific 1.5T template exists
        if [ -f "$TEMPLATE_DIR/MNI152_T1_1mm.nii.gz" ]; then
            EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
            log_message "Using dedicated 1.5T template"
        else
            # Use standard template with optimized 1.5T parameters
            EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
            log_message "Using standard MNI152_T1_1mm.nii.gz template with 1.5T-optimized parameters"
            
            # Adjust parameters specifically for 1.5T data using standard template
            # These adjustments compensate for different contrast characteristics
            N4_CONVERGENCE="0.0000005"  # More stringent convergence for typically noisier 1.5T data
            N4_BSPLINE=200              # Increased B-spline resolution for potentially more heterogeneous bias fields
            REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.3]"  # Adjusted mutual information parameters
            ATROPOS_MRF="[0.15,1x1x1]"  # Stronger regularization for segmentation
        fi
    fi

    
    # Check for Siemens MAGNETOM Sola specific optimizations
    if [ "$IS_SOLA" = true ]; then
        log_message "Applying optimizations specific to Siemens MAGNETOM Sola"
        
        # Adjust parameters based on MAGNETOM Sola characteristics
        # These values are optimized for Siemens MAGNETOM Sola
        REG_TRANSFORM_TYPE=3  # Use more aggressive transformation model
        REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"  # More robust mutual information
        N4_BSPLINE=200  # Optimized for MAGNETOM Sola field inhomogeneity profile
        REG_TRANSFORM_TYPE=3  # More aggressive transformation model

    fi
    
    log_message "✅ ANTs parameters optimized based on scanner metadata"
}

# Call these functions
extract_siemens_metadata "$SRC_DIR"
optimize_ants_parameters


# Step 1: Convert DICOM to NIfTI using dcm2niix with Siemens optimizations
log_message "==== Step 1: DICOM to NIfTI Conversion ===="
log_message "convert DICOM files from ${SRC_DIR} to ${EXTRACT_DIR} in NiFTi .nii.gz format using dcm2niix"
dcm2niix -b y -z y -f "%p_%s" -o "$EXTRACT_DIR" -m y -p y -s y "${SRC_DIR}"

# Call deduplication after DICOM conversion
deduplicate_identical_files "$EXTRACT_DIR"

# Check conversion success
if [ $(find "$EXTRACT_DIR" -name "*.nii.gz" | wc -l) -eq 0 ]; then
    log_message "⚠️ No NIfTI files created. DICOM conversion may have failed."
    exit 1
fi

sleep 5

find "${EXTRACT_DIR}" -name "*.nii.gz" -print0 | while IFS= read -r -d '' file; do
  log_message "Checking ${file}..:"
  fslinfo "${file}" >> ${EXTRACT_DIR}/tmp_fslinfo.log
  fslstats "${file}" -R -M -S >> "${EXTRACT_DIR}/tmp_fslinfo.log"
done

log_message "==== Combining multi-axis images for high-resolution volumes ===="
export COMBINED_DIR="${RESULTS_DIR}/combined"
mkdir -p "${COMBINED_DIR}"
combine_multiaxis_images "FLAIR" "${RESULTS_DIR}/combined"
log_message "Combined FLAIR"
combine_multiaxis_images "T1" "${RESULTS_DIR}/combined"
log_message "Combined T1"
combine_multiaxis_images "SWI" "${RESULTS_DIR}/combined"
log_message "Combined DWI"
combine_multiaxis_images "DWI" "${RESULTS_DIR}/combined"
log_message "Combined SWI"


log_message "Opening freeview with all the files in case you want to check"
nohup freeview ${RESULTS_DIR}/combined/*.nii.gz &

# Input directory
TRIMMED_OUTPUT_SUFFIX="${EXTRACT_DIR}_trimmed"

process_all_nifti_files_in_dir(){
    file="$1"
    # Skip if no files are found
    [ -e "$file" ] || continue

    log_message "Processing: $file"

    # Get the base filename (without path)
    base=$(basename "${file}" .nii.gz)

    # Get smallest bounding box of nonzero voxels
    bbox=($(fslstats "${file}" -w))

    xmin=${bbox[0]}
    xsize=${bbox[1]}
    ymin=${bbox[2]}
    ysize=${bbox[3]}
    zmin=${bbox[4]}
    zsize=${bbox[5]}

    log_message "Cropping region: X=\($xmin, $xsize\) Y=\($ymin, $ysize\) Z=\($zmin, $zsize\)"
    dir=$(dirname "${file}")

    # Output filename
    output_file="${dir}/${base}${TRIMMED_OUTPUT_SUFFIX}.nii.gz"

    # Add padding to avoid cutting too close
    xpad=$PADDING_X
    ypad=$PADDING_Y
    zpad=$PADDING_Z

    # Get image dimensions
    xdim=$(fslval "$file" dim1)
    ydim=$(fslval "$file" dim2)
    zdim=$(fslval "$file" dim3)
    
    # Calculate safe starting points with padding
    safe_xmin=$((xmin > PADDING_X ? xmin - PADDING_X : 0))
    safe_ymin=$((ymin > PADDING_Y ? ymin - PADDING_Y : 0))
    safe_zmin=$((zmin > PADDING_Z ? zmin - PADDING_Z : 0))
    
    # Calculate safe sizes ensuring we don't exceed dimensions
    safe_xsize=$((xsize + 2*PADDING_X))
    if [ $((safe_xmin + safe_xsize)) -gt "$xdim" ]; then
        safe_xsize=$((xdim - safe_xmin))
    fi
    
    safe_ysize=$((ysize + 2*PADDING_Y))
    if [ $((safe_ymin + safe_ysize)) -gt "$ydim" ]; then
        safe_ysize=$((ydim - safe_ymin))
    fi
    
    safe_zsize=$((zsize + 2*PADDING_Z))
    if [ $((safe_zmin + safe_zsize)) -gt "$zdim" ]; then
        safe_zsize=$((zdim - safe_zmin))
    fi
    
    # Apply the cropping with safe boundaries
    fslroi "$file" "$output_file" $safe_xmin $safe_xsize $safe_ymin $safe_ysize $safe_zmin $safe_zsize

    log_message "Saved trimmed file: ${output_file}"
    fslinfo "${output_file}"
}

export -f process_all_nifti_files_in_dir  # Ensure function is available in subshells

find "${RESULTS_DIR}/combined" -name "*.nii.gz" -print0 | parallel -0 -j 11 process_all_nifti_files_in_dir {}

echo "✅ All files processed to trim missing slices."

# Step 2: N4 Bias Field Correction with ANTs
log_message "==== Step 2: ANTs N4 Bias Field Correction ===="
mkdir -p "${RESULTS_DIR}/bias_corrected"

# N4BiasFieldCorrection parameters
###-d 3 - Dimensionality parameter
###
###Specifies that we're working with 3D image data
###Options: 2, 3, or 4 (for 2D, 3D, or 4D images)
###
###-b [200] - B-spline grid resolution control
###
###Controls the resolution of the B-spline mesh used to model the bias field
###Lower values (e.g., [100]) = smoother bias field with less detail
###Higher values (e.g., [300]) = more detailed bias field that captures local variations
###Can specify different resolutions per dimension: [200x200x200]
###
###-s 4 - Shrink factor
###
###Downsamples the input image to speed up processing
###Higher values = faster but potentially less accurate
###Typical values: 2-4
###For high-resolution images, 4 is good; for lower resolution, use 2
###
###Other important parameters that could be configurable:
###-w - Weight image
###
###Optional binary mask defining the region where bias correction is applied
###Different from the exclusion mask (-x)
###
###-n - Number of histogram bins used for N4
###
###Default is usually 200
###Controls precision of intensity histogram
###Lower = faster but less precise; higher = more precise but slower
###
###--weight-spline-order - B-spline interpolation order
###
###Default is 3
###Controls smoothness of the B-spline interpolation
###Range: 0-5 (higher = smoother but more computation)

mkdir -p "${RESULTS_DIR}/bias_corrected"


process_n4_correction() {
    local file="$1"
    local basename=$(basename "$file" .nii.gz)
    local dir=$(dirname "${file}")
    local output_dir = "${dir}/bias_corrected"
    mkdir -p "${output_dir}"
    mkdir -p "${RESULTS_DIR}/bias_corrected"
    local output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"

    log_message "Performing bias correction on: $basename - ${dir} ${output_dir} ${output_file}"

    # Create an initial brain mask for better bias correction
    antsBrainExtraction.sh -d 3 -a "$file" -o "${RESULTS_DIR}/bias_corrected/${basename}_" \
        -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
        -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

    log_message "${RESULTS_DIR}/bias_corrected/${basename}_"
    # Get sequence-specific N4 parameters
    n4_params=($(get_n4_parameters "$file"))

    # Run N4 bias correction
    #N4BiasFieldCorrection -d 3 \
    #j    -i "$file" \
    #    -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
    #    -o "$output_file" \
    #    -b [${n4_params[2]}] \
    #    -s ${n4_params[3]} \
    #    -c "[${n4_params[0]},${n4_params[1]}]"

    # Use optimized parameters from metadata if available
    if [[ -n "$N4_BSPLINE" ]]; then
        N4BiasFieldCorrection -d 3 \
            -i "$file" \
            -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
            -o "$output_file" \
            -b [$N4_BSPLINE] \
            -s ${n4_params[3]} \
            -c [${n4_params[0]},${n4_params[1]}]
    else
        N4BiasFieldCorrection -d 3 \
            -i "$file" \
            -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
            -o "$output_file" \
            -b [${n4_params[2]}] \
            -s ${n4_params[3]} \
            -c [${n4_params[0]},${n4_params[1]}]
    fi

    log_message "Saved bias-corrected image to: $output_file"
}

export -f process_n4_correction get_n4_parameters log_message  # Export functions

find "$COMBINED_DIR" -name "*.nii.gz" -maxdepth 1 -type f -print0 | \
parallel -0 -j 11 process_n4_correction {}

log_message "✅ Bias field correction complete."

# ==== NEW STEP 2.5: Flexible Image Dimension Standardization ====
log_message "==== Step 2.5: Flexible Image Dimension Standardization ===="
mkdir -p "${RESULTS_DIR}/standardized"

# Define sequence-specific target dimensions
# Format: x,y,z dimensions or "isotropic:N" for isotropic voxels of size N mm
declare -A SEQUENCE_DIMENSIONS=(
  ["T1"]="isotropic:1"  # 1mm isotropic resolution
  ["FLAIR"]="512,512,keep"      # Standardize xy, preserve z
  ["SWI"]="256,256,keep"        # Lower resolution for SWI
  ["DWI"]="keep,keep,keep"      # Preserve original dimensions for diffusion
  ["DEFAULT"]="512,512,keep"    # Default handling
)

standardize_dimensions() {
    local input_file="$1"
    local basename=$(basename "$input_file" .nii.gz)
    local output_file="${RESULTS_DIR}/standardized/${basename}_std.nii.gz"
   
    log_message "Standardizing dimensions for: $basename"
    
    # Get current image dimensions and spacings
    local x_dim=$(fslval "$input_file" dim1)
    local y_dim=$(fslval "$input_file" dim2)
    local z_dim=$(fslval "$input_file" dim3)
    local x_pixdim=$(fslval "$input_file" pixdim1)
    local y_pixdim=$(fslval "$input_file" pixdim2)
    local z_pixdim=$(fslval "$input_file" pixdim3)
    
    # Determine sequence type from filename
    local sequence_type="DEFAULT"
    if [[ "$basename" == *"T1"* ]]; then
        sequence_type="T1"
    elif [[ "$basename" == *"FLAIR"* ]]; then
        sequence_type="FLAIR"
    elif [[ "$basename" == *"SWI"* ]]; then
        sequence_type="SWI"
    elif [[ "$basename" == *"DWI"* ]]; then
        sequence_type="DWI"
    fi
    
    log_message "Identified sequence type: $sequence_type"
    
    # Get target dimensions for this sequence type
    local target_dims=${SEQUENCE_DIMENSIONS[$sequence_type]}
    local target_x=""
    local target_y=""
    local target_z=""
    local isotropic_size=""
    
    # Parse the target dimensions
    if [[ "$target_dims" == isotropic:* ]]; then
        # Handle isotropic case
        isotropic_size=$(echo "$target_dims" | cut -d':' -f2)
        log_message "Using isotropic voxel size of ${isotropic_size}mm"
        
        # Calculate dimensions based on physical size
        local physical_x=$(echo "$x_dim * $x_pixdim" | bc -l)
        local physical_y=$(echo "$y_dim * $y_pixdim" | bc -l)
        local physical_z=$(echo "$z_dim * $z_pixdim" | bc -l)
        
        target_x=$(echo "($physical_x / $isotropic_size + 0.5) / 1" | bc)
        target_y=$(echo "($physical_y / $isotropic_size + 0.5) / 1" | bc)
        target_z=$(echo "($physical_z / $isotropic_size + 0.5) / 1" | bc)
        
        # Ensure we have even dimensions (better for some algorithms)
        target_x=$(echo "($target_x + 1) / 2 * 2" | bc)
        target_y=$(echo "($target_y + 1) / 2 * 2" | bc)
        target_z=$(echo "($target_z + 1) / 2 * 2" | bc)
        
        # Set voxel dimensions
        x_pixdim=$isotropic_size
        y_pixdim=$isotropic_size
        z_pixdim=$isotropic_size
    else
        # Handle specified dimensions
        target_x=$(echo "$target_dims" | cut -d',' -f1)
        target_y=$(echo "$target_dims" | cut -d',' -f2)
        target_z=$(echo "$target_dims" | cut -d',' -f3)
        
        # Handle "keep" keyword
        if [ "$target_x" = "keep" ]; then target_x=$x_dim; fi
        if [ "$target_y" = "keep" ]; then target_y=$y_dim; fi
        if [ "$target_z" = "keep" ]; then target_z=$z_dim; fi
        
        # Recalculate voxel sizes to maintain physical dimensions
        if [ "$target_x" != "$x_dim" ]; then
            local physical_x=$(echo "$x_dim * $x_pixdim" | bc -l)
            x_pixdim=$(echo "$physical_x / $target_x" | bc -l)
        fi
        if [ "$target_y" != "$y_dim" ]; then
            local physical_y=$(echo "$y_dim * $y_pixdim" | bc -l)
            y_pixdim=$(echo "$physical_y / $target_y" | bc -l)
        fi
        if [ "$target_z" != "$z_dim" ]; then
            local physical_z=$(echo "$z_dim * $z_pixdim" | bc -l)
            z_pixdim=$(echo "$physical_z / $target_z" | bc -l)
        fi
    fi
    
    log_message "Original dimensions: ${x_dim}x${y_dim}x${z_dim} with voxel size ${x_pixdim}x${y_pixdim}x${z_pixdim}mm"
    log_message "Target dimensions: ${target_x}x${target_y}x${target_z} with voxel size ${x_pixdim}x${y_pixdim}x${z_pixdim}mm"
    # Check if resampling is truly necessary
# Skip if dimensions are very close to target (within 5% difference)
if [ $(echo "($x_dim - $target_x)^2 + ($y_dim - $target_y)^2 + ($z_dim - $target_z)^2 < (0.05 * ($x_dim + $y_dim + $z_dim))^2" | bc -l) -eq 1 ]; then
    log_message "Original dimensions \(${x_dim}x${y_dim}x${z_dim}\) already close to target - skipping resampling"
    cp "$input_file" "$output_file"
    
    # Ensure the header still has the correct spacing values
    c3d "$output_file" -spacing "$x_pixdim"x"$y_pixdim"x"$z_pixdim"mm -o "$output_file"
else
    # Use ANTs ResampleImage for high-quality resampling
    log_message "Resampling from ${x_dim}x${y_dim}x${z_dim} to ${target_x}x${target_y}x${target_z}"
    ResampleImage 3 \
        "$input_file" \
        "$output_file" \
        ${target_x}x${target_y}x${target_z} \
        0 \
        3 # 3 = use cubic B-spline interpolation
fi
    log_message "Saved standardized image to: $output_file"
    
    # Update NIFTI header with correct physical dimensions
    c3d "$output_file" -spacing "$x_pixdim"x"$y_pixdim"x"$z_pixdim"mm -o "$output_file"
    
    # Calculate and report the size change
    local orig_size=$(du -h "$input_file" | cut -f1)
    local new_size=$(du -h "$output_file" | cut -f1)
    log_message "Size change: $orig_size → $new_size"
}

export -f standardize_dimensions log_message

# Process all bias-corrected images
find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" -print0 | \
parallel -0 -j 11 standardize_dimensions {}

log_message "✅ Dimension standardization complete."


# Step 3: ANTs-based motion correction and registration
log_message "==== Step 3: ANTs Motion Correction and Registration ===="
mkdir -p "${RESULTS_DIR}/registered"

# First identify a T1w reference image if available
reference_image=""
#t1_files=($(find "$RESULTS_DIR/bias_corrected" -name "*T1*n4.nii.gz" -o -name "*T1*n4.nii.gz"))
t1_files=($(find "$RESULTS_DIR/standardized" -name "*T1*n4_std.nii.gz"))

if [ ${#t1_files[@]} -gt 0 ]; then
  best_t1=""
  best_res=0
  
  for t1 in "${t1_files[@]}"; do
      xdim=$(fslval "$t1" dim1)
      ydim=$(fslval "$t1" dim2)
      zdim=$(fslval "$t1" dim3)
      res=$((xdim * ydim * zdim))
  
      if [ $res -gt $best_res ]; then
          best_t1="$t1"
          best_res=$res
      fi
  done
  
  reference_image="$best_t1"
  log_message "Using ${reference_image} as reference for registration"
else
   # If no T1w found, use the first file
   reference_image=$(find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" | head -1)
   log_message "No T1w reference found. Using ${reference_image} as reference"
fi

# Process all images - register to the reference
#find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" -print0 | while IFS= read -r -d '' file; do
find "$RESULTS_DIR/standardized" -name "*n4_std.nii.gz" -print0 | while IFS= read -r -d '' file; do

    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/registered/${basename}_"
    
    log_message "Registering: $basename to reference using ANTs"
    
    # For FLAIR or T2 to T1 registration, use mutual information metric
    # This handles cross-modality registration better
    if [[ "$file" == *"FLAIR"*  ]]; then
        # Use optimized cross-modality registration metric if available
        if [[ -n "$REG_METRIC_CROSS_MODALITY" ]]; then
            antsRegistrationSyN.sh -d 3 \
                -f "$reference_image" \
                -m "$file" \
                -o "$output_prefix" \
                -t $REG_TRANSFORM_TYPE \
                -n 4 \
                -p f \
                -j 1 \
                -x "$REG_METRIC_CROSS_MODALITY"
        else
            antsRegistrationSyN.sh -d 3 \
                -f "$reference_image" \
                -m "$file" \
                -o "$output_prefix" \
                -t r \
                -n 4 \
                -p f \
                -j 1
        fi
    else
        # For same modality, use cross-correlation which works better
        antsRegistrationSyN.sh -d 3 \
            -f "$reference_image" \
            -m "$file" \
            -o "$output_prefix" \
            -t r \
            -n 4 \
            -p f \
            -j 1
    fi
    
    log_message "Saved registered image to: ${output_prefix}Warped.nii.gz"
    
    # Create a symlink with a more intuitive name
    ln -sf "${output_prefix}Warped.nii.gz" "${RESULTS_DIR}/registered/${basename}_reg.nii.gz"
done

log_message "✅ ANTs registration complete."

# Step 4: ANTs-based quality assessment 
log_message "==== Step 4: ANTs-based Quality Assessment ===="
mkdir -p "${RESULTS_DIR}/quality_checks"

# Process each registered file
find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/quality_checks/${basename}_"
    
    log_message "Performing quality checks on: $basename"
    
    # Extract brain with ANTs for more accurate SNR calculation
    antsBrainExtraction.sh -d 3 \
        -a "$file" \
        -o "$output_prefix" \
        -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
        -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

    
    # Calculate SNR using ANTs tools
    # Get mean signal in brain
    signal=$(ImageMath 3 ${output_prefix}signal.nii.gz m "$file" "${output_prefix}BrainExtractionMask.nii.gz")
    signal_mean=$(ImageStats "$file" "${output_prefix}BrainExtractionMask.nii.gz" 2 | awk '{print $2}')
    
    # Create background mask (inverted brain mask with erosion)
    ImageMath 3 "${output_prefix}background_mask.nii.gz" MC "${output_prefix}BrainExtractionMask.nii.gz" 0
    ImageMath 3 "${output_prefix}background_mask_eroded.nii.gz" ME "${output_prefix}background_mask.nii.gz" 3
    
    # Get noise standard deviation in background
    noise_sd=$(ImageStats "$file" "${output_prefix}background_mask_eroded.nii.gz" 5 | awk '{print $2}')
    
    # Calculate SNR
    snr=$(echo "$signal_mean / $noise_sd" | bc -l)
    
    # Save to log
    echo "$basename,$snr" >> "${RESULTS_DIR}/quality_checks/snr_values.csv"
    log_message "SNR for $basename: $snr"
    
    # For qualitative assessment, generate a check image
    CreateTiledMosaic -i "$file" -r "$reference_image" -o "${output_prefix}check.png" -a 0.3 -t -1x-1 -p mask -m "${output_prefix}BrainExtractionMask.nii.gz"
done

log_message "✅ Quality assessment complete."

# Step 5: ANTs-based intensity normalization for FLAIR
log_message "==== Step 5: ANTs-based Intensity Normalization ===="
mkdir -p "${RESULTS_DIR}/intensity_normalized"

# Find all FLAIR images after registration
flair_files=($(find "$RESULTS_DIR/registered" -name "*FLAIR*reg.nii.gz"))

if [ ${#flair_files[@]} -gt 0 ]; then
    log_message "Found ${#flair_files[@]} FLAIR images to normalize"
    
    for file in "${flair_files[@]}"; do
        basename=$(basename "$file" .nii.gz)
        output_file="${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz"
        
        log_message "Normalizing: $basename"
        
        # Advanced intensity normalization using N4 and histogram matching
        ImageMath 3 "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz" RescaleImage "$file" 0 1000
        
        # Use N4 again for better results on the registered data
        N4BiasFieldCorrection -d 3 \
            -i "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz" \
            -o "$output_file" \
            -b "[200]" \
            -s 2 \
            -c "[50x50x50,0.000001]" \
            -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" 
        
        # Clean up
        rm -f "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz"
        
        log_message "Saved intensity-normalized image to: $output_file"
    done
    
    log_message "✅ Intensity normalization complete for FLAIR images."
else
    log_message "⚠️ No FLAIR images found for intensity normalization."
fi

# Update reference to use standardized files for subsequent steps
# Modify this line at the registration step
# Find all T1w reference images if available
reference_image=""
t1_files=($(find "$RESULTS_DIR/standardized" -name "*T1*n4_std.nii.gz"))

# Step 6: Hyperintensity detection for FLAIR (using ANTs tools)
if [ ${#flair_files[@]} -gt 0 ]; then
    log_message "==== Step 6: Hyperintensity Detection on FLAIR ===="
    mkdir -p "${RESULTS_DIR}/hyperintensities"
    
    for file in "${flair_files[@]}"; do
        basename=$(basename "$file" .nii.gz)
        output_prefix="${RESULTS_DIR}/hyperintensities/${basename}_"
        
        # Use normalized version if available
        if [ -f "${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz" ]; then
            input_file="${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz"
        else
            input_file="$file"
        fi
        
        log_message "Detecting hyperintensities on: $basename"
        
        # First get brain mask
        cp "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" "${output_prefix}brain_mask.nii.gz"
        
        # Now find T1 to use for segmentation
        t1_reg=""
        for t1_candidate in "${RESULTS_DIR}/registered/"*T1*reg.nii.gz; do
            if [ -f "$t1_candidate" ]; then
                t1_reg="$t1_candidate"
                break
            fi
        done
        
        # If T1 is available, use it for tissue segmentation
        if [ -n "$t1_reg" ]; then
            log_message "Using $t1_reg for tissue segmentation"
            
            # Run ANTs segmentation on T1
             Atropos -d 3 \
                 -a "$input_file" \
                 -x "${output_prefix}brain_mask.nii.gz" \
                 -o [${output_prefix}atropos_segmentation.nii.gz,${output_prefix}atropos_prob%d.nii.gz] \
                 -c [${ATROPOS_CONVERGENCE}] \
                 -m "${ATROPOS_MRF}" \
                 -i ${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}] \
                 -k Gaussian
            ln -sf "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}segmentation.nii.gz"

            
                        
            # Extract WM (label 3) and GM (label 2)
            ThresholdImage 3 "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            ThresholdImage 3 "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2


            log_message "T1-based tissue segmentation complete."
        else
            # Fallback to intensity-based segmentation on FLAIR
            log_message "No T1 found. Using intensity-based segmentation on FLAIR."
            
            # Use Otsu thresholding to create rough tissue classes
            ThresholdImage 3 "$input_file" "${output_prefix}otsu.nii.gz" Otsu 3 "${output_prefix}brain_mask.nii.gz"
            
            # Extract approximate WM (highest intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            
            # Extract approximate GM (middle intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2
        fi
        
  # Method 1: Morphological approach for hyperintensity detection
  log_message "Using morphological approach for hyperintensity detection..."
  
  # First get WM statistics for initial threshold
  wm_mean=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 2 | awk '{print $2}')
  wm_sd=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 5 | awk '{print $2}')
  
  # Get sequence-specific parameters
  params=($(set_sequence_params "$file"))
  sequence_type="${params[0]}"
  iterations="${params[1]}"
  threshold_multiplier="${params[2]}"
  
  # Define threshold based on sequence type
  threshold=$(echo "$wm_mean + $threshold_multiplier * $wm_sd" | bc -l)
  log_message "$sequence_type WM mean: $wm_mean, WM SD: $wm_sd, Threshold multiplier: $threshold_multiplier, Final threshold: $threshold"
  
  # Initial threshold using intensity
  ThresholdImage 3 "$input_file" "${output_prefix}init_threshold.nii.gz" $threshold 99999 "${output_prefix}brain_mask.nii.gz"
  
  # Create tissue-specific masks to avoid false positives
  # Exclude CSF and non-brain areas
  if [ -f "${output_prefix}wm_mask.nii.gz" ] && [ -f "${output_prefix}gm_mask.nii.gz" ]; then
      # Combine WM and GM masks
      ImageMath 3 "${output_prefix}brain_tissue.nii.gz" + "${output_prefix}wm_mask.nii.gz" "${output_prefix}gm_mask.nii.gz"
      
      # Apply tissue mask to the initial threshold
      ImageMath 3 "${output_prefix}tissue_threshold.nii.gz" m "${output_prefix}init_threshold.nii.gz" "${output_prefix}brain_tissue.nii.gz"
  else
      # Just use the brain mask if tissue segmentation isn't available
      cp "${output_prefix}init_threshold.nii.gz" "${output_prefix}tissue_threshold.nii.gz"
  fi
  
  # Morphological operations to clean up the segmentation
  # Erosion to remove small connections and noise
  ImageMath 3 "${output_prefix}eroded.nii.gz" ME "${output_prefix}tissue_threshold.nii.gz" 1
  
  # Dilation to recover original size while maintaining disconnected regions
  ImageMath 3 "${output_prefix}eroded_dilated.nii.gz" MD "${output_prefix}eroded.nii.gz" 1
  
  # Connected component analysis to remove small islands
  ImageMath 3 "${output_prefix}hyperintensities_clean.nii.gz" GetLargestComponents "${output_prefix}eroded_dilated.nii.gz" $MIN_HYPERINTENSITY_SIZE
  
  # Calculate final hyperintensity volume and other metrics
  hyper_voxels=$(ImageStats "${output_prefix}hyperintensities_clean.nii.gz" 0 | grep "Voxels" | cut -d: -f2)
  log_message "Detected $hyper_voxels hyperintensity voxels"
  
  # Measure intensity distribution within hyperintensities
  mean_intensity=$(ImageStats "$input_file" "${output_prefix}hyperintensities_clean.nii.gz" 2 | awk '{print $2}')
  peak_intensity=$(ImageStats "$input_file" "${output_prefix}hyperintensities_clean.nii.gz" 9 | awk '{print $2}')
  log_message "Hyperintensity mean intensity: $mean_intensity, peak intensity: $peak_intensity"
  
  log_message "✅ Morphological hyperintensity detection complete."
  
          
 # Create overlay files for visualization in freeview
 # These .mgz files are appropriate for freeview overlay
 # Scale probability map to 0-100 range for better visualization
 ImageMath 3 "${output_prefix}hyperintensities_prob_scaled.nii.gz" m "${output_prefix}hyperintensities_prob.nii.gz" 100
          
 # Convert all results to .mgz format for FSL/Freeview
 # This requires mri_convert from FreeSurfer
 mri_convert "${output_prefix}hyperintensities_clean.nii.gz" "${output_prefix}hyperintensities_clean.mgz"
 mri_convert "${output_prefix}hyperintensities_atropos.nii.gz" "${output_prefix}hyperintensities_atropos.mgz"
 mri_convert "${output_prefix}hyperintensities_prob_scaled.nii.gz" "${output_prefix}hyperintensities_prob.mgz"
          
 # Also convert the normalized FLAIR for viewing
 mri_convert "$input_file" "${output_prefix}flair_norm.mgz"
          
 log_message "Converted results to .mgz format for Freeview."
          
 # Create a convenience script for opening in freeview with proper overlays
 cat > "${output_prefix}view_in_freeview.sh" << EOL
  
# Open results in Freeview with proper overlays
freeview -v "${output_prefix}flair_norm.mgz" \\
         -v "${output_prefix}hyperintensities_clean.mgz:colormap=heat:opacity=0.5" \\
         -v "${output_prefix}hyperintensities_prob.mgz:colormap=jet:opacity=0.7"
EOL
        chmod +x "${output_prefix}view_in_freeview.sh"
    done
fi

# Final step: Create cropped versions with padding using ANTs (better than FSL's fslroi)
log_message "==== Creating Cropped Versions with Padding ===="
mkdir -p "${RESULTS_DIR}/cropped"

find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"
    
    log_message "Creating cropped version with padding for: $basename"
    
    # Use ExtractRegionFromImageByMask from ANTs
    # This provides better cropping with customizable padding
    c3d "$file" -as S "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" -push S -thresh $C3D_CROP_THRESHOLD 1 1 0 -trim ${C3D_PADDING_MM}mm -o "$output_file"
    
    log_message "Saved cropped file: $output_file"
done

log_message "✅ All processing steps complete!"

# Create a summary report
log_message "==== Creating Summary Report ===="

# Find all generated hyperintensity files
hyperintensity_files=($(find "${RESULTS_DIR}/hyperintensities" -name "*hyperintensities_clean.nii.gz"))

# Calculate volume statistics
echo "Hyperintensity Volumetric Results:" > "${RESULTS_DIR}/hyperintensity_report.txt"
echo "-----------------------------------" >> "${RESULTS_DIR}/hyperintensity_report.txt"
echo "Filename, Volume mm³, % of Brain Volume" >> "${RESULTS_DIR}/hyperintensity_report.txt"

for file in "${hyperintensity_files[@]}"; do
    basename=$(basename "$file" _hyperintensities_clean.nii.gz)
    
    # Get voxel volume in mm³
    voxel_volume=$(c3d "$file" -info-full | grep "Voxel spacing" | awk '{print $4 * $5 * $6}')
    
    # Get number of hyperintensity voxels
    num_voxels=$(c3d "$file" -thresh 0.5 inf 1 0 -voxel-sum | awk '{print $3}')
    
    # Calculate total volume
    volume=$(echo "$voxel_volume * $num_voxels" | bc -l)
    
    # Get brain mask and calculate brain volume
    brain_mask="${RESULTS_DIR}/hyperintensities/${basename}_reg_brain_mask.nii.gz"
    brain_voxels=$(c3d "$brain_mask" -thresh 0.5 inf 1 0 -voxel-sum | awk '{print $3}')
    brain_volume=$(echo "$voxel_volume * $brain_voxels" | bc -l)
    
    # Calculate percentage
    percentage=$(echo "scale=4; ($volume / $brain_volume) * 100" | bc -l)
    
    echo "$basename, $volume, $percentage%" >> "${RESULTS_DIR}/hyperintensity_report.txt"
done

log_message "Summary report created at ${RESULTS_DIR}/hyperintensity_report.txt"

# Create a comprehensive freeview script that includes all relevant overlays
cat > "${RESULTS_DIR}/view_all_results.sh" << EOL

# Open all results in Freeview with proper overlays

# Find FLAIR files
flair_files=(\$(find "${RESULTS_DIR}/intensity_normalized" -name "*FLAIR*norm.nii.gz"))

if [ \${#flair_files[@]} -gt 0 ]; then
    # Use the first FLAIR as base
    base_file="\${flair_files[0]}"
    
    # Build command
    cmd="freeview -v \$base_file"
    
    # Add hyperintensity overlays
    for overlay in "${RESULTS_DIR}/hyperintensities/"*hyperintensities_clean.nii.gz; do
        if [ -f "\$overlay" ]; then
            cmd="\$cmd -v \$overlay:colormap=heat:opacity=0.5"
        fi
    done
    
    # Add probability map overlays
    for overlay in "${RESULTS_DIR}/hyperintensities/"*hyperintensities_prob.nii.gz; do
        if [ -f "\$overlay" ]; then
            cmd="\$cmd -v \$overlay:colormap=jet:opacity=0.3:visible=0"
        fi
    done
    
    # Execute command
    log_message "Running: \$cmd"
    eval \$cmd
else
    log_message "No FLAIR files found. Cannot open freeview."
fi
EOL
chmod +x "${RESULTS_DIR}/view_all_results.sh"

log_message "Created comprehensive freeview script at ${RESULTS_DIR}/view_all_results.sh"
log_message "==== Processing Pipeline Complete! ===="

# Done!