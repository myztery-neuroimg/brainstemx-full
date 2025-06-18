#!/usr/bin/env bash
#
# preprocess.sh - True preprocessing functions for the brain MRI processing pipeline
#
# This module contains:
# - Rician NLM denoising
# - N4 bias field correction
# - Parameter optimization
#
# This is now focused only on true preprocessing steps, with brain extraction
# and standardization moved to the brain_extraction.sh module for better modularity.
#

# Function to process Rician NLM denoising
process_rician_nlm_denoising() {
  local file="$1"
  
  # Validate input file
  if ! validate_nifti "$file" "Input file for Rician NLM denoising"; then
    log_formatted "ERROR" "Invalid input file for Rician NLM denoising: $file"
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$file" .nii.gz)
  local output_dir=$(create_module_dir "denoised")
  local output_file=$(get_output_path "denoised" "$basename" "_denoised")
  
  # Check if antsDenoiseImage is available
  if ! command -v antsDenoiseImage &> /dev/null; then
    log_formatted "WARNING" "antsDenoiseImage not available - skipping Rician denoising"
    log_message "Creating symbolic link to original file instead of denoising"
    # Create a symbolic link to the original file so downstream processes work
    ln -sf "$(realpath "$file")" "$output_file"
    echo "$output_file"
    return 0
  fi
  
  log_message "Rician NLM denoising: $file"
  
  # Determine ANTs bin path
  local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
  
  # Set threading for antsDenoiseImage (uses ITK threading)
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${ANTS_THREADS:-4}"
  
  # Execute Rician NLM denoising using enhanced ANTs command execution
  execute_ants_command "rician_nlm_denoising" "Rician Non-Local Means denoising for sharper bias fields and reduced false clusters" \
    antsDenoiseImage \
    -d 3 \
    -i "$file" \
    -o "$output_file" \
    -n Rician \
    -v 1
  
  local denoise_status=$?
  if [ $denoise_status -ne 0 ]; then
    log_formatted "ERROR" "Rician NLM denoising failed with status $denoise_status for: $file"
    log_formatted "WARNING" "Falling back to using original file without denoising"
    ln -sf "$(realpath "$file")" "$output_file"
    echo "$output_file"
    return 0
  fi
  
  # Validate output file
  if ! validate_nifti "$output_file" "Rician NLM denoised image"; then
    log_formatted "ERROR" "Denoised image validation failed: $output_file"
    log_formatted "WARNING" "Falling back to using original file"
    ln -sf "$(realpath "$file")" "$output_file"
  fi
  
  log_message "Saved denoised image: $output_file"
  
  # Return the path to the denoised file
  echo "$output_file"
  return 0
}

# Function to get N4 parameters
get_n4_parameters() {
  local file="$1"
  
  # Validate input file exists but don't stop on error
  if [ ! -f "$file" ]; then
    log_formatted "WARNING" "File not found for parameter determination: $file - using defaults"
  fi
  local iters="$N4_ITERATIONS"
  local conv="$N4_CONVERGENCE"
  local bspl="$N4_BSPLINE"
  local shrk="$N4_SHRINK"

  if [[ "$file" == *"FLAIR"* ]]; then
    iters="$N4_ITERATIONS_FLAIR"
    conv="$N4_CONVERGENCE_FLAIR"
    bspl="$N4_BSPLINE_FLAIR"
    shrk="$N4_SHRINK_FLAIR"
  fi
  echo "$iters" "$conv" "$bspl" "$shrk"
}

# Function to optimize ANTs parameters
optimize_ants_parameters() {
  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  
  create_module_dir "metadata"
  
  if [ ! -f "$metadata_file" ]; then
    return
  fi

  if command -v python3 &> /dev/null; then
    # Python script to parse JSON fields
    cat > "${RESULTS_DIR}/metadata/parse_json.py" <<EOF
import json, sys
try:
    with open(sys.argv[1],'r') as f:
        data = json.load(f)
    field_strength = data.get('fieldStrength',3)
    print(f"FIELD_STRENGTH={field_strength}")
    model = data.get('modelName','')
    print(f"MODEL_NAME={model}")
    is_sola = ('MAGNETOM Sola' in model)
    print(f"IS_SOLA={'1' if is_sola else '0'}")
except:
    print("FIELD_STRENGTH=3")
    print("MODEL_NAME=Unknown")
    print("IS_SOLA=0")
EOF
    eval "$(python3 "${RESULTS_DIR}/metadata/parse_json.py" "$metadata_file")"
  else
    FIELD_STRENGTH=3
    MODEL_NAME="Unknown"
    IS_SOLA=0
  fi

  if (( $(echo "$FIELD_STRENGTH > 2.5" | bc -l) )); then
    log_message "Optimizing for 3T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
    N4_CONVERGENCE="0.000001"
    REG_METRIC_CROSS_MODALITY="MI"
  else
    log_message "Optimizing for 1.5T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
    # 1.5T adjustments
    N4_CONVERGENCE="0.0000005"
    N4_BSPLINE=200
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.3]"
    ATROPOS_MRF="[0.15,1x1x1]"
  fi

  if [ "$IS_SOLA" = "1" ]; then
    log_message "Applying specific optimizations for MAGNETOM Sola"
    REG_TRANSFORM_TYPE=3
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"
    N4_BSPLINE=200
  fi
  log_message "ANTs parameters optimized from metadata"
}

