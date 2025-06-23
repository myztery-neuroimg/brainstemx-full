# Metadata-Enhanced File Selection and Orientation Validation

## Introduction

This document outlines the enhancements to the MRI processing pipeline to leverage JSON metadata for file selection and implement robust orientation validation. These improvements will:

1. Create a quality scoring system that prioritizes files based on ORIGINAL/DERIVED status and resolution
2. Implement orientation validation to prevent processing misaligned images
3. Fix diagnostic output issues to improve pipeline reliability
4. Fix the datatype conversion issue that's converting all NIfTI files to UINT8

## Implementation Phases

The implementation is divided into two phases:

- **Phase 1**: Critical immediate fixes for orientation correction, datatype conversion, and output validation
- **Phase 2**: Comprehensive metadata integration and advanced orientation validation

## Phase 1: Critical Immediate Fixes

### 1. Disable ORIENTATION_CORRECTION by Default

Update the configuration in `config/default_config.sh`:

```bash
# ------------------------------------------------------------------------------
# Orientation Parameters
# ------------------------------------------------------------------------------

# Disable orientation correction by default
export ORIENTATION_CORRECTION_ENABLED=false   # Previously was enabled
export ORIENTATION_VALIDATION_ENABLED=false    # Validate but don't auto-correct
export HALT_ON_ORIENTATION_MISMATCH=false      # Halt pipeline on orientation mismatch
```

### 2. Fix UINT8 Conversion for Mask Files Only

Update the `standardize_image_format` function in `src/modules/enhanced_registration_validation.sh`:

