#!/usr/bin/env bash
#
# import.sh - Data import functions for the brain MRI processing pipeline
#
# This module contains:
# - DICOM import
# - DICOM metadata extraction
# - DICOM to NIfTI conversion
# - Deduplication
#
unset import_deduplicate_identical_files
unset import_extract_metadata
unset import_convert_dicom_to_nifti
unset import_validate_dicom_files_new_2
unset import_validate_nifti_files
unset import_process_all_nifti_files_in_dir
unset import_import_dicom_data
export RESULTS_DIR="../mri_results"

# Source the DICOM analysis module with improved error handling
log_message "Attempting to load dicom_analysis.sh module"
DICOM_ANALYSIS_LOADED=false

# First try to find the module
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
MODULE_PATHS=(
  "${SCRIPT_DIR}/dicom_analysis.sh"
  "./src/modules/dicom_analysis.sh"
  "../src/modules/dicom_analysis.sh"
  "./modules/dicom_analysis.sh"
  "../modules/dicom_analysis.sh"
)

# Also source vendor-specific import module
VENDOR_MODULE="${SCRIPT_DIR}/import_vendor_specific.sh"
if [ -f "$VENDOR_MODULE" ]; then
  log_message "Loading vendor-specific import module from $VENDOR_MODULE"
  source "$VENDOR_MODULE"
else
  log_formatted "WARNING" "Vendor-specific import module not found: $VENDOR_MODULE"
fi

# Source the import_extract_metadata.sh module
EXTRACT_MODULE="${SCRIPT_DIR}/import_extract_metadata.sh"
if [ -f "$EXTRACT_MODULE" ]; then
  log_message "Loading metadata extraction module from $EXTRACT_MODULE"
  source "$EXTRACT_MODULE"
else
  log_formatted "WARNING" "Metadata extraction module not found: $EXTRACT_MODULE"
fi

for path in "${MODULE_PATHS[@]}"; do
  if [ -f "$path" ]; then
    log_message "Found dicom_analysis.sh at: $path"
    if source "$path"; then
      log_message "Successfully loaded DICOM analysis module from $path"
      DICOM_ANALYSIS_LOADED=true
      break
    else
      log_formatted "WARNING" "Found but failed to source dicom_analysis.sh from $path"
    fi
  fi
done

if [ "$DICOM_ANALYSIS_LOADED" = false ]; then
  log_formatted "WARNING" "Could not load dicom_analysis.sh module - using fallback implementations"
  
  # Provide minimal implementations of key functions for fallback
  extract_scanner_metadata() {
    local dicom_file="$1"
    local output_dir="$2"
    log_formatted "WARNING" "Using fallback extract_scanner_metadata implementation"
    mkdir -p "$output_dir"
    echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\",\"source\":\"fallback\"}" > "$output_dir/scanner_params.json"
    return 0
  }
  export -f extract_scanner_metadata