# Function to process N4 bias field correction
process_n4_correction() {
  local file="$1"
  
  # Validate input file
  if ! validate_nifti "$file" "Input file for N4 correction"; then
    log_formatted "ERROR" "Invalid input file for N4 correction: $file"
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$file" .nii.gz)
  local output_file=$(get_output_path "bias_corrected" "$basename" "_n4")
  local output_dir=$(get_module_dir "bias_corrected")
  
  # Ensure output directory exists
  if ! mkdir -p "$output_dir"; then
    log_formatted "ERROR" "Failed to create output directory: $output_dir"
    return $ERR_FILE_CREATION
  fi

  log_message "N4 bias correction with Rician NLM denoising: $file"
  
  # Step 1: Apply Rician NLM denoising first
  local denoised_file=$(process_rician_nlm_denoising "$file")
  local denoise_status=$?
  if [ $denoise_status -ne 0 ] || [ ! -f "$denoised_file" ]; then
    log_formatted "ERROR" "Rician NLM denoising failed for: $file (status: $denoise_status)"
    return $ERR_PREPROC
  fi
  
  log_message "Using denoised image for improved N4 correction: $denoised_file"
  
  # Generate brain mask output paths (using denoised image)
  local brain_prefix="${output_dir}/${basename}_"
  local brain_mask="${brain_prefix}BrainExtractionMask.nii.gz"
  
  # Brain extraction for a better mask (using denoised image for better extraction)
  if ! perform_brain_extraction "$denoised_file" "$brain_prefix"; then
    local brain_status=$?
    log_formatted "ERROR" "Brain extraction failed for denoised image: $denoised_file (status: $brain_status)"
    return $ERR_PREPROC
  fi
  
  # Check if brain mask was created
  if [ ! -f "$brain_mask" ]; then
    log_formatted "ERROR" "Brain extraction failed to create mask: $brain_mask"
    return $ERR_PREPROC
  fi

  # Get sequence-specific parameters
  local params=($(get_n4_parameters "$file"))
  local iters=${params[0]}
  local conv=${params[1]}
  local bspl=${params[2]}
  local shrk=${params[3]}

  # Run N4 bias correction on denoised image with our enhanced ANTs command function
  log_message "Running N4 bias correction on denoised image"
  
  # Determine ANTs bin path
  local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
  
  # Check if N4BiasFieldCorrection is available
  if ! command -v N4BiasFieldCorrection &> /dev/null; then
    log_formatted "WARNING" "N4BiasFieldCorrection not available - skipping bias field correction"
    log_message "Creating symbolic link to denoised file instead of N4 correction"
    # Create a symbolic link to the denoised file so downstream processes work
    ln -sf "$(realpath "$denoised_file")" "$output_file"
    log_message "Saved (no bias correction): $output_file"
    return 0
  fi
  
  # Execute N4 using enhanced ANTs command execution (on denoised image)
  execute_ants_command "n4_bias_correction" "Non-uniform intensity (bias field) correction on denoised image" \
    N4BiasFieldCorrection \
    -d 3 \
    -i "$denoised_file" \
    -x "$brain_mask" \
    -o "$output_file" \
    -b "[$bspl]" \
    -s "$shrk" \
    -c "[$iters,$conv]"

  local n4_status=$?
  if [ $n4_status -ne 0 ]; then
    log_formatted "ERROR" "N4 bias correction failed with status $n4_status for: $denoised_file"
    log_formatted "WARNING" "Falling back to using denoised file without bias correction"
    ln -sf "$(realpath "$denoised_file")" "$output_file"
    log_message "Saved (no bias correction): $output_file"
    return 0
  fi

  # Validate output file
  if ! validate_nifti "$output_file" "N4 bias-corrected image"; then
    log_formatted "ERROR" "N4 bias-corrected image validation failed: $output_file"
    return $ERR_DATA_CORRUPT
  fi
  
  log_message "Saved bias-corrected image (denoised + N4): $output_file"
  return 0
}

# Function to run N4 bias field correction in parallel
run_parallel_n4_correction() {
  local input_dir="${1:-$EXTRACT_DIR}"
  local pattern="${2:-*.nii.gz}"
  local jobs="${3:-$PARALLEL_JOBS}"
  local max_depth="${4:-1}"
  
  log_message "Running N4 bias correction with Rician NLM denoising in parallel on files matching '$pattern' in $input_dir"
  
  # Ensure output directories exist
  create_module_dir "denoised"
  create_module_dir "bias_corrected"
  
  # Export required functions for parallel execution
  export -f process_n4_correction process_rician_nlm_denoising get_n4_parameters
  export -f log_message log_formatted validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  export -f log_diagnostic execute_with_logging perform_brain_extraction execute_ants_command
  
  # Run in parallel using the common function
  run_parallel "process_n4_correction" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  if [ $status -ne 0 ]; then
    log_formatted "ERROR" "Parallel N4 bias correction with denoising failed with status $status"
    return $status
  fi
  
  log_formatted "SUCCESS" "Completed parallel N4 bias correction with Rician NLM denoising"
  return 0
}

# Export functions
export -f process_rician_nlm_denoising
export -f get_n4_parameters
export -f optimize_ants_parameters
export -f process_n4_correction
export -f run_parallel_n4_correction

log_message "Preprocessing module (denoising + N4) loaded"