```bash
# Function to standardize image format for compatibility
standardize_image_format() {
    local image="$1"
    local reference="${2:-$MNI_TEMPLATE}"
    local output="${3:-$(dirname "$image")/$(basename "$image" .nii.gz)_std.nii.gz}"
    local datatype="${4:-}"  # Optional datatype override
    
    log_formatted "INFO" "===== STANDARDIZING IMAGE FORMAT ====="
    log_message "Image: $image"
    log_message "Reference: $reference"
    log_message "Output: $output"
    
    # Create output directory if needed
    mkdir -p "$(dirname "$output")"
    
    # Get reference datatype if not specified
    if [ -z "$datatype" ]; then
        datatype=$(fslinfo "$reference" | grep "^data_type" | awk '{print $2}')
        log_message "Using reference datatype: $datatype"
    fi
    
    # IMPROVED BINARY MASK DETECTION
    # Check if file is a binary mask using multiple criteria
    local is_binary=false
    local filename=$(basename "$image")
    
    # 1. First check: Does the filename contain mask-related keywords?
    if [[ "$filename" =~ (mask|bin|binary|brain_mask|seg|label) ]]; then
        log_message "Filename suggests this might be a binary mask: $filename"
        
        # 2. Second check: Verify with intensity statistics
        local range=$(fslstats "$image" -R)
        local min_val=$(echo "$range" | awk '{print $1}')
        local max_val=$(echo "$range" | awk '{print $2}')
        local unique_values=$(echo "$max_val - $min_val" | bc)
        
        # 3. Check unique values and range
        if (( $(echo "$unique_values <= 1.01" | bc -l) )); then
            # Likely a 0-1 binary mask
            is_binary=true
            log_message "File appears to be a binary 0-1 mask (range: $min_val to $max_val)"
        elif (( $(echo "$min_val >= -0.01" | bc -l) )) && (( $(echo "$max_val <= 5.01" | bc -l) )); then
            # Check if we have very few unique values (segmentation or probability mask)
            local num_unique=$(fslstats "$image" -H 10 0 10 | awk '{sum+=$1} END {print NR}')
            
            if [ "$num_unique" -lt 7 ]; then
                is_binary=true
                log_message "File appears to be a segmentation mask with $num_unique unique values"
            else
                is_binary=false
                log_message "File has multiple intensity values ($num_unique), treating as intensity image"
            fi
        else
            is_binary=false
            log_message "File intensity range suggests this is NOT a binary mask: $min_val to $max_val"
        fi
    else
        # Not likely a mask based on filename
        is_binary=false
        log_message "Filename does not suggest a binary mask: $filename"
    fi
    
    # Explicitly check for known intensity images by name
    if [[ "$filename" =~ (T1|MPRAGE|FLAIR|T2|DWI|SWI|EPI|_brain) ]] && ! [[ "$filename" =~ (mask) ]]; then
        # Override the binary detection for actual image data types
        if [ "$is_binary" = "true" ]; then
            log_message "Overriding binary detection: file name suggests this is an actual image volume"
            is_binary=false
        fi
    fi
    
    # Special handling for BrainExtraction files that are NOT binary masks
    if [[ "$filename" =~ BrainExtraction ]] && ! [[ "$filename" =~ (Mask|Template|Prior|BrainFace|CSF) ]]; then
        is_binary=false
        log_message "BrainExtraction file that's not a mask, treating as intensity image"
    fi
    
    # Choose appropriate datatype based on content
    local target_datatype
    if [ "$is_binary" = "true" ]; then
        # Binary masks should be UINT8 for efficiency
        target_datatype="UINT8"
        log_message "Image is a binary or segmentation mask, using UINT8 datatype"
    else
        # For intensity data (like FLAIR and T1), preserve the original datatype or use FLOAT32
        local orig_datatype=$(fslinfo "$image" | grep "^data_type" | awk '{print $2}')
        
        if [ "$orig_datatype" = "FLOAT32" ] || [ "$orig_datatype" = "FLOAT64" ]; then
            # Preserve floating point for intensity data
            target_datatype="$orig_datatype"
            log_message "Preserving original float datatype: $orig_datatype"
        elif [[ "$filename" =~ (T1|MPRAGE|FLAIR|T2|DWI|SWI|EPI) ]]; then
            # Use FLOAT32 for actual image data that wasn't already float
            target_datatype="FLOAT32"
            log_message "Image appears to be an intensity image, converting to FLOAT32"
        else
            # Default to INT16 for other data
            target_datatype="INT16"
            log_message "Using INT16 for unclassified non-binary image"
        fi
    fi
    
    # Get current datatype of the image
    local img_datatype=$(fslinfo "$image" | grep "^data_type" | awk '{print $2}')
    
    # Convert datatype if needed
    if [ "$img_datatype" != "$target_datatype" ]; then
        log_message "Converting datatype from $img_datatype to $target_datatype"
        
        # Map datatype string to FSL datatype number
        local datatype_num
        case "$target_datatype" in
            "UINT8")   datatype_num=2  ;;
            "INT8")    datatype_num=2  ;;
            "INT16")   datatype_num=4  ;;
            "INT32")   datatype_num=8  ;;
            "FLOAT32") datatype_num=16 ;;
            "FLOAT64") datatype_num=64 ;;
            *)         datatype_num=4  ;; # Default to INT16
        esac
        
        # Convert datatype with detailed logging
        log_message "Running: fslmaths $image -dt $datatype_num $output"
        fslmaths "$image" -dt "$datatype_num" "$output"
    else
        log_message "Datatype already matches target ($target_datatype), copying file"
        cp "$image" "$output"
    fi
    
    if [ -f "$output" ]; then
        # Verify the operation was successful
        local final_datatype=$(fslinfo "$output" | grep "^data_type" | awk '{print $2}')
        log_formatted "SUCCESS" "Image format standardized: $output (datatype: $final_datatype)"
        return 0
    else
        log_formatted "ERROR" "Failed to standardize image format"
        return 1
    fi
}
```

### 3. Ensure Correct Files in Appropriate Directories

Add a verification function to check expected outputs after each pipeline step:

