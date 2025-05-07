#!/usr/bin/env bash
#
# fix_dcm2niix_flags.sh - Fix dcm2niix flag handling issues
#
# This script provides a simplified version of the dcm2niix command with 
# minimal flags to avoid parsing issues.

set -e  # Exit on error

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Include logging functions if available
if [ -f "$PROJECT_ROOT/src/modules/environment.sh" ]; then
    source "$PROJECT_ROOT/src/modules/environment.sh"
else
    # Minimal logging implementation
    log_message() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }
    
    log_formatted() {
        local level="$1"
        local message="$2"
        echo "[$level] $message"
    }
fi

log_formatted "INFO" "===== DCM2NIIX Flag Fixing Tool ====="

# Function to run dcm2niix with simplified flags
run_dcm2niix_simplified() {
    local dicom_dir="$1"
    local output_dir="$2"
    local preservation_mode="${3:-false}"
    
    if [ ! -d "$dicom_dir" ]; then
        log_formatted "ERROR" "DICOM directory does not exist: $dicom_dir"
        return 1
    fi
    
    mkdir -p "$output_dir"
    
    # Simplified flags that should work on all versions
    # -z y: Save compressed nifti
    # -f: Output filename
    # -o: Output directory
    # -m n: Merge 2D slices in same series
    # -i y: Ignore derived, localizer, etc.
    
    log_formatted "INFO" "Running dcm2niix with simplified flags"
    
    # First attempt - most basic flags
    log_message "Attempt 1: Using minimal flags"
    local attempt1_cmd="dcm2niix -z y -f \"%p_%s\" -m n -i y -o \"$output_dir\" \"$dicom_dir\""
    log_message "Command: $attempt1_cmd"
    
    eval "$attempt1_cmd"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_formatted "SUCCESS" "First attempt successful"
        return 0
    fi
    
    log_formatted "WARNING" "First attempt failed with status $exit_code, trying second approach"
    
    # Second attempt - try with --no-collapse if available
    if dcm2niix -h 2>&1 | grep -q "no-collapse"; then
        log_message "Attempt 2: Adding --no-collapse flag"
        local attempt2_cmd="dcm2niix -z y -f \"%p_%s\" -m n -i y --no-collapse -o \"$output_dir\" \"$dicom_dir\""
        log_message "Command: $attempt2_cmd"
        
        eval "$attempt2_cmd"
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            log_formatted "SUCCESS" "Second attempt successful"
            return 0
        fi
        
        log_formatted "WARNING" "Second attempt failed with status $exit_code"
    else
        log_message "Skipping second attempt: --no-collapse not supported"
    fi
    
    # Special attempt - super minimal flags (just -z y)
    log_message "Attempt 2.5: Using super minimal flags (just -z y)"
    local minimal_cmd="dcm2niix -z y -f \"%p_%s\" -o \"$output_dir\" \"$dicom_dir\""
    log_message "Command: $minimal_cmd"
    
    eval "$minimal_cmd"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_formatted "SUCCESS" "Super minimal flags attempt successful"
        return 0
    fi
    
    log_formatted "WARNING" "Super minimal flags attempt failed with status $exit_code"
    
    # Third attempt - try with only absolute minimal flags
    log_message "Attempt 3: Using absolute minimal flags"
    local attempt3_cmd="dcm2niix -z y -f \"%p_%s\" -o \"$output_dir\" \"$dicom_dir\""
    log_message "Command: $attempt3_cmd"
    
    eval "$attempt3_cmd"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_formatted "SUCCESS" "Third attempt successful with minimal flags"
        return 0
    fi
    
    log_formatted "ERROR" "All attempts failed. Please try manual conversion."
    return 1
}

# Check for dcm2niix
if ! command -v dcm2niix &>/dev/null; then
    log_formatted "ERROR" "dcm2niix not found. Please install dcm2niix."
    exit 1
fi

# Get dcm2niix version
dcm2niix_version=$(dcm2niix -v 2>&1 | head -n 1 || echo "Unknown")
log_message "Found dcm2niix version: $dcm2niix_version"

# Run with arguments if provided
if [ $# -ge 2 ]; then
    run_dcm2niix_simplified "$1" "$2"
    exit $?
else
    log_message "Usage: $0 <dicom_dir> <output_dir>"
    log_message "Example: $0 /path/to/dicom /path/to/output"
    exit 1
fi