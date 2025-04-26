#!/usr/bin/env bash
#
# import_vendor_specific.sh - Vendor-specific DICOM import functions
#
# This module contains functions for working with vendor-specific DICOM files:
# - Siemens metadata extraction - extracts scanner parameters to optimize processing
# - Philips metadata extraction - extracts scanner parameters to optimize processing
# - Other vendor-specific DICOM functionality
#
# The metadata extracted by these functions is used by the pipeline to:
# 1. Optimize processing parameters based on field strength (1.5T vs 3T)
# 2. Determine if sequences are 3D isotropic for proper processing
# 3. Apply scanner-model specific optimizations (e.g., for MAGNETOM Sola)
#

# Unset any existing functions to prevent conflicts
unset import_extract_siemens_metadata
unset import_extract_philips_metadata

# Function to extract Siemens-specific metadata using the Python script
# This metadata is crucial for optimizing the pipeline parameters based on scanner characteristics
import_extract_siemens_metadata() {
    local dicom_dir="$1"
    local output_dir="${2:-${RESULTS_DIR}/metadata}"
    
    log_message "Extracting Siemens-specific metadata from DICOM directory: $dicom_dir"
    
    # Create metadata directory
    mkdir -p "$output_dir"
    
    # Find a sample DICOM file
    local sample_dicom=""
    
    # Use shell globbing to find a DICOM file
    shopt -s nullglob
    dicom_files=("$dicom_dir"/Image*)
    shopt -u nullglob
    
    if [ ${#dicom_files[@]} -gt 0 ]; then
        sample_dicom="${dicom_files[0]}"
        log_message "Found sample DICOM file for metadata extraction: $sample_dicom"
    else
        # Try with different patterns
        for pattern in "*.dcm" "IM_*" "Image*" "*.[0-9][0-9][0-9][0-9]" "DICOM*"; do
            shopt -s nullglob
            alt_files=("$dicom_dir"/$pattern)
            shopt -u nullglob
            
            if [ ${#alt_files[@]} -gt 0 ]; then
                sample_dicom="${alt_files[0]}"
                log_message "Found sample DICOM file with pattern $pattern: $sample_dicom"
                break
            fi
        done
    fi
    
    if [ -z "$sample_dicom" ] || [ ! -f "$sample_dicom" ]; then
        log_formatted "WARNING" "No DICOM files found for Siemens metadata extraction"
        return 0  # Continue pipeline despite the warning
    fi
    
    # Call the Python script to extract metadata
    local output_file="$output_dir/siemens_params.json"
    
    log_message "Running Python metadata extraction script"
    
    # Check if Python script exists
    local script_path="$(dirname "${BASH_SOURCE[0]}")/extract_dicom_metadata.py"
    if [ ! -f "$script_path" ]; then
        log_formatted "ERROR" "Python script not found: $script_path"
        # Create a minimal fallback metadata file
        echo "{\"manufacturer\":\"SIEMENS\",\"source\":\"fallback-script-missing\"}" > "$output_file"
        return 0  # Continue pipeline despite the error
    fi
    
    # Run the Python script
    if ! python3 "$script_path" "$sample_dicom" "$output_file"; then
        log_formatted "WARNING" "Python metadata extraction failed"
        # Create a fallback metadata file
        echo "{\"manufacturer\":\"SIEMENS\",\"source\":\"fallback-script-failed\"}" > "$output_file"
    else
        log_message "Siemens metadata extraction completed successfully"
    fi
    
    # Display a message about how this metadata will be used
    log_message "Extracted scanner metadata will be used to optimize processing parameters"
    log_message "Field strength and scanner model information will influence registration and bias correction"
    
    return 0
}

# Function to extract Philips-specific metadata
import_extract_philips_metadata() {
    local dicom_dir="$1"
    local output_dir="${2:-${RESULTS_DIR}/metadata}"
    
    log_message "Extracting Philips-specific metadata from DICOM directory: $dicom_dir"
    
    # Implementation similar to Siemens but with Philips-specific patterns
    # For now, just calling the same Python script which handles both vendors
    import_extract_siemens_metadata "$dicom_dir" "$output_dir"
    
    return 0
}

# Export functions
export -f import_extract_siemens_metadata
export -f import_extract_philips_metadata

log_message "Vendor-specific import module loaded"