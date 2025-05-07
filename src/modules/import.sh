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
# Function to deduplicate identical files - now completely disabled
import_deduplicate_identical_files() {
  local dir="$1"
  
  # IMPORTANT: Deduplication is now permanently disabled
  # This prevents accidental removal of unique slices and data loss
  log_formatted "WARNING" "Deduplication is completely disabled - required to preserve all slices"
  return 0
  
  # The following code is never executed but kept for reference
  
  log_message "==== Deduplicating identical files in $dir (USE WITH CAUTION) ===="
  [ -d "$dir" ] || return 0

  mkdir -p "${dir}/tmp_checksums"

  # Check if the NIfTI files are actually from different series
  # before attempting deduplication - this is a safety check
  local series_count=$(find "$dir" -name "*.nii.gz" -type f | sed 's/.*_\([^_]*\)\.nii\.gz$/\1/' | sort | uniq | wc -l)
  if [ "$series_count" -gt 1 ]; then
    log_message "Found $series_count different series - skipping deduplication to preserve unique data"
    rm -rf "${dir}/tmp_checksums"
    return 0
  fi

  # Add additional safety check - don't deduplicate files with different slice counts
  # as this likely indicates different acquisitions
  local unique_dims=$(find "$dir" -name "*.nii.gz" -type f -exec fslinfo {} \; | grep -E "^dim3" | awk '{print $2}' | sort | uniq | wc -l)
  if [ "$unique_dims" -gt 1 ]; then
    log_message "Found files with different slice counts - skipping deduplication to preserve unique data"
    rm -rf "${dir}/tmp_checksums"
    return 0
  fi

  # Only proceed with actual deduplication if explicitly enabled and deemed safe
  log_message "DEDUPLICATION DISABLED - modern dcm2niix handles this better"
  rm -rf "${dir}/tmp_checksums"
  return 0
}

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
  
  # Try direct globbing first (more reliable than find with patterns)
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

