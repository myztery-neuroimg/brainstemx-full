#!/usr/bin/env bash
#
# fix_registration_issues.sh - Tool to fix common registration issues
#
# This script automatically detects and fixes common registration issues:
# 1. Datatype mismatches between images (UINT8 vs INT16 vs FLOAT32)
# 2. Coordinate space mismatches
# 3. Incorrect mask handling (binary vs intensity masks)
#

# Get the registration module path for sourcing functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
REG_MODULE="${PARENT_DIR}/modules/registration.sh"
ENV_MODULE="${PARENT_DIR}/modules/environment.sh"
ENHANCED_REG_MODULE="${PARENT_DIR}/modules/enhanced_registration_validation.sh"

# Source basic functions if environment module is available
if [ -f "$ENV_MODULE" ]; then
    source "$ENV_MODULE"
else
    # Define basic logging functions if not available
    log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
    log_formatted() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2"; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }
fi

# Banner display
echo "============================================================"
echo "             Registration Issue Fixing Tool                 "
echo "============================================================"
log_message "Starting registration issue fixing tool"

# Verify FSL is available
if ! command -v fslinfo &>/dev/null; then
    log_error "FSL commands not found. Please ensure FSL is properly installed."
    exit 1
fi

# Check for FSLDIR environment variable
if [ -z "$FSLDIR" ]; then
    log_formatted "WARNING" "FSLDIR environment variable not set, using default paths"
    # Try to guess FSLDIR based on common locations
    for dir in /usr/local/fsl /opt/fsl /usr/share/fsl /Applications/fsl; do
        if [ -d "$dir" ]; then
            export FSLDIR="$dir"
            log_message "Found FSL in $FSLDIR"
            break
        fi
    done
fi

# Initialize MNI template path
MNI_TEMPLATE="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
MNI_BRAIN="${FSLDIR}/data/standard/MNI152_T1_1mm_brain.nii.gz"
MNI_MASK="${FSLDIR}/data/standard/MNI152_T1_1mm_brain_mask.nii.gz"

# Check if MNI templates exist
if [ ! -f "$MNI_TEMPLATE" ]; then
    log_formatted "WARNING" "MNI template not found at $MNI_TEMPLATE"
fi

# Source enhanced registration validation if available
if [ -f "$ENHANCED_REG_MODULE" ]; then
    source "$ENHANCED_REG_MODULE"
    log_message "Loaded enhanced registration validation module"
    ENHANCED_VALIDATION=true
else
    ENHANCED_VALIDATION=false
    log_formatted "WARNING" "Enhanced registration validation module not found at $ENHANCED_REG_MODULE"
    log_message "Limited functionality will be available"
fi

# Detect all NIfTI files in the mri_results directory
find_nifti_files() {
    local base_dir="$1"
    
    log_message "Searching for NIfTI files in $base_dir"
    find "$base_dir" -name "*.nii.gz" -type f
}

# Analyze image datatype
analyze_datatype() {
    local img="$1"
    local img_datatype=$(fslinfo "$img" | grep "^data_type" | awk '{print $2}')
    local img_val_range=$(fslstats "$img" -R)
    local is_binary=false
    
    # Check if image is binary (only 0s and 1s)
    local range_diff=$(echo "$img_val_range" | awk '{print $2 - $1}')
    if (( $(echo "$range_diff <= 1.01" | bc -l) )); then
        is_binary=true
    fi
    
    echo "File: $img"
    echo "  Datatype: $img_datatype"
    echo "  Value range: $img_val_range"
    echo "  Binary mask: $is_binary"
    
    # Provide recommendation
    if [ "$is_binary" = true ] && [ "$img_datatype" != "UINT8" ]; then
        echo "  RECOMMENDATION: Convert to UINT8 for better compatibility with binary masks"
    elif [ "$is_binary" = false ] && [ "$img_datatype" = "UINT8" ]; then
        echo "  RECOMMENDATION: Convert to INT16 for better precision with non-binary data"
    fi
}