```bash
# Function to verify expected outputs from a pipeline step
verify_pipeline_step_outputs() {
    local step_name="$1"       # Name of the pipeline step (e.g., "registration", "segmentation")
    local output_dir="$2"      # Directory containing the outputs
    local modality="$3"        # Modality being processed (e.g., "T1", "FLAIR")
    local min_expected="${4:-1}"  # Minimum number of expected .nii.gz files
    
    log_formatted "INFO" "===== VERIFYING OUTPUTS FOR $step_name ($modality) ====="
    log_message "Output directory: $output_dir"
    log_message "Minimum expected files: $min_expected"
    
    # Check if directory exists
    if [ ! -d "$output_dir" ]; then
        log_formatted "ERROR" "Output directory does not exist: $output_dir"
        return 1
    fi
    
    # Count .nii.gz files
    local file_count=$(find "$output_dir" -name "*.nii.gz" -type f | wc -l)
    log_message "Found $file_count .nii.gz files in $output_dir"
    
    # Check if we have enough files
    if [ "$file_count" -lt "$min_expected" ]; then
        log_formatted "ERROR" "Insufficient output files: found $file_count, expected at least $min_expected"
        return 1
    fi
    
    # Check file datatypes
    log_message "Checking file datatypes..."
    local error_count=0
    
    for file in $(find "$output_dir" -name "*.nii.gz" -type f); do
        local filename=$(basename "$file")
        local datatype=$(fslinfo "$file" | grep "^data_type" | awk '{print $2}')
        
        # Verify datatype is appropriate
        if [[ "$filename" =~ (mask|bin|binary|Brain_Extraction_Mask) ]]; then
            # Binary masks should be UINT8
            if [ "$datatype" != "UINT8" ]; then
                log_formatted "WARNING" "Binary mask $filename has incorrect datatype: $datatype (expected UINT8)"
                error_count=$((error_count + 1))
            fi
        elif [[ "$filename" =~ (T1|MPRAGE|FLAIR|T2|DWI|SWI|EPI|brain) ]] && ! [[ "$filename" =~ (mask) ]]; then
            # Intensity images should not be UINT8
            if [ "$datatype" = "UINT8" ]; then
                log_formatted "ERROR" "Intensity image $filename has incorrect datatype: UINT8"
                error_count=$((error_count + 1))
            fi
        fi
        
        log_message "File: $filename, Datatype: $datatype"
    done
    
    if [ "$error_count" -gt 0 ]; then
        log_formatted "WARNING" "Found $error_count datatype issues in output files"
    else
        log_formatted "SUCCESS" "All output files have appropriate datatypes"
    fi
    
    # Generate additional step-specific checks based on the step name
    case "$step_name" in
        "brain_extraction")
            # Check for brain mask
            if ! find "$output_dir" -name "*brain_mask.nii.gz" -type f | grep -q .; then
                log_formatted "WARNING" "No brain mask file found in brain extraction outputs"
                error_count=$((error_count + 1))
            fi
            
            # Check for extracted brain
            if ! find "$output_dir" -name "*brain.nii.gz" -type f | grep -q .; then
                log_formatted "WARNING" "No extracted brain file found in brain extraction outputs"
                error_count=$((error_count + 1))
            fi
            ;;
            
        "registration")
            # Check for warped file
            if ! find "$output_dir" -name "*Warped.nii.gz" -type f | grep -q .; then
                log_formatted "WARNING" "No warped file found in registration outputs"
                error_count=$((error_count + 1))
            fi
            
            # Check for transform file
            if ! find "$output_dir" -name "*GenericAffine.mat" -type f | grep -q .; then
                log_formatted "WARNING" "No transform file found in registration outputs"
                error_count=$((error_count + 1))
            fi
            ;;
            
        "segmentation")
            # Check for segmentation outputs
            if ! find "$output_dir" -name "*seg*.nii.gz" -type f | grep -q .; then
                log_formatted "WARNING" "No segmentation file found in segmentation outputs"
                error_count=$((error_count + 1))
            fi
            ;;
            
        "bias_corrected")
            # Check for bias corrected image
            if ! find "$output_dir" -name "*n4*.nii.gz" -type f | grep -q .; then
                log_formatted "WARNING" "No bias-corrected file found in outputs"
                error_count=$((error_count + 1))
            fi
            ;;
    esac
    
    # Return success if no errors, otherwise return error count
    if [ "$error_count" -eq 0 ]; then
        log_formatted "SUCCESS" "All expected outputs for $step_name ($modality) are present and valid"
        return 0
    else
        log_formatted "WARNING" "Found $error_count issues with $step_name ($modality) outputs"
        return "$error_count"
    fi
}
```

### Phase 1 Integration

1. Update the configuration file to disable orientation correction by default:

```bash
# Add to config/default_config.sh
export ORIENTATION_CORRECTION_ENABLED=false  # Disable by default
```

2. Replace the datatype conversion logic in enhanced_registration_validation.sh with the improved version

3. Add verification steps after each major pipeline stage:

```bash
# Example integration in pipeline.sh or module-specific scripts

# After brain extraction
verify_pipeline_step_outputs "brain_extraction" "${RESULTS_DIR}/brain_extraction" "T1" 2

# After registration
verify_pipeline_step_outputs "registration" "${RESULTS_DIR}/registered" "T1_to_FLAIR" 2

# After segmentation
verify_pipeline_step_outputs "segmentation" "${RESULTS_DIR}/segmentation" "T1" 3

# After bias correction
verify_pipeline_step_outputs "bias_corrected" "${RESULTS_DIR}/bias_corrected" "T1" 1
```

## Phase 2: Metadata Integration and Advanced Orientation Validation

### A. Metadata Parser Enhancement