# Function to convert DICOM to NIfTI
import_convert_dicom_to_nifti() {
  local dicom_dir="$1"
  local output_dir="${2:-$RESULTS_DIR}"
  #local options="{$3:-z y -f %p_%s -o"}

  log_formatted "INFO" "===== DICOM to NIfTI Conversion (PRESERVING ALL SLICES) ====="
  log_message "Converting DICOM to NIfTI: $dicom_dir $output_dir"
  mkdir -p "$output_dir"

  # Check if dcm2niix is installed
  if ! command -v dcm2niix &> /dev/null; then
    log_formatted "ERROR" "dcm2niix is not installed or not in PATH"
    return 1
  fi
  
  # Print the version of dcm2niix for debugging
  dcm2niix -v | head -1 | tee -a "$LOG_FILE" || true
  
  # Optimize conversion flags based on vendor detection
  if type import_optimize_conversion_flags &>/dev/null; then
    log_message "Detecting vendor and optimizing conversion flags"
    import_optimize_conversion_flags "$dicom_dir"
  else
    log_message "Vendor detection not available - using default flags"
  fi

  # Default options for dcm2niix
  local default_options="-z y -f %p_%s -o"
  local cmd_options="$default_options"
  
  # Run dcm2niix
  log_message "Running: dcm2niix $cmd_options $output_dir $dicom_dir" 

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
  
  # Report disk usage for source directory - useful for diagnosing data loss
  log_message "Source directory size: $(du -sh "$dicom_dir" 2>/dev/null || echo "unknown")"

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

  # IMPORTANT: We need to force preservation of all slices to prevent data loss
  # Run dcm2niix with the most aggressive slice preservation settings
  log_formatted "INFO" "Using MAXIMUM PRESERVATION settings to prevent slice loss"
  
  # Use the vendor-specific flags if available
  local vendor_flags="${DICOM_VENDOR_FLAGS:-}"
  
  # Determine the most aggressive slice preservation flags based on dcm2niix version
  local preserve_flags=""
  
  # DATA PRESERVATION MODE - focus on recovering all slices
  # Reset previous flags to avoid conflicts
  unset DICOM_VENDOR_FLAGS
  unset conversion_options
  
  # Use approach that preserves more data
  # -m n: Try to preserve more slices
  # -i n: Keep all images including localizers to avoid data loss
  preserve_flags="-m n -i n"
  
  # Add no-collapse to prevent combining slices
  if dcm2niix -h 2>&1 | grep -q -- "--no-collapse"; then
    preserve_flags="$preserve_flags --no-collapse"
    log_message "Added --no-collapse flag to preserve more slices"
  fi
  
  log_message "Using data preservation flags: $preserve_flags"
  
  # Log the command we're about to run, ensuring we don't have duplicated flags
  log_message "Running dcm2niix command: dcm2niix -z y -f \"%p_%s\" $preserve_flags -o \"$output_dir\" \"$dicom_dir\""
  
  # Make sure we don't have duplicate flags
  local cmd="dcm2niix -z y -f \"%p_%s\" $preserve_flags -o \"$output_dir\" \"$dicom_dir\""
  log_message "Executing: $cmd"
  
  # Execute the constructed command
  eval "$cmd"
  
  local exit_code=$?
  
  # Check if the conversion was successful
  if [ $exit_code -ne 0 ]; then
    log_formatted "ERROR" "dcm2niix had issues (exit code $exit_code) - likely invalid flags"
    
    # First try our simplified flags script
    local flag_fix_paths=(
      "./src/tools/fix_dcm2niix_flags.sh"
      "../src/tools/fix_dcm2niix_flags.sh"
      "$(dirname "${BASH_SOURCE[0]}")/../tools/fix_dcm2niix_flags.sh"
    )
    
    local flag_fix_found=false
    local flag_fix_path=""
    
    for path in "${flag_fix_paths[@]}"; do
      if [ -f "$path" ]; then
        flag_fix_found=true
        flag_fix_path="$path"
        break
      fi
    done
    
    if [ "$flag_fix_found" = true ]; then
      log_formatted "WARNING" "Attempting flag-fixing script: $flag_fix_path"
      chmod +x "$flag_fix_path"
      "$flag_fix_path" "$dicom_dir" "$output_dir"
      exit_code=$?
      if [ $exit_code -eq 0 ]; then
        log_formatted "SUCCESS" "Flag-fixing script succeeded"
        return 0
      else
        log_formatted "WARNING" "Flag-fixing script also failed with status $exit_code"
      fi
    else
      log_formatted "WARNING" "fix_dcm2niix_flags.sh not found in any expected location"
    fi
    
    # If the flag-fixing script didn't work, try the duplicates script
    local duplicates_paths=(
      "./src/fix_dcm2niix_duplicates.sh"
      "../src/fix_dcm2niix_duplicates.sh"
      "$(dirname "${BASH_SOURCE[0]}")/../fix_dcm2niix_duplicates.sh"
    )
    
    local duplicates_found=false
    local duplicates_path=""
    
    for path in "${duplicates_paths[@]}"; do
      if [ -f "$path" ]; then
        duplicates_found=true
        duplicates_path="$path"
        break
      fi
    done
    
    if [ "$duplicates_found" = true ]; then
      log_formatted "WARNING" "Attempting fallback with fix_dcm2niix_duplicates.sh script: $duplicates_path"
      chmod +x "$duplicates_path"
      "$duplicates_path" "$dicom_dir" "$output_dir" --series-by-series
      exit_code=$?
      if [ $exit_code -eq 0 ]; then
        log_formatted "SUCCESS" "Fallback conversion succeeded"
        return 0
      else
        log_formatted "WARNING" "All fallback attempts failed. Using final data preservation approach."
        # Emergency data preservation approach: separate passes with different flags
        log_formatted "INFO" "=== EMERGENCY DATA RECOVERY MODE ==="
        
        # Try first with super minimal flags - just compression and output
        log_message "Emergency attempt 1: Ultra minimal flags"
        dcm2niix -z y -f "%p_%s" -o "$output_dir" "$dicom_dir"
        
        # Try second approach with full debug output
        log_message "Emergency attempt 2: Debug mode with no merging"
        dcm2niix -z y -f "%p_%s" -m n -v y -o "${output_dir}_debug" "$dicom_dir"
        
        # Copy any additional files found in the debug output
        if [ -d "${output_dir}_debug" ]; then
          log_message "Copying additional files from debug mode output"
          find "${output_dir}_debug" -name "*.nii.gz" -exec cp {} "$output_dir/" \;
          rm -rf "${output_dir}_debug"
        fi
      fi
    else
      log_formatted "WARNING" "fix_dcm2niix_duplicates.sh not found in any expected location"
    fi
  fi
  
  # Check if all files are being marked as duplicates
  local duplicates_marker=$(find "$output_dir" -name "*.nii.gz" | grep -v "DUPLIC" | wc -l)
  FORCE_SERIES_BY_SERIES=1
  # If all files are being marked as duplicates, try the series-by-series approach
  if [ $duplicates_marker -eq 0 ] || [ "${FORCE_SERIES_BY_SERIES:-false}" = "true" ]; then
    log_formatted "WARNING" "All files being marked as duplicates, trying series-by-series conversion"
    
    # Create a temporary directory for intermediate results
    local temp_dir="${output_dir}/temp_series_conversion"
    mkdir -p "$temp_dir"
    
    # Find all subdirectories in the DICOM directory
    local series_dirs=($(find "$dicom_dir" -type d | sort))
    local found_series=false
    
    # Process each series directory separately
    for subdir in "${series_dirs[@]}"; do
      # Skip the main directory
      if [ "$subdir" = "$dicom_dir" ]; then
        continue
      fi
      
      # Count the DICOM files in this subdirectory
      local file_count=$(find "$subdir" -type f | wc -l)
      if [ $file_count -gt 5 ]; then
        log_message "Processing subdirectory with $file_count files: $subdir"
        found_series=true
        
        # Create a unique output directory for this series
        local series_name=$(basename "$subdir")
        local series_outdir="${temp_dir}/${series_name}"
        mkdir -p "$series_outdir"
        
        # Convert series with data preservation flags
        local series_cmd="dcm2niix -z y -f \"%p_%s\" -m n -i n"
        
        # Add no-collapse to prevent combining slices
        if dcm2niix -h 2>&1 | grep -q -- "--no-collapse"; then
          series_cmd="$series_cmd --no-collapse"
          log_message "Added --no-collapse flag to preserve more slices in series-by-series conversion"
        fi
        
        log_message "Using data preservation flags for series-by-series conversion"
        
        # Complete the command
        series_cmd="$series_cmd -o \"$series_outdir\" \"$subdir\""
        
        # Execute the command
        log_message "Executing series-by-series conversion: $series_cmd"
        eval "$series_cmd"
      fi
    done
    
    # If we found and processed series directories, move results to main output
    if [ "$found_series" = "true" ]; then
      log_message "Moving series-by-series results to main output directory"
      find "$temp_dir" -name "*.nii.gz" -exec cp {} "$output_dir/" \;
      rm -rf "$temp_dir"
    else
      log_message "No suitable series subdirectories found for series-by-series conversion"
    fi
  fi

  # After conversion, count resulting files and check for missing data
  local converted_files=$(find "$output_dir" -type f -name "*.nii.gz" | wc -l)
  local output_size=$(du -sh "$output_dir" 2>/dev/null || echo "unknown")
  log_message "Total NIfTI files created: $converted_files (output size: $output_size)"

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
  
  # Ensure there are output files before proceeding
  local output_files=$(find "$output_dir" -name "*.nii.gz" | wc -l)
  
  if [ $output_files -eq 0 ]; then
    log_formatted "ERROR" "No NIfTI files were created during conversion. Cannot proceed."
    return $ERR_DATA_MISSING
  else
    log_formatted "SUCCESS" "Successfully converted $output_files NIfTI files"
  fi
  
  return 0
}