# Check for datatype mismatches across images
check_datatype_mismatches() {
    local base_dir="$1"
    local output_file="${base_dir}/datatype_analysis.txt"
    
    log_message "Checking for datatype mismatches in $base_dir"
    echo "Datatype Analysis Report" > "$output_file"
    echo "=======================" >> "$output_file"
    echo "Date: $(date)" >> "$output_file"
    echo "" >> "$output_file"
    
    # Group images by directory
    while read -r img; do
        img_dir=$(dirname "$img")
        img_name=$(basename "$img")
        
        # Skip temporary files
        if [[ "$img_name" == *"tmp"* ]]; then
            continue
        fi
        
        echo "Analyzing $img_dir/$img_name" >> "$output_file"
        analyze_datatype "$img" >> "$output_file"
        echo "" >> "$output_file"
    done < <(find_nifti_files "$base_dir")
    
    log_message "Datatype analysis complete, report saved to $output_file"
}

# Fix datatypes for binary masks
fix_binary_mask_datatypes() {
    local base_dir="$1"
    local output_dir="${base_dir}/fixed_datatypes"
    
    mkdir -p "$output_dir"
    log_message "Fixing binary mask datatypes, outputs in $output_dir"
    
    while read -r img; do
        # Skip files that are already in the fixed_datatypes directory
        if [[ "$img" == *"fixed_datatypes"* ]]; then
            continue
        fi
        
        # Check if image is binary
        local img_val_range=$(fslstats "$img" -R)
        local range_diff=$(echo "$img_val_range" | awk '{print $2 - $1}')
        local is_binary=false
        #if (( $(echo "$range_diff <= 1.01" | bc -l) )); then
        #    is_binary=true
        #fi
        
        # Get current datatype
        local img_datatype=$(fslinfo "$img" | grep "^data_type" | awk '{print $2}')
        
        # Fix if needed
        if [ "$is_binary" = true ] && [ "$img_datatype" != "UINT8" ]; then
            local output_file="${output_dir}/$(basename "$img" .nii.gz)_uint8.nii.gz"
            log_message "Converting binary mask $img to UINT8"
            fslmaths "$img" -bin "$output_file" -odt int
        elif [ "$is_binary" = false ] && [ "$img_datatype" = "UINT8" ]; then
            #local output_file="${output_dir}/$(basename "$img" .nii.gz)_int16.nii.gz"
            #log_message "Converting non-binary data $img to INT16"
            #fslmaths "$img" "$output_file" -odt int
        fi
    done < <(find_nifti_files "$base_dir")
    
    log_message "Datatype fixing complete"
}