fi
# Function to deduplicate identical files
import_deduplicate_identical_files() {
  local dir="$1"
  #log_message "==== Deduplicating identical files in $dir ===="
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
    if [ "${#allfiles[@]}" -gt 1 ]; then
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

# Function to extract Siemens metadata
import_extract_siemens_metadata() {
  local dicom_dir="$1"
  log_message "dicom_dir: $dicom_dir"
  log_message "Starting extract_siemens_metadata with directory: $dicom_dir"
  [ -e "$dicom_dir" ] || log_message "Directory $dicom_dir does not exist" && return 0

  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"

  log_message "Extracting Siemens MAGNETOM Sola metadata..."
  
  # Reference the file directly using the known path
  local  first_dicom=$(ls "$dicom_dir"/"${DICOM_PRIMARY_PATTERN}" | head -1)
  log_message "DEBUG: Using primary pattern: ${DICOM_PRIMARY_PATTERN}"
  
  test -f "$first_dicom" 
  if [ ! -z "$first_dicom" ]; then
    #echo "DEBUG: No DICOM files found with primary pattern, trying additional patterns..." > /dev/stderr
    for pattern in ${DICOM_ADDITIONAL_PATTERNS:-"*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"}; do
      first_dicom=$(find "$dicom_dir" -type f -name "$pattern" | head -1)
      [ -n "$first_dicom" ] && break
    done
  fi
  log_message "first_dicom extract: $first_dicom"

  mkdir -p "$(dirname $metadata_file)"
  log_message "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file" 

  # Path to the external Python script
  # Updated path to the correct location in the modules directory
  local python_script="../extract_dicom_metadata.py"
  if [ ! -f "$python_script" ]; then
    # Try a few other common locations
    log_message "Python script not found at: $python_script, trying alternatives..."
    for alt_path in "modules/extract_dicom_metadata.py" "extract_dicom_metadata.py" "../modules/extract_dicom_metadata.py" "./extract_dicom_metadata.py"; do
      log_message "DEBUG: Checking for script at: $alt_path" 
      if [ -f "$alt_path" ]; then
        python_script="$alt_path"
        log_message "Found script at: $python_script"
        break
      fi
    done
    if [ ! -f "$python_script" ]; then
      log_message "Python script not found, using dummy values"
      return 0
    fi
  fi
  chmod +x "$python_script"

  log_message "Extracting metadata with Python script..."
  timeout 30s python3 "$python_script" "$first_dicom" "$metadata_file".tmp >&2
  local exit_code=$?
  if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
    log_message "Python script timed out. Using default values."
    return 1
  elif [ $exit_code -ne 0 ]; then
    log_message "Python script failed (exit $exit_code). See python_error.log"
    return 1
  else
    mv "$metadata_file".tmp "$metadata_file"
    log_message "Metadata extracted successfully"
  fi
  log_message "Metadata extraction complete"
  return 0
}

# Function to convert DICOM to NIfTI
import_convert_dicom_to_nifti() {
  local dicom_dir="$1"
  local output_dir="${2:-$RESULTS_DIR}"
  #local options="{$3:-z y -f %p_%s -o"}

  log_message "Converting DICOM to NIfTI: $dicom_dir $output_dir"
  mkdir -p "$output_dir"

  # Check if dcm2niix is installed
  if ! command -v dcm2niix &> /dev/null; then
    log_formatted "ERROR" "dcm2niix is not installed or not in PATH"
    return 1
  fi

  # Default options for dcm2niix
  local default_options="-z y -f %p_%s -o"
  local cmd_options="$default_options"
  
  # Before conversion, count actual DICOM files using all patterns
  local total_dicom_files=0
  # First try primary pattern
  local primary_count=$(find "$dicom_dir" -type f -name "${DICOM_PRIMARY_PATTERN}" 2>/dev/null | wc -l)
  total_dicom_files=$primary_count
  
  # If primary pattern doesn't find anything, try alternative patterns
  if [ $total_dicom_files -eq 0 ]; then
    log_message "No files found with primary pattern, trying alternative patterns..."
    for pattern in ${DICOM_ADDITIONAL_PATTERNS:-"*.dcm IM* Image* *.[0-9][0-9][0-9][0-9] DICOM*"}; do
      local pattern_count=$(find "$dicom_dir" -type f -name "$pattern" 2>/dev/null | wc -l)
      total_dicom_files=$((total_dicom_files + pattern_count))
    done
  fi
  
  log_message "Total DICOM files found: $total_dicom_files"

  # Check if dcm2niix supports the exact_values flag
  local supports_exact_values=false
  if dcm2niix -h 2>&1 | grep -q "exact_values"; then
    supports_exact_values=true
    log_message "dcm2niix supports exact_values flag, will use for better slice handling"
  else
    log_message "dcm2niix does not support exact_values flag, using standard conversion"
  fi

  # Analyze DICOM headers using the vendor-agnostic module
  local sample_file=$(find "$dicom_dir" -type f -name "${DICOM_PRIMARY_PATTERN}" | head -1)
  local conversion_options=""
  
  if [ -n "$sample_file" ]; then
    log_message "Performing vendor-agnostic DICOM header analysis"
    
    if type analyze_dicom_header &>/dev/null; then
      # Use the new module functions if available
      analyze_dicom_header "$sample_file" "${LOG_DIR}/dicom_header_analysis.txt"
      
      # Check for empty fields that might cause grouping issues
      if type check_empty_dicom_fields &>/dev/null; then
        check_empty_dicom_fields "$sample_file"
      fi
      
      # Detect scanner manufacturer and get appropriate conversion options
      if type detect_scanner_manufacturer &>/dev/null && type get_conversion_recommendations &>/dev/null; then
        local manufacturer=$(detect_scanner_manufacturer "$sample_file")
        log_message "Detected scanner manufacturer: $manufacturer"
        
        conversion_options=$(get_conversion_recommendations "$manufacturer")
        log_message "Using recommended conversion options for $manufacturer: $conversion_options"
      fi
    else
      # Fallback to basic inspection if module functions not available
      log_message "DICOM analysis module not loaded, using basic inspection"
      if command -v dcmdump &>/dev/null; then
        log_message "Examining DICOM header fields:"
        dcmdump "$sample_file" | grep -E "(Series|Acquisition|Instance|Study)" | tee -a "$LOG_FILE"
      else
        log_message "dcmdump not available, skipping header inspection"
      fi
    fi
  fi

  # Run dcm2niix with appropriate options
  if $supports_exact_values; then
    if [ -n "$conversion_options" ]; then
      log_message "Running dcm2niix with vendor-specific options: $conversion_options"
      dcm2niix -z y -f "%p_%s" $conversion_options -o "$output_dir" "$dicom_dir"
    else
      log_message "Running dcm2niix with exact_values flag to prevent incorrect grouping of slices"
      dcm2niix -z y -f "%p_%s" --exact_values 1 -o "$output_dir" "$dicom_dir"
    fi
  else
    log_message "Running standard dcm2niix conversion"
    dcm2niix -z y -f "%p_%s" -o "$output_dir" "$dicom_dir"
  fi
  
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log_formatted "ERROR" "dcm2niix had issues (exit code $exit_code)"
  fi

  # After conversion, count resulting files and check for missing data
  local converted_files=$(find "$output_dir" -type f -name "*.nii.gz" | wc -l)
  log_message "Total NIfTI files created: $converted_files"

  # Check for discrepancies and provide detailed analysis
  local expected_ratio=0
  
  # Calculate expected slices per volume based on common MRI protocols
  if [ $total_dicom_files -gt 100 ]; then
    # Probably 3D acquisition - many slices per volume
    expected_ratio=100
  else
    # Probably 2D acquisition - fewer slices per volume
    expected_ratio=30
  fi
  
  # Compare actual vs expected ratio
  if (( total_dicom_files > converted_files * $expected_ratio )); then
    log_formatted "WARNING" "Significant mismatch between DICOM inputs ($total_dicom_files) and NIfTI outputs ($converted_files) - possible data loss"
    log_formatted "WARNING" "This may indicate that empty header fields are causing improper slice grouping"
    log_formatted "WARNING" "Consider using a different DICOM conversion tool or manually inspecting the data"
  elif (( total_dicom_files > converted_files * 10 )); then
    log_formatted "INFO" "Moderate mismatch between DICOM inputs ($total_dicom_files) and NIfTI outputs ($converted_files)"
    log_formatted "INFO" "This is expected for 3D acquisitions but verify outputs are complete"
  else
    log_formatted "SUCCESS" "Conversion ratio within expected range: $total_dicom_files DICOM files → $converted_files NIfTI files"
  fi

  log_message "DICOM to NIfTI conversion complete"
  return 0
}

# Function to validate DICOM files
import_validate_dicom_files_new_2() {
  # Print directly to terminal for debug (early return disabled to allow validation)
  # return 0
  local dicom_dir="$1"
  local output_dir="$2"
  # Use primary pattern from environment (modules/environment.sh)
  # export DICOM_PRIMARY_PATTERN='Image*'
  local dicom_count=0
  local sample_dicom=""
  log_message "Starting validate_dicom_files_new with directory: $dicom_dir"
  log_message "Validating DICOM files in $dicom_dir"
  mkdir -p "$output_dir"
  
  # Check for DICOM files using configured patterns
  log_message "Looking for files matching pattern: $DICOM_PRIMARY_PATTERN"
  #log_message $(find "$dicom_dir" -name ${DICOM_PRIMARY_PATTERN} -ls) 
  dicom_count=$(find "$dicom_dir" -name ${DICOM_PRIMARY_PATTERN} 2>/dev/null | wc -l )
  
  
  if [ $dicom_count -eq 0 ]; then
    log_message "ERROR: No DICOM files found in $dicom_dir"
    return 1
  fi
  
  log_message "Found $dicom_count DICOM files"

  return 0
  
}

# Function to validate NIfTI files
import_validate_nifti_files() {
  local nifti_dir="$1"
  local output_dir="${2:-$RESULTS_DIR/validation/nifti}"
  
  log_message "Validating NIfTI files in $nifti_dir"
  mkdir -p "$output_dir"
  
  # Count NIfTI files
  local nifti_count=$(find "$nifti_dir" -type f -name "*.nii.gz" | wc -l)
  if [ "$nifti_count" -eq 0 ]; then
    log_formatted "ERROR" "No NIfTI files found in $nifti_dir"
    return 1
  fi
  
  log_message "Found $nifti_count NIfTI files"
  
  # Check each NIfTI file
  local all_valid=true
  for nifti_file in $(find "$nifti_dir" -type f -name "*.nii.gz"); do
    log_message "Checking $nifti_file"
    
    # Check if file is readable
    if ! fslinfo "$nifti_file" &>/dev/null; then
      log_formatted "ERROR" "Failed to read $nifti_file"
      all_valid=false
      continue
    fi
    
    # Check dimensions
    local dims=$(fslinfo "$nifti_file" | grep -E "^dim[1-3]" | awk '{print $2}')
    for dim in $dims; do
      if [ "$dim" -le 1 ]; then
        log_formatted "ERROR" "$nifti_file has suspicious dimension: $dim"
        all_valid=false
        break
      fi
    done
  done
  
  if $all_valid; then
    log_message "All NIfTI files are valid"
    return 0
  else
    log_formatted "WARNING" "Some NIfTI files have issues"
    return 1
  fi
}

# Function to process all NIfTI files in a directory
 import_process_all_nifti_files_in_dir() {
  local input_dir="$1"
  local output_dir="$2"
  local process_func="$3"
  shift 3
  local process_args=("$@")
  
  log_formatted "INFO" "Processing all NIfTI files in $input_dir"
  mkdir -p "$output_dir"
  
  # Find all NIfTI files
  local nifti_files=($(find "$input_dir" -name "*.nii.gz" -type f))
  if [ $nifti_files[@] -eq 0 ]; then
    log_formatted "ERROR" "No NIfTI files found in $input_dir"
    return 1
  fi
  
  log_message "Found $nifti_files[@] NIfTI files to process"
  
  # Process each file
  for nifti_file in "$nifti_files[@]"; do
    local basename=$(basename "$nifti_file" .nii.gz)
    log_message "Processing $basename"
    
    # Call the processing function with the file and additional arguments
    "$process_func" "$nifti_file" "$process_args[@]"
    
    # Check if processing was successful
    if [ $? -ne 0 ]; then
      log_formatted "ERROR" "Processing failed for $basename"
    else
      log_message "Processing complete for $basename"
    fi
  done
  
  log_message "Finished processing all NIfTI files"
  return 0
}

# Function to import DICOM data
import_dicom_data() {
  local dicom_dir="$1"
  local output_dir="$2"
  log_message "===== ENTERING import_dicom_data =====" 
  log_message "DEBUG: dicom_dir='$dicom_dir'" 
  log_message "DEBUG: Checking if directory exists: $dicom_dir" 
  test -d "$dicom_dir" && log_message "DEBUG: DIRECTORY EXISTS" || log_message "DEBUG: DIRECTORY DOES NOT EXIST" 
  log_message "** Importing DICOM data from $dicom_dir"
  
  # Validate DICOM files
  log_message "DEBUG: About to call import_validate_dicom_files_new_2" 
  import_validate_dicom_files_new_2 "$dicom_dir" "$output_dir"
  log_message "DEBUG: validate_dicom_files COMPLETED" 
  
  # Extract metadata
  log_message "DEBUG: About to call extract_metadata"
  import_extract_metadata "$dicom_dir"
  log_message "DEBUG: extract_metadata COMPLETED"
  log_message "DEBUG: About to call convert_dicom_to_nifti" 
  
  # Convert DICOM to NIfTI
  import_convert_dicom_to_nifti "$dicom_dir" "$output_dir"
  
  # Validate NIfTI files
  import_validate_nifti_files "$output_dir"
  
  # Deduplicate identical files
  import_deduplicate_identical_files "$output_dir"
  
  log_message "DICOM import complete"
  return 0
}

# Export functions
export -f import_deduplicate_identical_files
export -f import_extract_metadata
export -f import_convert_dicom_to_nifti
export -f import_validate_dicom_files_new_2
export -f import_validate_nifti_files
export -f import_process_all_nifti_files_in_dir
export -f import_dicom_data

log_message "Import module loaded"