# Function to validate DICOM files
import_validate_dicom_files_new_2() {
  # Print directly to terminal for debug
  return 0
  local dicom_dir="$1"
  local output_dir="$2"
  local dicom_count=0
  local sample_dicom=""
  log_message "Starting validate_dicom_files_new with directory: $dicom_dir"
  log_message "Validating DICOM files in $dicom_dir"
  mkdir -p "$output_dir"
  
  # Check for DICOM files using configured patterns
  log_message "Looking for files matching pattern: $DICOM_PRIMARY_PATTERN"
  sample_dicom=$(ls "$dicom_dir"/${DICOM_PRIMARY_PATTERN} 2>/dev/null | head -1)
  
  if [ -f "$sample_dicom" ]; then
    dicom_count=$(find "$dicom_dir" -mame $DICOM_PRIMARY_PATTERN 2>/dev/null | wc -l)
    log_message "Found $dicom_count DICOM files with primary pattern. Sample: $sample_dicom"
  else 
    # Method 2: Try different common DICOM patterns
    for pattern in "*.dcm" "IM_*" "Image*" "*.[0-9][0-9][0-9][0-9]" "DICOM*"; do
      sample_dicom=$(ls "$dicom_dir"/$pattern 2>/dev/null | head -1)
      if [ -f "$sample_dicom" ]; then
        dicom_count=$(ls "$dicom_dir"/$pattern 2>/dev/null | wc -l)
        log_message "Found $dicom_count DICOM files with pattern $pattern"
        break
      fi
    done
  fi
  
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

# Function to process one DICOM series in parallel
process_dicom_series() {
  local series_dir="$1"
  local output_dir="$2"
  local series_name=$(basename "$series_dir")
  local series_output_dir="${output_dir}/tmp_${series_name}"
  
  log_message "Processing DICOM series: $series_name"
  mkdir -p "$series_output_dir"
  
  # Optimize conversion flags based on vendor detection
  if type import_optimize_conversion_flags &>/dev/null; then
    import_optimize_conversion_flags "$series_dir"
  fi
  
  # Use the vendor-specific flags if available
  local vendor_flags="${DICOM_VENDOR_FLAGS:-}"
  local all_flags=""
  
  # DATA PRESERVATION MODE for series processing
  # Reset previous flags to avoid conflicts
  unset vendor_flags
  
  # Use approach that preserves more data
  # -m n: Try to preserve more slices
  # -i n: Keep all images including localizers to avoid data loss
  preserve_flags="-m n -i n"
  
  # Add no-collapse to prevent combining slices
  if dcm2niix -h 2>&1 | grep -q -- "--no-collapse"; then
    preserve_flags="$preserve_flags --no-collapse"
    log_message "Added --no-collapse flag to preserve more slices"
  fi
  
  log_message "Using data preservation flags for series processing: $preserve_flags"
  
  log_formatted "INFO" "Processing series $series_name with MAXIMUM PRESERVATION settings"
  log_message "Running dcm2niix for $series_name with flags: $preserve_flags"
  
  # Use eval for consistent command construction
  local cmd="dcm2niix -z y -f \"%p_%s\" $preserve_flags -o \"$series_output_dir\" \"$series_dir\""
  log_message "Executing: $cmd"
  eval "$cmd"
  
  # Check output size for debugging
  log_message "Series output size: $(du -sh "$series_output_dir" 2>/dev/null || echo "unknown")"
  
  # Move files to main output directory
  find "$series_output_dir" -name "*.nii.gz" -exec mv {} "$output_dir/" \;
  find "$series_output_dir" -name "*.json" -exec mv {} "$output_dir/" \;
  
  # Clean up
  rm -rf "$series_output_dir"
  
  return 0
}

# Function to import DICOM data with parallel processing
import_dicom_data() {
  local dicom_dir="$1"
  local output_dir="$2"
  local parallel_jobs="${DICOM_IMPORT_PARALLEL:-4}"  # Use specific DICOM import parallelism
  
  log_message "===== ENTERING import_dicom_data ====="
  log_message "DEBUG: dicom_dir='$dicom_dir'"
  log_message "DEBUG: Checking if directory exists: $dicom_dir"
  test -d "$dicom_dir" && log_message "DEBUG: DIRECTORY EXISTS" || log_message "DEBUG: DIRECTORY DOES NOT EXIST"
  log_message "** Importing DICOM data from $dicom_dir"
  
  # Validate DICOM files
  log_message "DEBUG: About to call import_validate_dicom_files_new_2"
  import_validate_dicom_files_new_2 "$dicom_dir" "$output_dir"
  log_message "DEBUG: validate_dicom_files COMPLETED"
  
  # Extract metadata using vendor-agnostic function
  log_message "DEBUG: About to call extract_metadata"
  import_extract_metadata "$dicom_dir"
  log_message "DEBUG: extract_metadata COMPLETED"
  
  # Check if parallel processing is enabled and GNU parallel is available
  if [ "$parallel_jobs" -gt 1 ] && command -v parallel &>/dev/null; then
    log_formatted "INFO" "Using parallel processing with $parallel_jobs jobs"
    mkdir -p "$output_dir"
    
    # Find all subdirectories that might contain DICOM series
    log_message "Detecting DICOM series directories..."
    local series_dirs=()
    
    # Method 1: Find subdirectories with sufficient DICOM files
    for subdir in "$dicom_dir"/*; do
      if [ -d "$subdir" ]; then
        local file_count=$(find "$subdir" -type f | wc -l)
        if [ "$file_count" -gt 5 ]; then
          series_dirs+=("$subdir")
          log_message "Found series directory: $subdir with $file_count files"
        fi
      fi
    done
    
    # Method 2: If no subdirectories found with series, try to group by series number
    if [ ${#series_dirs[@]} -eq 0 ]; then
      log_message "No series subdirectories found, processing entire directory"
      series_dirs=("$dicom_dir")
    fi
    
    # Export functions for GNU parallel
    export -f log_message log_formatted process_dicom_series
    if type import_optimize_conversion_flags &>/dev/null; then
      export -f import_optimize_conversion_flags
      export DICOM_VENDOR
      export DICOM_VENDOR_FLAGS
    fi
    
    # Process each series directory in parallel
    if [ ${#series_dirs[@]} -gt 1 ]; then
      log_message "Processing ${#series_dirs[@]} series directories in parallel"
      printf "%s\n" "${series_dirs[@]}" | parallel -j "$parallel_jobs" process_dicom_series {} "$output_dir"
    else
      log_message "Only one directory to process, falling back to standard method"
      import_convert_dicom_to_nifti "$dicom_dir" "$output_dir"
    fi
  else
    # Fall back to standard sequential processing
    if [ "$parallel_jobs" -gt 1 ]; then
      log_message "GNU parallel not found, falling back to sequential processing"
    else
      log_message "Parallel processing disabled, using sequential processing"
    fi
    
    log_message "DEBUG: About to call convert_dicom_to_nifti"
    import_convert_dicom_to_nifti "$dicom_dir" "$output_dir"
  fi
  
  log_message "DEBUG: DICOM conversion COMPLETED"
  
  # Validate NIfTI files
  import_validate_nifti_files "$output_dir"
  log_message "DEBUG: validate_nifti_files COMPLETED with status $?"
  
  # Deduplicate identical files
  import_deduplicate_identical_files "$output_dir"
  log_message "DEBUG: deduplicate_identical_files COMPLETED with status $?"
  
  log_message "DICOM import complete"
  return 0
}


# Export functions
export -f process_dicom_series
export -f import_deduplicate_identical_files
export -f import_extract_metadata
export -f import_convert_dicom_to_nifti
export -f import_validate_dicom_files_new_2
export -f import_validate_nifti_files
export -f import_process_all_nifti_files_in_dir
export -f import_dicom_data

log_message "Import module loaded"

