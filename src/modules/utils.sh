#!/usr/bin/env bash
#
# utils.sh - Utility functions for the brain MRI processing pipeline
#

# Legacy wrapper function for ANTs commands - only kept for backwards compatibility
# Use the enhanced version from environment.sh for new code
#
# NOTE: This function is deprecated and will be removed in a future version.
# Please use the execute_ants_command from environment.sh which provides:
# - Better progress indication
# - Step descriptions
# - Execution time tracking
# - Visualization suggestions
legacy_execute_ants_command() {
    log_formatted "WARNING" "Using legacy_execute_ants_command - please update to new version from environment.sh"
    
    local log_prefix="$1"
    shift
    
    # Create logs directory if it doesn't exist
    mkdir -p "$RESULTS_DIR/logs"
    
    # Full log file path
    local full_log="$RESULTS_DIR/logs/${log_prefix}_full.log"
    local filtered_log="$RESULTS_DIR/logs/${log_prefix}_filtered.log"
    
    log_message "Running ANTs command: $1 (full logs: $full_log)"
    
    # Execute the command and redirect ALL output to the log file
    "$@" > "$full_log" 2>&1
    local status=$?
    
    # Create a filtered version without the diagnostic lines
    grep -v "DIAGNOSTIC" "$full_log" | grep -v "^$" > "$filtered_log"
    
    # Show a summary of what happened (last few non-empty lines)
    if [ $status -eq 0 ]; then
        log_formatted "SUCCESS" "ANTs command completed successfully."
        log_message "Summary (last 3 lines):"
        tail -n 3 "$filtered_log" 
    else
        log_formatted "ERROR" "ANTs command failed with status $status"
        log_message "Error summary (last 5 lines):"
        tail -n 5 "$filtered_log" 
    fi
    
    return $status
}

# Export functions
export -f legacy_execute_ants_command

log_message "Utilities module loaded"

# Wrapper to apply transforms using FLIRT or ANTs based on USE_ANTS_SYN flag
apply_transform() {
    local input_file="$1"
    local ref_file="$2"
    local transform_file="$3"
    local output_file="$4"
    local interp="${5:-trilinear}"

    # Handle usesqform flag (skip init matrix)
    if [ "${transform_file}" == "-usesqform" ]; then
        log_message "Applying transform with FLIRT using sform/qform: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -usesqform -out "${output_file}" -interp "${interp}"
        return $?
    fi

    if [ "${USE_ANTS_SYN}" = "true" ]; then
        # Map interpolation to ANTs options
        local ants_interp="Linear"
        if [[ "${interp}" == "nearestneighbour" ]]; then
            ants_interp="NearestNeighbor"
        fi
        # Use centralized apply_transformation function for consistent SyN transform handling
        log_message "Using centralized apply_transformation function..."
        
        # Extract transform prefix from transform file path
        local transform_prefix="${transform_file%0GenericAffine.mat}"
        if apply_transformation "${input_file}" "${ref_file}" "${output_file}" "$transform_prefix" "${ants_interp}"; then
            log_message "✓ Successfully applied transform using centralized function"
        else
            log_formatted "ERROR" "Failed to apply transform using centralized function"
            return 1
        fi
    else
        log_message "Applying transform with FLIRT: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -init "${transform_file}" \
            -out "${output_file}" -interp "${interp}"
    fi
}