#### 1. Add file quality scoring function to enhanced_registration_validation.sh

```bash
# Function to generate quality score for file selection
score_file_quality() {
    local file="$1"
    local json_file="${file%.nii.gz}.json"
    local total_score=0
    
    # Check if JSON exists
    if [ -f "$json_file" ]; then
        # Check ORIGINAL vs DERIVED status
        local image_type=$(grep -o '"ImageType":\s*\[[^]]*\]' "$json_file" | grep -i "ORIGINAL")
        if [ -n "$image_type" ]; then
            # Apply ORIGINAL preference weight
            total_score=$((total_score + ORIGINAL_PREFERENCE_WEIGHT))
            log_message "File $file is ORIGINAL: +$ORIGINAL_PREFERENCE_WEIGHT points"
        else
            log_message "File $file is DERIVED: +0 points"
        fi
        
        # Check for resolution information in JSON (if available)
        local spacing_x=$(grep -o '"PixelSpacing":\s*\[[^]]*\]' "$json_file" | awk -F',' '{print $1}' | grep -o '[0-9.]*')
        local spacing_y=$(grep -o '"PixelSpacing":\s*\[[^]]*\]' "$json_file" | awk -F',' '{print $2}' | grep -o '[0-9.]*')
        local spacing_z=$(grep -o '"SliceThickness":\s*[0-9.]*' "$json_file" | grep -o '[0-9.]*')
        
        if [ -n "$spacing_x" ] && [ -n "$spacing_y" ] && [ -n "$spacing_z" ]; then
            local res_score=$(echo "scale=2; 10 * (1 / (($spacing_x + $spacing_y + $spacing_z) / 3))" | bc -l)
            total_score=$(echo "$total_score + $res_score" | bc -l)
            log_message "Resolution score for $file: +$res_score points (from JSON)"
        fi
    fi
    
    # If resolution not found in JSON or JSON doesn't exist, use fslinfo
    if ! grep -q "Resolution score" <<< "$(log_message "")" && [ -f "$file" ]; then
        local pixdim1=$(fslinfo "$file" | grep pixdim1 | awk '{print $2}')
        local pixdim2=$(fslinfo "$file" | grep pixdim2 | awk '{print $2}')
        local pixdim3=$(fslinfo "$file" | grep pixdim3 | awk '{print $2}')
        local res_score=$(echo "scale=2; 10 * (1 / (($pixdim1 + $pixdim2 + $pixdim3) / 3))" | bc -l)
        total_score=$(echo "$total_score + $res_score" | bc -l)
        log_message "Resolution score for $file: +$res_score points (from fslinfo)"
    fi
    
    # Apply pattern matching bonus based on existing priority patterns
    if [[ "$file" =~ $T1_PRIORITY_PATTERN ]]; then
        local pattern_score=5
        total_score=$(echo "$total_score + $pattern_score" | bc -l)
        log_message "T1 priority pattern match for $file: +$pattern_score points"
    elif [[ "$file" =~ $FLAIR_PRIORITY_PATTERN ]]; then
        local pattern_score=5
        total_score=$(echo "$total_score + $pattern_score" | bc -l)
        log_message "FLAIR priority pattern match for $file: +$pattern_score points"
    fi
    
    log_message "Total quality score for $file: $total_score"
    echo "$total_score"
}
```

#### 2. Create file selection function that uses scoring

```bash
# Function to select best file from a set of candidates
select_best_file() {
    local pattern="$1"
    local dir="$2"
    local modality="${3:-UNKNOWN}"
    local best_file=""
    local best_score=0
    
    log_formatted "INFO" "Selecting best $modality file with pattern: $pattern"
    
    # Create a temporary directory for storing file scores
    local temp_dir=$(mktemp -d)
    local score_file="${temp_dir}/scores.txt"
    
    # Process all matching files
    for file in $(find "$dir" -name "$pattern"); do
        local score=$(score_file_quality "$file")
        echo "$score $file" >> "$score_file"
        
        if (( $(echo "$score > $best_score" | bc -l) )); then
            best_score="$score"
            best_file="$file"
        fi
    done
    
    # Log all candidates and their scores for transparency
    if [ -f "$score_file" ]; then
        log_message "All $modality candidates and scores:"
        sort -nr "$score_file" | while read -r line; do
            log_message "  $line"
        done
        rm -f "$score_file"
    fi
    
    # Clean up
    rmdir "$temp_dir"
    
    if [ -n "$best_file" ]; then
        log_formatted "SUCCESS" "Selected best $modality file: $best_file (score: $best_score)"
    else
        log_formatted "WARNING" "No files found matching pattern: $pattern"
    fi
    
    echo "$best_file"
}
```

