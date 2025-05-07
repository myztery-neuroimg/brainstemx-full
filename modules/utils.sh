#!/usr/bin/env bash
#
# utils.sh - Utility functions for the brain MRI processing pipeline
#

# Create a wrapper function to execute ANTs commands with controlled output
execute_ants_command() {
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
        tail -n 3 "$filtered_log" | while read -r line; do
            log_message "  $line"
        done
    else
        log_formatted "ERROR" "ANTs command failed with status $status"
        log_message "Error summary (last 5 lines):"
        tail -n 5 "$filtered_log" | while read -r line; do
            log_formatted "ERROR" "  $line"
        done
    fi
    
    return $status
}

# Export functions
export -f execute_ants_command

log_message "Utilities module loaded"