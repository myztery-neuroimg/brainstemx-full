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
        execute_ants_command "apply_transform" "Applying transform with ANTs" \
            antsApplyTransforms -d 3 -i "${input_file}" -r "${ref_file}" -o "${output_file}" \
            -n "${ants_interp}" -t "${transform_file}"
    else
        log_message "Applying transform with FLIRT: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -init "${transform_file}" \
            -out "${output_file}" -interp "${interp}"
    fi
}
export -f apply_transform