### B. Advanced Orientation Validation

#### 1. Add comprehensive orientation checker

```bash
# Function to check file orientation
validate_file_orientation() {
    local file="$1"
    local reference="${2:-}"
    local output_dir="${3:-./orientation_validation}"
    
    log_formatted "INFO" "===== VALIDATING FILE ORIENTATION ====="
    log_message "File: $file"
    if [ -n "$reference" ]; then
        log_message "Reference: $reference"
    fi
    
    mkdir -p "$output_dir"
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        log_formatted "ERROR" "File does not exist: $file"
        return 1
    fi
    
    # Get orientation information using fslhd
    local orientation=$(fslhd "$file" | grep -E "qform_[xyz]orient|sform_[xyz]orient")
    local qform_x=$(echo "$orientation" | grep "qform_xorient" | awk '{print $2}')
    local qform_y=$(echo "$orientation" | grep "qform_yorient" | awk '{print $2}')
    local qform_z=$(echo "$orientation" | grep "qform_zorient" | awk '{print $2}')
    local sform_x=$(echo "$orientation" | grep "sform_xorient" | awk '{print $2}')
    local sform_y=$(echo "$orientation" | grep "sform_yorient" | awk '{print $2}')
    local sform_z=$(echo "$orientation" | grep "sform_zorient" | awk '{print $2}')
    
    # Create report
    {
        echo "Orientation Validation Report"
        echo "============================"
        echo "Date: $(date)"
        echo ""
        echo "File: $file"
        echo ""
        echo "qform orientation:"
        echo "  X: $qform_x"
        echo "  Y: $qform_y"
        echo "  Z: $qform_z"
        echo ""
        echo "sform orientation:"
        echo "  X: $sform_x"
        echo "  Y: $sform_y"
        echo "  Z: $sform_z"
    } > "${output_dir}/$(basename "$file")_orientation.txt"
    
    # If reference is provided, compare orientations
    if [ -n "$reference" ] && [ -f "$reference" ]; then
        local ref_orientation=$(fslhd "$reference" | grep -E "qform_[xyz]orient|sform_[xyz]orient")
        local ref_qform_x=$(echo "$ref_orientation" | grep "qform_xorient" | awk '{print $2}')
        local ref_qform_y=$(echo "$ref_orientation" | grep "qform_yorient" | awk '{print $2}')
        local ref_qform_z=$(echo "$ref_orientation" | grep "qform_zorient" | awk '{print $2}')
        local ref_sform_x=$(echo "$ref_orientation" | grep "sform_xorient" | awk '{print $2}')
        local ref_sform_y=$(echo "$ref_orientation" | grep "sform_yorient" | awk '{print $2}')
        local ref_sform_z=$(echo "$ref_orientation" | grep "sform_zorient" | awk '{print $2}')
        
        # Check if orientations match
        local orientation_match=true
        if [ "$qform_x" != "$ref_qform_x" ] || [ "$qform_y" != "$ref_qform_y" ] || [ "$qform_z" != "$ref_qform_z" ] || \
           [ "$sform_x" != "$ref_sform_x" ] || [ "$sform_y" != "$ref_sform_y" ] || [ "$sform_z" != "$ref_sform_z" ]; then
            orientation_match=false
        fi
        
        # Update report with comparison
        {
            echo ""
            echo "Reference: $reference"
            echo ""
            echo "Reference qform orientation:"
            echo "  X: $ref_qform_x"
            echo "  Y: $ref_qform_y"
            echo "  Z: $ref_qform_z"
            echo ""
            echo "Reference sform orientation:"
            echo "  X: $ref_sform_x"
            echo "  Y: $ref_sform_y"
            echo "  Z: $ref_sform_z"
            echo ""
            echo "Orientation Match: $orientation_match"
            
            if [ "$orientation_match" = "false" ]; then
                echo ""
                echo "CRITICAL ERROR: Orientation mismatch detected"
                echo "This will cause significant issues with registration and analysis"
                echo ""
                echo "Mismatched orientations:"
                
                if [ "$qform_x" != "$ref_qform_x" ]; then
                    echo "  qform X-orientation: $qform_x vs $ref_qform_x"
                fi
                if [ "$qform_y" != "$ref_qform_y" ]; then
                    echo "  qform Y-orientation: $qform_y vs $ref_qform_y"
                fi
                if [ "$qform_z" != "$ref_qform_z" ]; then
                    echo "  qform Z-orientation: $qform_z vs $ref_qform_z"
                fi
                if [ "$sform_x" != "$ref_sform_x" ]; then
                    echo "  sform X-orientation: $sform_x vs $ref_sform_x"
                fi
                if [ "$sform_y" != "$ref_sform_y" ]; then
                    echo "  sform Y-orientation: $sform_y vs $ref_sform_y"
                fi
                if [ "$sform_z" != "$ref_sform_z" ]; then
                    echo "  sform Z-orientation: $sform_z vs $ref_sform_z"
                fi
                
                echo ""
                echo "Suggested fix command:"
                
                # Generate appropriate swap command based on the mismatch
                if [ "$qform_x" = "Right-to-Left" ] && [ "$ref_qform_x" = "Left-to-Right" ]; then
                    echo "fslswapdim $file -x y z ${file%.nii.gz}_reorient.nii.gz"
                elif [ "$qform_x" = "Left-to-Right" ] && [ "$ref_qform_x" = "Right-to-Left" ]; then
                    echo "fslswapdim $file -x y z ${file%.nii.gz}_reorient.nii.gz"
                elif [ "$qform_y" = "Posterior-to-Anterior" ] && [ "$ref_qform_y" = "Anterior-to-Posterior" ]; then
                    echo "fslswapdim $file x -y z ${file%.nii.gz}_reorient.nii.gz"
                elif [ "$qform_y" = "Anterior-to-Posterior" ] && [ "$ref_qform_y" = "Posterior-to-Anterior" ]; then
                    echo "fslswapdim $file x -y z ${file%.nii.gz}_reorient.nii.gz"
                elif [ "$qform_z" = "Inferior-to-Superior" ] && [ "$ref_qform_z" = "Superior-to-Inferior" ]; then
                    echo "fslswapdim $file x y -z ${file%.nii.gz}_reorient.nii.gz"
                elif [ "$qform_z" = "Superior-to-Inferior" ] && [ "$ref_qform_z" = "Inferior-to-Superior" ]; then
                    echo "fslswapdim $file x y -z ${file%.nii.gz}_reorient.nii.gz"
                else
                    echo "# Complex orientation mismatch, manual intervention required"
                    echo "# Consider using: fslswapdim <options based on specific mismatch>"
                fi
            fi
        } >> "${output_dir}/$(basename "$file")_orientation.txt"
        
        # Return success/failure
        if [ "$orientation_match" = "true" ]; then
            log_formatted "SUCCESS" "Orientation validation passed"
            return 0
        else
            if [ "${HALT_ON_ORIENTATION_MISMATCH:-true}" = "true" ]; then
                log_formatted "ERROR" "ORIENTATION MISMATCH DETECTED - HALTING PIPELINE"
                log_message "See ${output_dir}/$(basename "$file")_orientation.txt for details"
                cat "${output_dir}/$(basename "$file")_orientation.txt"
                return 1
            else
                log_formatted "WARNING" "Orientation mismatch detected but continuing due to HALT_ON_ORIENTATION_MISMATCH=false"
                return 0
            fi
        fi
    else
        # Check against expected orientations if no reference provided
        local expected_qform_x="${EXPECTED_QFORM_X:-Left-to-Right}"
        local expected_qform_y="${EXPECTED_QFORM_Y:-Posterior-to-Anterior}"
        local expected_qform_z="${EXPECTED_QFORM_Z:-Inferior-to-Superior}"
        
        local orientation_ok=true
        if [ "$qform_x" != "$expected_qform_x" ] || [ "$qform_y" != "$expected_qform_y" ] || [ "$qform_z" != "$expected_qform_z" ]; then
            orientation_ok=false
        fi
        
        # Update report with expected orientations
        {
            echo ""
            echo "Expected qform orientation:"
            echo "  X: $expected_qform_x"
            echo "  Y: $expected_qform_y"
            echo "  Z: $expected_qform_z"
            echo ""
            echo "Orientation Match: $orientation_ok"
            
            if [ "$orientation_ok" = "false" ]; then
                echo ""
                echo "WARNING: Non-standard orientation detected"
                echo "This may cause issues with atlas registration"
                
                if [ "$qform_x" != "$expected_qform_x" ]; then
                    echo "  X-orientation: $qform_x (Expected: $expected_qform_x)"
                fi
                if [ "$qform_y" != "$expected_qform_y" ]; then
                    echo "  Y-orientation: $qform_y (Expected: $expected_qform_y)"
                fi
                if [ "$qform_z" != "$expected_qform_z" ]; then
                    echo "  Z-orientation: $qform_z (Expected: $expected_qform_z)"
                fi
            fi
        } >> "${output_dir}/$(basename "$file")_orientation.txt"
        
        log_message "Orientation report saved to: ${output_dir}/$(basename "$file")_orientation.txt"
        
        # Only return failure if orientation check failed AND we're configured to halt
        if [ "$orientation_ok" = "false" ] && [ "${HALT_ON_ORIENTATION_MISMATCH:-true}" = "true" ]; then
            log_formatted "ERROR" "NON-STANDARD ORIENTATION DETECTED - HALTING PIPELINE"
            log_message "See ${output_dir}/$(basename "$file")_orientation.txt for details"
            cat "${output_dir}/$(basename "$file")_orientation.txt"
            return 1
        fi
        
        return 0
    fi
}
```