# Enhanced function to standardize coordinate spaces - only runs if needed directories exist
fix_coordinate_spaces() {
    local base_dir="$1"
    local output_dir="${base_dir}/fixed_spaces"
    
    mkdir -p "$output_dir"
    log_message "Fixing coordinate space mismatches, outputs in $output_dir"
    
    # Skip early if standardized directory doesn't exist yet (pipeline hasn't run yet)
    local standardized_dir="${base_dir}/standardized"
    if [ ! -d "$standardized_dir" ]; then
        log_formatted "INFO" "Standardized directory not found, skipping space fixing as pipeline hasn't created these files yet"
        return 0
    fi
    
    # Find all segmentation masks
    log_message "Looking for segmentation masks..."
    local segmentation_dir="${base_dir}/segmentation"
    if [ -d "$segmentation_dir" ]; then
        # Find reference T1 file
        local t1_std=$(find "$base_dir/standardized" -name "*T1*_std.nii.gz" | head -1)
        if [ -z "$t1_std" ]; then
            log_formatted "WARNING" "No standardized T1 found, using original T1"
            t1_std=$(find "$base_dir/bias_corrected" -name "*T1*.nii.gz" | head -1)
        fi
        
        # Process each segmentation mask
        if [ -n "$t1_std" ]; then
            log_message "Using T1 reference: $t1_std"
            while read -r mask; do
                # Get reference space information
                local t1_dims=$(fslinfo "$t1_std" | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x')
                local mask_dims=$(fslinfo "$mask" | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x')
                
                # Skip if dimensions already match
                if [ "$t1_dims" = "$mask_dims" ]; then
                    log_message "Mask $mask already matches T1 dimensions"
                    continue
                fi
                
                log_message "Resampling mask $mask to match T1 dimensions"
                local output_file="${output_dir}/$(basename "$mask" .nii.gz)_resampled.nii.gz"
                
                # Use FSL's applywarp to resample with nearest neighbor interpolation
                flirt -in "$mask" -ref "$t1_std" -out "$output_file" -applyxfm -init $FSLDIR/etc/flirtsch/ident.mat -interp nearestneighbour
                
                log_message "Resampled mask saved to $output_file"
            done < <(find "$segmentation_dir" -name "*.nii.gz")
        else
            log_formatted "ERROR" "No T1 reference found for resampling"
        fi
    else
        log_formatted "WARNING" "No segmentation directory found at $segmentation_dir"
    fi
    
    log_message "Space fixing complete"
}

# Main function
main() {
    # Determine base directory (default to ../mri_results)
    BASE_DIR="${1:-../mri_results}"
    
    if [ ! -d "$BASE_DIR" ]; then
        log_error "Base directory not found: $BASE_DIR"
        exit 1
    fi
    
    log_message "Fixing registration issues in: $BASE_DIR"
    
    # Check for datatype mismatches
    check_datatype_mismatches "$BASE_DIR"
    
    # Fix datatypes for binary masks
    fix_binary_mask_datatypes "$BASE_DIR"
    
    # Fix coordinate space mismatches
    fix_coordinate_spaces "$BASE_DIR"
    
    # If enhanced validation is available, run additional checks
    if [ "$ENHANCED_VALIDATION" = true ]; then
        log_message "Running enhanced validation checks..."
        
        # Find T1 and FLAIR files
        local t1_std=$(find "$BASE_DIR/standardized" -name "*T1*_std.nii.gz" | head -1)
        local flair_std=$(find "$BASE_DIR/standardized" -name "*FLAIR*_std.nii.gz" | head -1)
        
        if [ -n "$t1_std" ] && [ -n "$flair_std" ]; then
            # Run coordinate space validation
            local space_validation_dir="${BASE_DIR}/validation/space"
            mkdir -p "$space_validation_dir"
            
            # Validate spaces
            validate_coordinate_space "$t1_std" "$MNI_TEMPLATE" "$space_validation_dir/t1"
            validate_coordinate_space "$flair_std" "$MNI_TEMPLATE" "$space_validation_dir/flair"
            validate_coordinate_space "$flair_std" "$t1_std" "$space_validation_dir/t1_flair"
            
            # Check if any transformations are needed
            log_message "Checking if any standardizations are needed..."
            local t1_datatype=$(fslinfo "$t1_std" | grep "^data_type" | awk '{print $2}')
            local flair_datatype=$(fslinfo "$flair_std" | grep "^data_type" | awk '{print $2}')
            
            # Standardize datatypes if needed
            if [ "$t1_datatype" != "INT16" ]; then
                log_message "Standardizing T1 datatype to INT16 for better compatibility..."
                standardize_image_format "$t1_std" "$MNI_TEMPLATE" "${BASE_DIR}/fixed_datatypes/t1_std_INT16.nii.gz" "INT16"
            fi
            
            if [ "$flair_datatype" != "INT16" ]; then
                log_message "Standardizing FLAIR datatype to INT16 for better compatibility..."
                standardize_image_format "$flair_std" "$MNI_TEMPLATE" "${BASE_DIR}/fixed_datatypes/flair_std_INT16.nii.gz" "INT16"
            fi
        else
            log_formatted "WARNING" "Could not find standardized T1 and FLAIR for validation"
        fi
    fi
    
    log_message "Registration issue fixing complete"
    log_message "Fixed files are in the following directories:"
    log_message "  - Datatype fixes: ${BASE_DIR}/fixed_datatypes/"
    log_message "  - Space fixes: ${BASE_DIR}/fixed_spaces/"
    
    return 0
}

# Run main function with all arguments
main "$@"
