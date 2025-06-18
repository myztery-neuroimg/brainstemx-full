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
  
  # Check if antsBrainExtraction.sh is available
  if ! command -v antsBrainExtraction.sh &> /dev/null; then
    log_formatted "WARNING" "antsBrainExtraction.sh not available - trying FSL BET as fallback"
    
    # Fallback to FSL BET
    if command -v bet &> /dev/null; then
      local brain_file="${output_prefix}BrainExtractionBrain.nii.gz"
      local mask_file="${output_prefix}BrainExtractionMask.nii.gz"
      
      log_message "Using FSL BET for brain extraction"
      bet "$input_file" "$brain_file" -m -f 0.5
      
      # BET creates mask with _mask suffix, rename it
      if [ -f "${brain_file%%.nii.gz}_mask.nii.gz" ]; then
        mv "${brain_file%%.nii.gz}_mask.nii.gz" "$mask_file"
      fi
      
      return $?
    else
      log_formatted "ERROR" "Neither antsBrainExtraction.sh nor BET available for brain extraction"
      return 1
    fi
  fi
  
  # Use ANTs brain extraction with available template
  local template_dir="${TEMPLATE_DIR:-/usr/local/fsl/data/standard}"
  local extraction_template="${template_dir}/${EXTRACTION_TEMPLATE:-MNI152_T1_1mm.nii.gz}"
  local probability_mask="${template_dir}/${PROBABILITY_MASK:-MNI152_T1_1mm_brain_mask.nii.gz}"
  
  # Check if templates exist
  if [ ! -f "$extraction_template" ]; then
    log_formatted "WARNING" "Template not found: $extraction_template - using without template"
    extraction_template=""
  fi
  
  if [ ! -f "$probability_mask" ]; then
    log_formatted "WARNING" "Probability mask not found: $probability_mask - using without mask"
    probability_mask=""
  fi
  
  # Build ANTs brain extraction command
  local cmd="antsBrainExtraction.sh -d 3 -a \"$input_file\" -o \"$output_prefix\""
  
  if [ -n "$extraction_template" ]; then
    cmd="$cmd -e \"$extraction_template\""
  fi
  
  if [ -n "$probability_mask" ]; then
    cmd="$cmd -m \"$probability_mask\""
  fi
  
  log_message "Running ANTs brain extraction: $cmd"
  eval "$cmd"
  
  return $?
}

export -f apply_transform perform_brain_extraction
