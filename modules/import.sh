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

# Function to deduplicate identical files
deduplicate_identical_files() {
  local dir="$1"
  log_message "==== Deduplicating identical files in $dir ===="
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
    if [ ${#allfiles[@]} -gt 1 ]; then
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
extract_siemens_metadata() {
  local dicom_dir="$1"
  log_message "dicom_dir: $dicom_dir"
  [ -e "$dicom_dir" ] || return 0

  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"

  log_message "Extracting Siemens MAGNETOM Sola metadata..."

  local first_dicom
  first_dicom=$(find "$dicom_dir" -name "Image*" -type f | head -1)
  if [ -z "$first_dicom" ]; then
    log_message "No DICOM files found for metadata extraction."
    return 1
  fi

  mkdir -p "$(dirname "$metadata_file")"
  echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file"

  # Path to the external Python script
  local python_script="./extract_dicom_metadata.py"
  if [ ! -f "$python_script" ]; then
    log_message "Python script not found at: $python_script"
    return 1
  fi
  chmod +x "$python_script"

  log_message "Extracting metadata with Python script..."
  if command -v timeout &> /dev/null; then
    timeout 30s python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log"
    local exit_code=$?
    if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
      log_message "Python script timed out. Using default values."
    elif [ $exit_code -ne 0 ]; then
      log_message "Python script failed (exit $exit_code). See python_error.log"
    else
      mv "$metadata_file".tmp "$metadata_file"
      log_message "Metadata extracted successfully"
    fi
  else
    # If 'timeout' isn't available, do a manual background kill approach
    python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log" &
    local python_pid=$!
    for i in {1..30}; do
      if ! kill -0 $python_pid 2>/dev/null; then
        # Process finished
        wait $python_pid
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
          mv "$metadata_file".tmp "$metadata_file"
          log_message "Metadata extracted successfully"
        else
          log_message "Python script failed (exit $exit_code)."
        fi
        break
      fi
      sleep 1
      if [ $i -eq 30 ]; then
        kill $python_pid 2>/dev/null || true
        log_message "Script took too long. Using default values."
      fi
    done
  fi
  log_message "Metadata extraction complete"
  return 0
}

# Function to convert DICOM to NIfTI
convert_dicom_to_nifti() {
  local dicom_dir="$1"
  local output_dir="$2"
  local options="${3:-}"

  log_message "Converting DICOM to NIfTI: $dicom_dir -> $output_dir"
  mkdir -p "$output_dir"

  # Check if dcm2niix is installed
  if ! command -v dcm2niix &> /dev/null; then
    log_formatted "ERROR" "dcm2niix is not installed or not in PATH"
    return 1
  fi

  # Default options for dcm2niix
  local default_options="-z y -f %p_%s -o"
  local cmd_options="${options:-$default_options}"

  # Run dcm2niix
  log_message "Running: dcm2niix $cmd_options $output_dir $dicom_dir"
  dcm2niix $cmd_options "$output_dir" "$dicom_dir"
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log_formatted "ERROR" "dcm2niix failed with exit code $exit_code"
    return 1
  fi

  log_message "DICOM to NIfTI conversion complete"
  return 0
}

# Function to validate DICOM files
validate_dicom_files() {
  local dicom_dir="$1"
  local output_dir="${2:-$RESULTS_DIR/validation/dicom}"
  
  log_message "Validating DICOM files in $dicom_dir"
  mkdir -p "$output_dir"
  
  # Count DICOM files
  local dicom_count=$(find "$dicom_dir" -type f -name "*.dcm" | wc -l)
  if [ "$dicom_count" -eq 0 ]; then
    log_formatted "WARNING" "No DICOM files found in $dicom_dir"
    return 1
  fi
  
  log_message "Found $dicom_count DICOM files"
  
  # Check for common DICOM headers
  local sample_dicom=$(find "$dicom_dir" -type f -name "*.dcm" | head -1)
  if [ -n "$sample_dicom" ]; then
    log_message "Checking DICOM headers in $sample_dicom"
    if command -v dcmdump &> /dev/null; then
      dcmdump "$sample_dicom" > "$output_dir/sample_dicom_headers.txt"
    elif command -v gdcmdump &> /dev/null; then
      gdcmdump "$sample_dicom" > "$output_dir/sample_dicom_headers.txt"
    else
      log_formatted "WARNING" "dcmdump or gdcmdump not found, skipping header check"
    fi
  fi
  
  return 0
}

# Function to validate NIfTI files
validate_nifti_files() {
  local nifti_dir="$1"
  local output_dir="${2:-$RESULTS_DIR/validation/nifti}"
  
  log_message "Validating NIfTI files in $nifti_dir"
  mkdir -p "$output_dir"
  
  # Count NIfTI files
  local nifti_count=$(find "$nifti_dir" -type f -name "*.nii.gz" | wc -l)
  if [ "$nifti_count" -eq 0 ]; then
    log_formatted "WARNING" "No NIfTI files found in $nifti_dir"
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
        log_formatted "WARNING" "$nifti_file has suspicious dimension: $dim"
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
process_all_nifti_files_in_dir() {
  local input_dir="$1"
  local output_dir="$2"
  local process_func="$3"
  shift 3
  local process_args=("$@")
  
  log_message "Processing all NIfTI files in $input_dir"
  mkdir -p "$output_dir"
  
  # Find all NIfTI files
  local nifti_files=($(find "$input_dir" -name "*.nii.gz" -type f))
  if [ ${#nifti_files[@]} -eq 0 ]; then
    log_formatted "WARNING" "No NIfTI files found in $input_dir"
    return 1
  fi
  
  log_message "Found ${#nifti_files[@]} NIfTI files to process"
  
  # Process each file
  for nifti_file in "${nifti_files[@]}"; do
    local basename=$(basename "$nifti_file" .nii.gz)
    log_message "Processing $basename"
    
    # Call the processing function with the file and additional arguments
    "$process_func" "$nifti_file" "${process_args[@]}"
    
    # Check if processing was successful
    if [ $? -ne 0 ]; then
      log_formatted "WARNING" "Processing failed for $basename"
    else
      log_message "Processing complete for $basename"
    fi
  done
  
  log_message "Finished processing all NIfTI files"
  return 0
}

# Function to import DICOM data
import_dicom_data() {
  local dicom_dir="${1:-$SRC_DIR}"
  local output_dir="${2:-$EXTRACT_DIR}"
  
  log_message "Importing DICOM data from $dicom_dir"
  
  # Validate DICOM files
  validate_dicom_files "$dicom_dir"
  
  # Extract metadata
  extract_siemens_metadata "$dicom_dir"
  
  # Convert DICOM to NIfTI
  convert_dicom_to_nifti "$dicom_dir" "$output_dir"
  
  # Validate NIfTI files
  validate_nifti_files "$output_dir"
  
  # Deduplicate identical files
  deduplicate_identical_files "$output_dir"
  
  log_message "DICOM import complete"
  return 0
}

# Export functions
export -f deduplicate_identical_files
export -f extract_siemens_metadata
export -f convert_dicom_to_nifti
export -f validate_dicom_files
export -f validate_nifti_files
export -f process_all_nifti_files_in_dir
export -f import_dicom_data

log_message "Import module loaded"