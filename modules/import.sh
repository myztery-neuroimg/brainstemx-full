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
unset import_extract_siemens_metadata
unset import_convert_dicom_to_nifti
unset import_validate_dicom_files_new_2
unset import_validate_nifti_files
unset import_process_all_nifti_files_in_dir
unset import_import_dicom_data
export RESULTS_DIR="../mri_results"
# Function to deduplicate identical files
import_deduplicate_identical_files() {
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
  echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file"

  # Path to the external Python script
  # Updated path to the correct location in the modules directory
  local python_script="/Users/davidbrewster/Documents/workspace/2025/brainMRI-ants-e2e-pipeline/extract_dicom_metadata.py"
  if [ ! -f "$python_script" ]; then
    # Try a few other common locations
    log_message "Python script not found at: $python_script, trying alternatives..."
    for alt_path in "modules/extract_dicom_metadata.py" "extract_dicom_metadata.py" "../modules/extract_dicom_metadata.py" "./extract_dicom_metadata.py"; do
      echo "DEBUG: Checking for script at: $alt_path" > /dev/stderr
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
  
  # Run dcm2niix
  log_message "Running: dcm2niix $cmd_options $output_dir $dicom_dir" 

  # Run dcm2niix
  dcm2niix -z y -f "%p_%s" -o "$output_dir" "$dicom_dir"
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log_formatted "WARNING" "dcm2niix had issues (exit code $exit_code)"
  fi

  log_message "DICOM to NIfTI conversion complete"
  return 0
}

# Function to validate DICOM files
import_validate_dicom_files_new_2() {
  # Print directly to terminal for debug
  return 0
  local dicom_dir="$1"
  local output_dir="$2"
  DICOM_PRIMARY_PATTERN='Image"*"'
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
    log_message "WARNING: No DICOM files found in $dicom_dir"
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
 import_process_all_nifti_files_in_dir() {
  local input_dir="$1"
  local output_dir="$2"
  local process_func="$3"
  shift 3
  local process_args=("$@")
  
  log_message "Processing all NIfTI files in $input_dir"
  mkdir -p "$output_dir"
  
  # Find all NIfTI files
  local nifti_files=($(find "$input_dir" -name "*.nii.gz" -type f))
  if [ $nifti_files[@] -eq 0 ]; then
    log_formatted "WARNING" "No NIfTI files found in $input_dir"
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
  local dicom_dir="$1"
  local output_dir="$2"
  echo "===== ENTERING import_dicom_data =====" > /dev/stderr
  echo "DEBUG: dicom_dir='$dicom_dir'" > /dev/stderr
  echo "DEBUG: Checking if directory exists: $dicom_dir" > /dev/stderr
  test -d "$dicom_dir" && echo "DEBUG: DIRECTORY EXISTS" > /dev/stderr || echo "DEBUG: DIRECTORY DOES NOT EXIST" > /dev/stderr
  log_message "** Importing DICOM data from $dicom_dir"
  
  # Validate DICOM files
  echo "DEBUG: About to call import_validate_dicom_files_new_2" > /dev/stderr
  import_validate_dicom_files_new_2 "$dicom_dir" "$output_dir"
  echo "DEBUG: validate_dicom_files COMPLETED" > /dev/stderr
  
  # Extract metadata
  echo "DEBUG: About to call extract_siemens_metadata" > /dev/stderr 
  import_extract_siemens_metadata "$dicom_dir"
  echo "DEBUG: extract_siemens_metadata COMPLETED" > /dev/stderr
  echo "DEBUG: About to call convert_dicom_to_nifti" > /dev/stderr
  
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
export -f import_extract_siemens_metadata
export -f import_convert_dicom_to_nifti
export -f import_validate_dicom_files_new_2
export -f import_validate_nifti_files
export -f import_process_all_nifti_files_in_dir
export -f import_dicom_data

log_message "Import module loaded"
