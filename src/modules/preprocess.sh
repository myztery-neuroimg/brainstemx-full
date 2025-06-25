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

# Function to standardize image orientation to radiological (RAS/LPS)
standardize_orientation() {
    local input_file="$1"
    
    # Redirect all logging to ensure clean stdout for command substitution
    {
        # Validate input file
        if ! validate_nifti "$input_file" "Input file for orientation standardization"; then
            log_formatted "ERROR" "Invalid input file for orientation: $input_file"
            return $ERR_DATA_CORRUPT
        fi
        
        local basename=$(basename "$input_file" .nii.gz)
        local output_dir=$(create_module_dir "oriented")
        local output_file=$(get_output_path "oriented" "$basename" "_oriented")
        
        log_message "Checking and standardizing orientation: $input_file"
        
        # Check current orientation
        local current_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
        log_message "Current orientation: $current_orient"
        
        # If orientation is neurological, convert to radiological
        if [[ "$current_orient" == "NEUROLOGICAL" ]]; then
            log_message "Converting from NEUROLOGICAL to RADIOLOGICAL orientation"
            
            # Use fslswapdim to flip left-right (convert neurological to radiological)
            fslswapdim "$input_file" -x y z "$output_file"
            
            if [ $? -ne 0 ] || [ ! -f "$output_file" ]; then
                log_formatted "ERROR" "Failed to convert orientation"
                return 1
            fi
            
            # Set orientation to radiological
            if ! fslorient -forceradiological "$output_file"; then
                log_formatted "ERROR" "Failed to set radiological orientation for: $output_file"
                return $ERR_PREPROC
            fi

            log_message "Saved to: $output_file"
            
        elif [[ "$current_orient" == "RADIOLOGICAL" ]]; then
            log_message "Image already in RADIOLOGICAL orientation, copying as-is"
            # Create symbolic link to avoid unnecessary copying
            cp -Rp "$(realpath "$input_file")" "$output_file"
            #ln -sf "$(realpath "$input_file")" "$output_file"
            
            # Ensure it's marked as radiological
            fslorient -forceradiological "$output_file" 2>/dev/null || true
            
        else
            log_formatted "WARNING" "Unknown orientation '$current_orient', NOT assuming correct and proceeding"
            return 1
            #cp -Rp "$(realpath "$input_file")" "$output_file"
            #ln -sf "$(realpath "$input_file")" "$output_file"
            #fslorient -forceradiological "$output_file" 2>/dev/null || true
        fi

            # Check and FIX sform/qform matrix issues
            local sform_elements=($(fslorient -getsform "$output_file"))
            local qform_elements=($(fslorient -getqform "$output_file"))

            # Fix corrupted or missing spatial matrices
            if [[ ${#sform_elements[@]} -ne 16 ]] || [[ "${sform_elements[0]}" == "0" && "${sform_elements[5]}" == "0" && "${sform_elements[10]}" == "0" ]]; then
                log_message "Fixing corrupted spatial matrices by rebuilding from image geometry"
                
                # Reset matrices and rebuild from image geometry
                local temp_fixed="${output_file%.nii.gz}_temp_fixed.nii.gz"
                if fslreorient2std "$output_file" "$temp_fixed"; then
                    mv "$temp_fixed" "$output_file"
                    fslorient -forceradiological "$output_file"
                    log_message "✓ Spatial matrices rebuilt and fixed"
                else
                    log_formatted "ERROR" "Failed to fix spatial matrices"
                    rm -f "$temp_fixed"
                    return $ERR_PREPROC
                fi
            fi

          # Check and FIX anisotropic voxels
          log_message "Checking fslval $output_file pixdim1 pixdim2 pixdim3"

          local px="$(fslval $output_file pixdim1)"
          local py="$(fslval $output_file pixdim2)"
          local pz="$(fslval $output_file pixdim3)"
          
          local max_dim=$(echo "scale=2; if($px>$py && $px>$pz) $px; else if($py>$pz) $py; else $pz" | bc -l)
          local min_dim=$(echo "scale=2; if($px<$py && $px<$pz) $px; else if($py<$pz) $py; else $pz" | bc -l)
          local aniso_ratio=$(echo "scale=2; $max_dim / $min_dim" | bc -l)

          # CONFIG
          if [ "$RESAMPLE_TO_ISOTROPIC" == "true" ]; then
            # Actually FIX anisotropic voxels by resampling
            if (( $(echo "$aniso_ratio > 2.0" | bc -l) )); then
                log_message "Fixing anisotropic voxels (${px}x${py}x${pz}mm) by resampling to isotropic"
                
                local target_res="$min_dim"
                local temp_resampled="${output_file%.nii.gz}_temp_resampled.nii.gz"
                
                if flirt -in "$output_file" -ref "$output_file" -out "$temp_resampled" -applyisoxfm "$target_res" -interp spline; then
                    mv "$temp_resampled" "$output_file"
                    log_message "✓ Resampled to isotropic ${target_res}mm voxels"
                else
                    log_formatted "ERROR" "Failed to resample anisotropic voxels"
                    rm -f "$temp_resampled"
                    return $ERR_PREPROC
                fi
            fi
          fi

          log_message "✓ All spatial properties fixed: orientation, matrices, and voxel isotropy"
          log_message "Output at $output_file"

        # Validate output
        if ! validate_nifti "$output_file" "Orientation-standardized image"; then
            log_formatted "ERROR" "Output validation failed: $output_file"
            return $ERR_DATA_CORRUPT
        fi
        
        # Verify final orientation
        local final_orient=$(fslorient -getorient "$output_file" 2>/dev/null || echo "UNKNOWN")
        log_message "Final orientation: $final_orient"
        
    } >&2  # Redirect all logging in this block to stderr
    
    # Echo the output file path to stdout (this is what gets captured)
    echo "$output_file"
    return 0
}

# Function to process Rican NLM denoising
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
  DENOISE_BINARY="DenoiseImage"
  if ! command -v "$DENOISE_BINARY" &> /dev/null; then
    log_formatted "WARNING" "$DENOISE_BINARY not available - using FSL SUSAN for denoising"
    
    # Use FSL SUSAN (structure-preserving spatial smoothing)
    if command -v susan &> /dev/null; then
      log_message "Using FSL SUSAN for structure-preserving denoising..."
      
      # Calculate brightness threshold (typically 10-25% of mean intensity)
      local mean_intensity=$(fslstats "$file" -M)
      local brightness_threshold=$(echo "scale=0; $mean_intensity * 0.15" | bc -l)
      
      # SUSAN parameters: input, brightness_threshold, spatial_size, dimensionality, use_median, n_usans, output
      susan "$file" "$brightness_threshold" 2.0 3 1 0 "$output_file"
      
      if [ -f "$output_file" ]; then
        log_message "✓ FSL SUSAN denoising completed"
        echo "$output_file"
        return 0
      else
        log_formatted "ERROR" "FSL SUSAN denoising failed"
        return 1
      fi
    else
      log_formatted "WARNING" "FSL SUSAN not available - skipping denoising"
      log_message "Creating symbolic link to original file instead of denoising"
      # Create a symbolic link to the original file so downstream processes work
      ln -sf "$(realpath "$file")" "$output_file"
      echo "$output_file"
      return 0
    fi
  fi
  
  log_message "Rician NLM denoising: $file"
  
  # Determine ANTs bin path
  local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
  
  # Set threading for antsDenoiseImage (uses ITK threading)
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${ANTS_THREADS:-32}"
  
  # Execute Rician NLM denoising using enhanced ANTs command execution
  execute_ants_command "rician_nlm_denoising" "Rician Non-Local Means denoising for sharper bias fields and reduced false clusters" \
    "$DENOISE_BINARY" \
    -d 3 \
    -i "$file" \
    -o "$output_file" \
    -n Rician \
    -v 1
  
  local denoise_status=$?
  if [ $denoise_status -ne 0 ]; then
    log_formatted "ERROR" "Rician NLM denoising failed with status $denoise_status for: $file"
    log_formatted "WARNING" "Falling back to using original file without denoising"
    ln -sf "$(realpath $file)" "$output_file"
    echo "$output_file"
    return 1
  fi
  
  # Validate output file
  if ! validate_nifti "$output_file" "Rician NLM denoised image"; then
    log_formatted "ERROR" "Denoised image validation failed: $output_file"
    log_formatted "WARNING" "Falling back to using original file"
    ln -sf "$(realpath $file)" "$output_file"
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
    N4_CONVERGENCE="0.000001"
    REG_METRIC_CROSS_MODALITY="MI"
  else
    log_message "Optimizing for 1.5T field strength ($FIELD_STRENGTH T)"
    # 1.5T adjustments
    N4_CONVERGENCE="0.000005"
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

  log_message "N4 bias correction with orientation standardization and Rician NLM denoising: $file"
  
  # Step 1: Standardize orientation FIRST to avoid downstream issues
  local oriented_file=$(standardize_orientation "$file")
  local orient_status=$?
  if [ $orient_status -ne 0 ] || [ ! -f "$oriented_file" ]; then
    log_formatted "ERROR" "Orientation standardization failed for: $file (status: $orient_status)"
    return $ERR_PREPROC
  fi
  
  log_message "Using orientation-standardized image: $oriented_file"
  
  # Step 2: Apply Rician NLM denoising on oriented image
  local denoised_file=$(process_rician_nlm_denoising "$oriented_file")
  local denoise_status=$?
  denoised_file="$RESULTS_DIR/denoised/${basename}_oriented_denoised.nii.gz"
  if [ $denoise_status -ne 0 ] || [ ! -f "$denoised_file" ]; then
    log_formatted "ERROR" "Rician NLM denoising failed for: $file (status: $denoise_status file: $denoised_file)"
    return $ERR_PREPROC
  fi
  
  log_message "Denoised file:  $denoised_file created"
  log_message "Using denoised image for improved N4 correction: $denoised_file"
  
  # Generate brain mask output paths (using denoised image)
  local brain_prefix="${output_dir}/${basename}_"
  local brain_mask="${brain_prefix}BrainExtractionMask.nii.gz"
  
  # Brain extraction for a better mask (using denoised image for better extraction)
  if ! extract_brain "$denoised_file" "$brain_prefix"; then
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
  export -f process_n4_correction process_rician_nlm_denoising get_n4_parameters standardize_orientation
  export -f log_message log_formatted validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  export -f log_diagnostic execute_with_logging execute_ants_command
  
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
export -f standardize_orientation
export -f process_rician_nlm_denoising
export -f get_n4_parameters
export -f optimize_ants_parameters
export -f process_n4_correction
export -f run_parallel_n4_correction

log_message "Preprocessing module (orientation + denoising + N4) loaded"