# Function to perform brain extraction using available ANTs tools
perform_brain_extraction() {
  local input_file="$1"
  local output_prefix="$2"
  local brain_file="${output_prefix}BrainExtractionBrain.nii.gz"
  local mask_file="${output_prefix}BrainExtractionMask.nii.gz"

  # Check for required ANTs tools
  if command -v N4BiasFieldCorrection &> /dev/null && \
     command -v ThresholdImage &> /dev/null && \
     command -v ImageMath &> /dev/null; then
    
    log_message "Using ANTs template-free brain extraction for: $input_file"

    local temp_dir
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/brain_extraction_XXXXXX")
    local n4_corrected="${temp_dir}/n4_corrected.nii.gz"
    local initial_mask="${temp_dir}/initial_mask.nii.gz"
    local largest_component_mask="${temp_dir}/largest_component_mask.nii.gz"
    local refined_mask="${temp_dir}/refined_mask.nii.gz"

    # 1. N4 Bias Field Correction
    log_message "Step 1: Performing N4 Bias Field Correction"
    if ! execute_with_logging "N4BiasFieldCorrection -d 3 -i \"$input_file\" -o \"$n4_corrected\" -s 4 -c \"[50x50x30x20,1e-6]\" -b \"[200]\"" "n4_correction"; then
        log_formatted "ERROR" "N4BiasFieldCorrection failed."
        rm -rf "$temp_dir"
        return 1
    fi

    # 2. Otsu Thresholding for initial brain mask
    log_message "Step 2: Creating initial brain mask with Otsu thresholding"
    if ! execute_with_logging "ThresholdImage 3 \"$n4_corrected\" \"$initial_mask\" Otsu 1" "otsu_threshold"; then
        log_formatted "ERROR" "Otsu thresholding failed."
        rm -rf "$temp_dir"
        return 1
    fi

    # 3. Keep largest connected component
    log_message "Step 3: Identifying largest connected component"
    if ! execute_with_logging "ImageMath 3 \"$largest_component_mask\" GetLargestComponent \"$initial_mask\"" "largest_component"; then
        log_formatted "ERROR" "Failed to get largest component."
        rm -rf "$temp_dir"
        return 1
    fi

    # 4. Morphological operations for mask refinement
    log_message "Step 4a: Dilating mask"
    if ! execute_with_logging "ImageMath 3 \"$refined_mask\" MD \"$largest_component_mask\" 4" "mask_refinement_dilate"; then
        log_formatted "ERROR" "Mask dilation failed."
        rm -rf "$temp_dir"
        return 1
    fi

    log_message "Step 4b: Eroding mask to refine boundaries"
    if ! execute_with_logging "ImageMath 3 \"$refined_mask\" ME \"$refined_mask\" 4" "mask_refinement_erode"; then
        log_formatted "ERROR" "Mask erosion failed."
        rm -rf "$temp_dir"
        return 1
    fi

    log_message "Step 4c: Filling holes in the final mask"
    if ! execute_with_logging "ImageMath 3 \"$mask_file\" FillHoles \"$refined_mask\"" "mask_refinement_fill"; then
        log_formatted "ERROR" "Mask hole filling failed."
        rm -rf "$temp_dir"
        return 1
    fi

    # 5. Create brain-extracted image by multiplying the corrected image with the final mask
    log_message "Step 5: Applying final mask to create brain-extracted image"
    if ! execute_with_logging "ImageMath 3 \"$brain_file\" m \"$n4_corrected\" \"$mask_file\"" "apply_mask"; then
        log_formatted "ERROR" "Failed to create brain-extracted image."
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_formatted "SUCCESS" "ANTs template-free brain extraction completed successfully."
    rm -rf "$temp_dir"
    return 0

  # Fallback to FSL BET if ANTs tools are not available
  elif command -v bet &> /dev/null; then
    log_formatted "WARNING" "ANTs tools not found. Falling back to FSL BET."
    
    log_message "Using FSL BET for brain extraction on: $input_file"
    if execute_with_logging "fsl_bet" \
      bet "$input_file" "$brain_file" -m -f 0.5; then
      # Rename the generated mask to match the expected output filename
      local bet_mask="${output_prefix}BrainExtractionBrain_mask.nii.gz"
      if [ -f "$bet_mask" ]; then
        mv "$bet_mask" "$mask_file"
      fi
      log_formatted "SUCCESS" "FSL BET completed successfully."
      return 0
    else
      log_formatted "ERROR" "FSL BET failed."
      return 1
    fi
  else
    log_formatted "ERROR" "Neither ANTs core tools nor FSL BET are available for brain extraction."
    return 1
  fi
}

export -f apply_transform perform_brain_extraction