### C. Configuration Updates for Phase 2

Add these parameters to config/default_config.sh:

```bash
# ------------------------------------------------------------------------------
# Metadata and Orientation Parameters
# ------------------------------------------------------------------------------

# Metadata-based file selection
export METADATA_BASED_SELECTION=true
export ORIGINAL_PREFERENCE_WEIGHT=30  # Percentage boost for ORIGINAL files

# Expected orientation for validation when no reference provided
export EXPECTED_QFORM_X="Left-to-Right"
export EXPECTED_QFORM_Y="Posterior-to-Anterior"
export EXPECTED_QFORM_Z="Inferior-to-Superior"
export EXPECTED_SFORM_X="Left-to-Right"
export EXPECTED_SFORM_Y="Posterior-to-Anterior"
export EXPECTED_SFORM_Z="Inferior-to-Superior"

# Priority patterns for modality selection
export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_.*.nii.gz"
export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS.*.nii.gz"
```

### D. Diagnostic Output Improvement

Update the execute_ants_command function in environment.sh:

```bash
# Function specifically for ANTs commands without escaping issues
execute_ants_command() {
    local log_prefix="${1:-ants_cmd}"
    local diagnostic_log="${LOG_DIR}/${log_prefix}_diagnostic.log"
    local cmd=("${@:2}") # Get all arguments except the first one as the command
    
    # Create diagnostic log directory if needed
    mkdir -p "$LOG_DIR"
    
    # Log the command that will be executed
    log_message "Executing ANTs command: ${cmd[*]} (diagnostic output redirected to $diagnostic_log)"
    
    # Improved filtering to handle all diagnostic patterns from ANTs
    # This captures both "2DIAGNOSTIC" and "DIAGNOSTIC" messages
    # It will also filter out the Euler3DTransform registration diagnostics
    
    # Create named pipes for better output handling
    local stdout_pipe=$(mktemp -u)
    local stderr_pipe=$(mktemp -u)
    mkfifo "$stdout_pipe"
    mkfifo "$stderr_pipe"
    
    # Start background processes to handle output
    grep -v -E "^(2)?DIAGNOSTIC|^XXDIAGNOSTIC|convergenceValue|metricValue|ITERATION_TIME" < "$stdout_pipe" | tee -a "$LOG_FILE" &
    local stdout_pid=$!
    
    tee -a "$diagnostic_log" < "$stderr_pipe" >&2 &
    local stderr_pid=$!
    
    # Execute command directly without eval with improved output redirection
    "${cmd[@]}" > "$stdout_pipe" 2> "$stderr_pipe"
    local status=$?
    
    # Wait for output handling processes to complete
    wait $stdout_pid
    wait $stderr_pid
    
    # Remove named pipes
    rm -f "$stdout_pipe" "$stderr_pipe"
    
    # Add better status reporting after command completes
    if [ $status -eq 0 ]; then
        log_formatted "SUCCESS" "ANTs command completed successfully"
    else
        log_formatted "ERROR" "ANTs command failed with status $status"
        # Extract important error lines from the diagnostic log
        tail -n 10 "$diagnostic_log" | grep -v -E "^(2)?DIAGNOSTIC|^XXDIAGNOSTIC|convergenceValue" | tail -n 3
    fi
    
    # Return the exit code of the command
    return $status
}
```

