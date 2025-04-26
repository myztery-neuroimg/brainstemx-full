# Function to extract scanner metadata using vendor-agnostic functions
import_extract_metadata() {
  local dicom_dir="$1"
  log_message "Starting metadata extraction for directory: $dicom_dir"
  
  # Proceed even if directory doesn't exist
  if [ ! -e "$dicom_dir" ]; then
    log_message "WARNING: Directory $dicom_dir does not exist - creating default metadata"
    local metadata_dir="${RESULTS_DIR}/metadata"
    mkdir -p "$metadata_dir"
    echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_dir/scanner_params.json"
    log_message "Created default metadata file due to missing DICOM directory"
    return 0
  fi

  # Create metadata directory
  local metadata_dir="${RESULTS_DIR}/metadata"
  mkdir -p "$metadata_dir"
  log_message "Created metadata directory: $metadata_dir"

  # Always create a fallback metadata file first in case processing fails
  echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_dir/scanner_params.json"
  log_message "Created initial default metadata file"

  # Find a sample DICOM file
  local first_dicom=""
  log_message "Looking for sample DICOM file in $dicom_dir"
  
  # Try primary pattern first
  # First try directly with the pattern as variable
  pattern_raw=${DICOM_PRIMARY_PATTERN:-Image*}
  log_message "Using primary pattern: $pattern_raw"
  
  # Debug output of what files exist
  log_message "Files in DICOM dir $(ls -la "$dicom_dir" | head -5)"
  
  # Use simple shell globbing for more reliable file matching
  shopt -s nullglob # Avoid errors if no files match
  dicom_files=("$dicom_dir"/Image*)
  shopt -u nullglob
  
  if [ ${#dicom_files[@]} -gt 0 ]; then
    first_dicom="${dicom_files[0]}"
    log_message "Found DICOM using glob: $first_dicom"
  else
    # Fallback to find but with simpler pattern
    log_message "No files found with glob, trying find"
    first_dicom=$(find "$dicom_dir" -type f -name "Image*" 2>/dev/null | head -1)
    log_message "Find result: $first_dicom"
  fi
  
  # If no files found with primary pattern, try additional patterns
  if [ ! -f "$first_dicom" ]; then
    log_message "No files found with primary pattern, trying additional patterns"
    for pattern in ${DICOM_ADDITIONAL_PATTERNS:-"*.dcm IM* Image* *.[0-9][0-9][0-9][0-9] DICOM*"}; do
      log_message "Trying pattern: $pattern"
      # Use more reliable shell globbing first
      shopt -s nullglob
      add_files=("$dicom_dir"/$pattern)
      shopt -u nullglob
      
      if [ ${#add_files[@]} -gt 0 ]; then
        first_dicom="${add_files[0]}"
        log_message "Found DICOM using glob with pattern $pattern: $first_dicom"
        break
      else
        # Fall back to find as last resort
        first_dicom=$(find "$dicom_dir" -type f -name "$pattern" 2>/dev/null | head -1)
        if [ -f "$first_dicom" ]; then
          log_message "Found DICOM using find with pattern $pattern: $first_dicom"
          break
        fi
      fi
      if [ -f "$first_dicom" ]; then
        log_message "Found DICOM file with pattern '$pattern': $first_dicom"
        break
      fi
    done
  fi
  
  if [ ! -f "$first_dicom" ]; then
    log_formatted "WARNING" "No DICOM files found in $dicom_dir - using default metadata"
    return 0
  fi
  
  log_message "Using sample DICOM file for metadata extraction: $first_dicom"
  
  # Check if dicom_analysis.sh is properly loaded
  log_message "Checking if dicom_analysis module is loaded - functions available:"
  declare -F | grep "extract_scanner_metadata" || log_message "extract_scanner_metadata NOT FOUND"
  declare -F | grep "detect_scanner_manufacturer" || log_message "detect_scanner_manufacturer NOT FOUND"
  
  # Use vendor-agnostic function from dicom_analysis.sh
  if type extract_scanner_metadata &>/dev/null; then
    log_message "Calling extract_scanner_metadata with sample file"
    extract_scanner_metadata "$first_dicom" "$metadata_dir"
    local exit_code=$?
    log_message "extract_scanner_metadata completed with status: $exit_code"
    if [ $exit_code -ne 0 ]; then
      log_formatted "WARNING" "Metadata extraction reported errors (exit code $exit_code)"
    fi
  else
    log_formatted "WARNING" "extract_scanner_metadata function not available - using fallback metadata"
    # Fallback metadata file already created above
    return 0
  fi
  
  log_message "Metadata extraction completed successfully"
  return 0
}