## Phase 2 Integration

### 1. Enhance registration.sh to integrate with the new features

Modify the register_modality_to_t1 function to include orientation validation:

```bash
# Function to register any modality to T1
register_modality_to_t1() {
    local t1_file="$1"
    local modality_file="$2"
    local modality_name="${3:-OTHER}"
    local out_prefix="${4:-${RESULTS_DIR}/registered/t1_to_${modality_name,,}}"
    
    if [ ! -f "$t1_file" ] || [ ! -f "$modality_file" ]; then
        log_formatted "ERROR" "T1 or $modality_name file not found"
        return 1
    fi
    
    log_message "=== Registering $modality_name to T1 with orientation validation ==="
    
    # Create validation directory
    local validation_dir="${out_prefix}_validation"
    mkdir -p "$validation_dir"
    
    # Validate orientation compatibility before registration
    if ! validate_orientation_compatibility "$t1_file" "$modality_file" "$validation_dir"; then
        log_formatted "ERROR" "Orientation validation failed, aborting registration"
        return 1
    fi
    
    # Continue with existing registration logic...
}
```

### 2. Enhance file selection in pipeline.sh

Add modality-specific file selection functions:

```bash
# Function to select best T1 file
select_best_t1() {
    local extract_dir="$1"
    local pattern="${2:-.*T1.*\.nii\.gz}"
    
    # Use metadata-based selection if enabled
    if [ "${METADATA_BASED_SELECTION:-true}" = "true" ]; then
        log_formatted "INFO" "Using metadata-based T1 selection"
        select_best_file "$pattern" "$extract_dir" "T1"
    else
        # Fall back to existing pattern-based selection
        log_formatted "INFO" "Using pattern-based T1 selection"
        find "$extract_dir" -name "$pattern" | head -1
    fi
}

# Function to select best FLAIR file
select_best_flair() {
    local extract_dir="$1"
    local pattern="${2:-.*FLAIR.*\.nii\.gz}"
    
    # Use metadata-based selection if enabled
    if [ "${METADATA_BASED_SELECTION:-true}" = "true" ]; then
        log_formatted "INFO" "Using metadata-based FLAIR selection"
        select_best_file "$pattern" "$extract_dir" "FLAIR"
    else
        # Fall back to existing pattern-based selection
        log_formatted "INFO" "Using pattern-based FLAIR selection"
        find "$extract_dir" -name "$pattern" | head -1
    fi
}
```

## Implementation Strategy

1. **Phase 1 (Immediate Fixes)** - Implement the critical fixes:
   - Fix datatype conversion to prevent UINT8 conversion of intensity images 
   - Disable orientation correction by default
   - Add file verification to ensure correct output files

2. **Phase 2 (Enhancements)** - Implement the advanced features:
   - Add metadata-based file selection with ORIGINAL/DERIVED scoring
   - Implement comprehensive orientation validation
   - Fix XXDIAGNOSTIC output redirection

## Testing Plan

### Phase 1 Testing
1. **Binary Mask Detection Testing**:
   - Test with various filenames and intensity ranges
   - Verify recognition of true binary masks from intensity images
   - Ensure BrainExtraction images are not misclassified

2. **Datatype Preservation Testing**:
   - Verify intensity images retain FLOAT32/INT16 format
   - Verify true binary masks convert to UINT8
   - Check types of files in each output directory

3. **Pipeline Output Verification**:
   - Run pipeline with verification steps
   - Confirm expected files and correct datatypes in each directory

### Phase 2 Testing
1. **Metadata Extraction Testing**:
   - Test with known ORIGINAL and DERIVED files
   - Verify correct parsing of ImageType field
   - Verify correct scoring based on ORIGINAL/DERIVED status

2. **Orientation Validation Testing**:
   - Test with correctly oriented files
   - Test with intentionally misoriented files
   - Verify halt behavior works as expected

3. **File Selection Testing**:
   - Test selection with mix of ORIGINAL and DERIVED files
   - Verify selection logic prioritizes correctly

## Implementation Checklist

### Phase 1 (Immediate Fixes)
- [ ] Update configuration file to disable orientation correction
- [ ] Replace the standardize_image_format function
- [ ] Add the verification function
- [ ] Integrate verification steps throughout the pipeline
- [ ] Test the changes with various image types

### Phase 2 (Enhancements)
- [ ] Implement JSON metadata parsing
- [ ] Add file quality scoring function
- [ ] Add best-file selection function
- [ ] Implement enhanced orientation validation
- [ ] Fix XXDIAGNOSTIC output redirection
- [ ] Update pipeline to use metadata-based file selection
- [ ] Test the enhancements