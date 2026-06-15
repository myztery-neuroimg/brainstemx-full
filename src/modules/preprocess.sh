#!/usr/bin/env bash
#
# preprocess.sh - True preprocessing functions for the brain MRI processing pipeline
#
# This module contains:
# - Orientation standardization (RAS/LPS) with header-heuristic fallback
# - Modality-aware denoising: T1/T2/FLAIR -> adaptive Rician NLM (ANTs
#   DenoiseImage; Manjon 2010), DWI -> MP-PCA (dwidenoise; Veraart 2016, via
#   dwi_preprocess.sh), SWI/TOF -> skipped
# - N4 bias-field correction (Tustison 2010) where field strength tunes the
#   b-spline mesh / spline distance (-b); FLAIR uses a gentler, lesion-aware
#   preset so diffuse lesion contrast is not absorbed into the bias field
#   (Valdes Hernandez 2016)
# - Metadata-driven parameter optimization
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

# Function to detect the modality of an image from its filename.
# Returns one of: T1, T2, FLAIR, DWI, SWI, TOF, UNKNOWN
# Detection is case-insensitive and intentionally conservative so that the
# default structural (T1/FLAIR) flow is never mis-routed.
detect_modality() {
  local file="$1"
  local name
  name=$(basename "$file")
  # Lowercase for case-insensitive matching
  local lname
  lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

  # Diffusion: DWI / DTI / diffusion / ADC / trace / b-value tags
  case "$lname" in
    *dwi*|*dti*|*diffusion*|*_adc*|*adc_*|*trace*|*bval*|*bvec*)
      echo "DWI"; return 0 ;;
  esac

  # Susceptibility-weighted / susceptibility / microbleed imaging
  case "$lname" in
    *swi*|*susceptib*|*_swan*|*swan_*|*venobold*|*mip_swi*)
      echo "SWI"; return 0 ;;
  esac

  # Time-of-flight / angiography
  case "$lname" in
    *tof*|*angio*|*_mra*|*mra_*|*time_of_flight*)
      echo "TOF"; return 0 ;;
  esac

  # FLAIR (check before generic T2 since FLAIR is a T2-weighted variant)
  case "$lname" in
    *flair*)
      echo "FLAIR"; return 0 ;;
  esac

  # T1-weighted (MPRAGE/SPGR/T1)
  case "$lname" in
    *t1*|*mprage*|*spgr*|*mp2rage*)
      echo "T1"; return 0 ;;
  esac

  # T2-weighted (SPACE/CISS/T2) — checked after FLAIR
  case "$lname" in
    *t2*|*space*|*ciss*)
      echo "T2"; return 0 ;;
  esac

  echo "UNKNOWN"
  return 0
}

# Modality-aware denoising dispatcher.
#
# Routes each file to the correct denoising method based on its modality:
#   - T1 / T2 / FLAIR  -> Rician Non-Local-Means (DenoiseImage), structural default
#   - DWI / diffusion  -> MP-PCA (dwidenoise) via the DWI module; NEVER NLM
#   - SWI / TOF / angio -> SKIP denoising by default (smears microbleeds/vessels)
#   - UNKNOWN          -> conservative default (NLM) unless DENOISE_DEFAULT_SKIP=true
#
# Behaviour is config-driven (see DENOISE_* / SWI_TOF_* / DWI_* vars in
# config/default_config.sh).  The function always echoes the resulting output
# file path to stdout (so callers can capture it) and logs which method was used.
dispatch_denoising() {
  local file="$1"
  local modality="${2:-}"

  # Validate input file
  if ! validate_nifti "$file" "Input file for denoising dispatch"; then
    log_formatted "ERROR" "Invalid input file for denoising dispatch: $file"
    return $ERR_DATA_CORRUPT
  fi

  # Auto-detect modality if not explicitly provided
  if [ -z "$modality" ]; then
    modality=$(detect_modality "$file")
  fi

  log_message "Denoising dispatch: file=$(basename "$file") modality=$modality"

  case "$modality" in
    DWI)
      log_formatted "INFO" "Routing DWI to MP-PCA (dwidenoise) — NLM is invalid for diffusion data"
      # Prefer the dedicated DWI denoise step (MP-PCA).  Degrade gracefully if
      # the DWI module / tool is unavailable.
      if command -v dwidenoise &> /dev/null && declare -F denoise_dwi_mppca &> /dev/null; then
        denoise_dwi_mppca "$file"
        return $?
      fi
      log_formatted "WARNING" "dwidenoise (MP-PCA) unavailable — skipping denoising for DWI (NLM is NOT a valid substitute)"
      _dispatch_denoise_passthrough "$file"
      return $?
      ;;
    SWI|TOF)
      if [ "${SWI_TOF_DENOISE_ENABLED:-false}" = "true" ]; then
        log_formatted "INFO" "SWI/TOF denoising explicitly enabled — applying gentle NLM (may smear microbleeds/small vessels)"
        process_rician_nlm_denoising "$file"
        return $?
      fi
      log_message "Skipping denoising for $modality (default) to preserve microbleeds / small vessels"
      _dispatch_denoise_passthrough "$file"
      return $?
      ;;
    T1|T2|FLAIR)
      log_message "Routing $modality to Rician NLM denoising"
      process_rician_nlm_denoising "$file"
      return $?
      ;;
    *)
      if [ "${DENOISE_DEFAULT_SKIP:-false}" = "true" ]; then
        log_formatted "WARNING" "Unknown modality for $(basename "$file") — skipping denoising (DENOISE_DEFAULT_SKIP=true)"
        _dispatch_denoise_passthrough "$file"
        return $?
      fi
      log_formatted "WARNING" "Unknown modality for $(basename "$file") — defaulting to Rician NLM (structural assumption)"
      process_rician_nlm_denoising "$file"
      return $?
      ;;
  esac
}

# Helper: produce a "denoised" output path that is a pass-through (symlink) of
# the input, used when denoising is intentionally skipped so that downstream
# stages which expect a *_denoised.nii.gz file continue to work unchanged.
_dispatch_denoise_passthrough() {
  local file="$1"
  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "denoised" >/dev/null
  local output_file
  output_file=$(get_output_path "denoised" "$basename" "_denoised")
  ln -sf "$(realpath "$file")" "$output_file"
  log_message "Denoising skipped — pass-through link created: $output_file"
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
#
# Emits four whitespace-separated fields in EXACTLY the order the N4 command in
# process_n4_correction() consumes them: "<iters> <conv> <bspl> <shrk>" where
#   iters = -c iteration counts (e.g. 100x100x100)
#   conv  = -c convergence threshold (stopping criterion)
#   bspl  = -b spline distance in mm (single isotropic scalar; see default_config.sh)
#   shrk  = -s shrink factor
# For FLAIR inputs (filename contains "FLAIR") it returns the GENUINELY gentler
# FLAIR preset (larger spline distance => smoother bias field + fewer iterations)
# so N4 does not absorb diffuse FLAIR lesion contrast into the bias field.
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
    # Gentler, lesion-safe FLAIR N4 (see N4_PRESET_FLAIR in default_config.sh).
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

  # Field-strength optimization acts on the N4 b-spline MESH SPACING (-b), NOT on
  # the convergence threshold. The convergence threshold is purely a STOPPING
  # criterion (the old 0.000001 vs 0.000005 split was cosmetic - both just
  # iterated to the cap), so we leave it at the single value already derived from
  # the quality preset (N4_CONVERGENCE) for BOTH field strengths. The real
  # field-strength lever is the spline distance (N4_BSPLINE, a single isotropic
  # spline distance in mm; see the N4 -b convention in default_config.sh):
  #   - 1.5T: weaker, smoother bias field -> COARSER mesh (LARGER spline distance)
  #   - 3T:   stronger, more spatially varying field -> FINER mesh (smaller dist.)
  if (( $(echo "$FIELD_STRENGTH > 2.5" | bc -l) )); then
    log_message "Optimizing for 3T field strength ($FIELD_STRENGTH T)"
    # 3T: ensure a FINER mesh to capture the stronger, more spatially varying
    # bias field. Only tighten if the preset distance is coarser than 120mm so we
    # never accidentally make 3T coarser than intended. The numeric guard keeps
    # this safe if N4_BSPLINE is ever empty or a non-scalar (e.g. a custom preset
    # missing the spline field) - we simply leave the preset value untouched.
    if [[ "$N4_BSPLINE" =~ ^[0-9]+$ ]] && (( $(echo "$N4_BSPLINE > 120" | bc -l) )); then
      N4_BSPLINE=120
    fi
    REG_METRIC_CROSS_MODALITY="MI"
  else
    log_message "Optimizing for 1.5T field strength ($FIELD_STRENGTH T)"
    # 1.5T adjustments: COARSER mesh => smoother bias field. 200 is a blessed
    # value, applied here CONSISTENTLY as an isotropic spline DISTANCE in mm.
    N4_BSPLINE=200
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.3]"
    ATROPOS_MRF="[0.15,1x1x1]"
  fi

  if [ "$IS_SOLA" = "1" ]; then
    log_message "Applying specific optimizations for MAGNETOM Sola"
    REG_TRANSFORM_TYPE=3
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"
    # Blessed 200mm spline distance for Sola (same -b convention as everywhere).
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
  
  # Step 2: Apply modality-aware denoising on oriented image.
  # The dispatcher routes T1/T2/FLAIR -> Rician NLM (unchanged behaviour),
  # DWI -> MP-PCA, and SWI/TOF -> skip.  For the structural T1/FLAIR inputs
  # that reach process_n4_correction today, this is identical to before.
  local denoised_file=$(dispatch_denoising "$oriented_file")
  local denoise_status=$?
  denoised_file="$RESULTS_DIR/denoised/${basename}_oriented_denoised.nii.gz"
  if [ $denoise_status -ne 0 ] || [ ! -f "$denoised_file" ]; then
    log_formatted "ERROR" "Denoising failed for: $file (status: $denoise_status file: $denoised_file)"
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

  # Assemble N4 arguments. -b is an isotropic spline DISTANCE in mm wrapped as
  # "[<dist>]" (single source-of-truth convention; see default_config.sh).
  local n4_args=(
    -d 3
    -i "$denoised_file"
    -x "$brain_mask"
    -o "$output_file"
    -b "[$bspl]"
    -s "$shrk"
    -c "[$iters,$conv]"
  )

  # OPTIONAL lesion-weight mask for FLAIR (two-pass workflow). N4's -w weight
  # image down-weights high-weight voxels during bias-field ESTIMATION, so a
  # lesion mask here keeps lesion contrast out of the estimated field.
  # Lesions are unknown at first preprocessing, so the intended workflow is:
  #   pass 1: N4_FLAIR_LESION_MASK="" -> gentler preset only (this same code)
  #   detect lesions on the pass-1 output (analysis.sh)
  #   pass 2: re-run with N4_FLAIR_LESION_MASK=<lesion weight in FLAIR space>
  # The weight image must already match the denoised/oriented FLAIR geometry.
  if [[ "$file" == *"FLAIR"* ]] && [ -n "${N4_FLAIR_LESION_MASK:-}" ]; then
    if [ -f "$N4_FLAIR_LESION_MASK" ]; then
      log_message "Applying FLAIR lesion weight mask to N4 (-w): $N4_FLAIR_LESION_MASK"
      n4_args+=(-w "$N4_FLAIR_LESION_MASK")
    else
      log_formatted "WARNING" "N4_FLAIR_LESION_MASK set but file not found: $N4_FLAIR_LESION_MASK - running N4 without weight image"
    fi
  fi

  # Execute N4 using enhanced ANTs command execution (on denoised image)
  execute_ants_command "n4_bias_correction" "Non-uniform intensity (bias field) correction on denoised image" \
    N4BiasFieldCorrection \
    "${n4_args[@]}"

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

# Modality-aware wrapper used by the parallel runner.
#
# This GUARDS the broad "*.nii.gz" pattern: even if the caller points the
# parallel runner at a directory that contains DWI/SWI/TOF images, those are
# NEVER routed through Rician NLM + structural N4 (which would smear microbleeds
# on SWI, small vessels on TOF, and inflate the noise floor on DWI).
#
#   - DWI       -> dedicated MP-PCA DWI path (run_dwi_preprocessing) if enabled
#                  + tools present; otherwise a clear non-fatal skip.
#   - SWI / TOF -> skipped (structural N4/NLM is inappropriate).
#   - T1/T2/FLAIR/UNKNOWN -> existing process_n4_correction (denoise via
#                  dispatch_denoising, then N4) — unchanged behaviour.
process_modality_aware_correction() {
  local file="$1"
  local modality
  modality=$(detect_modality "$file")

  log_message "Modality-aware correction: file=$(basename "$file") modality=$modality"

  case "$modality" in
    DWI)
      if [ "${PROCESS_DWI:-false}" = "true" ] && declare -F run_dwi_preprocessing &> /dev/null; then
        log_formatted "INFO" "Routing $(basename "$file") to dedicated DWI preprocessing (MP-PCA path)"
        run_dwi_preprocessing "$file"
        return $?
      fi
      log_formatted "WARNING" "Skipping DWI file in N4 runner: $(basename "$file") (structural N4/NLM is invalid for diffusion; enable PROCESS_DWI for the MP-PCA path)"
      return 0
      ;;
    SWI|TOF)
      log_formatted "WARNING" "Skipping $modality file in N4 runner: $(basename "$file") (structural N4/NLM would smear microbleeds/vessels)"
      return 0
      ;;
    *)
      process_n4_correction "$file"
      return $?
      ;;
  esac
}

# Function to run N4 bias field correction in parallel
run_parallel_n4_correction() {
  local input_dir="${1:-$EXTRACT_DIR}"
  local pattern="${2:-*.nii.gz}"
  local jobs="${3:-$PARALLEL_JOBS}"
  local max_depth="${4:-1}"

  log_message "Running modality-aware N4/denoising in parallel on files matching '$pattern' in $input_dir"

  # Ensure output directories exist
  create_module_dir "denoised"
  create_module_dir "bias_corrected"

  # Export required functions for parallel execution
  export -f process_modality_aware_correction detect_modality dispatch_denoising _dispatch_denoise_passthrough
  export -f process_n4_correction process_rician_nlm_denoising get_n4_parameters standardize_orientation
  export -f log_message log_formatted validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  export -f log_diagnostic execute_with_logging execute_ants_command
  # Export the full DWI path if it has been loaded so parallel workers can route
  # DWI through every step (run_dwi_preprocessing calls the whole chain).
  if declare -F run_dwi_preprocessing &> /dev/null; then
    export -f run_dwi_preprocessing run_dwi_preprocessing_auto \
      denoise_dwi_mppca degibbs_dwi eddy_correct_dwi biascorrect_dwi \
      compute_dwi_mean find_dwi_gradients 2>/dev/null || true
  fi

  # Run in parallel using the common function, going through the modality-aware
  # wrapper so DWI/SWI/TOF are never routed to Rician NLM + structural N4.
  run_parallel "process_modality_aware_correction" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?

  if [ $status -ne 0 ]; then
    log_formatted "ERROR" "Parallel modality-aware N4/denoising failed with status $status"
    return $status
  fi

  log_formatted "SUCCESS" "Completed parallel modality-aware N4 bias correction / denoising"
  return 0
}

# Export functions
export -f standardize_orientation
export -f detect_modality
export -f dispatch_denoising
export -f _dispatch_denoise_passthrough
export -f process_rician_nlm_denoising
export -f get_n4_parameters
export -f optimize_ants_parameters
export -f process_n4_correction
export -f process_modality_aware_correction
export -f run_parallel_n4_correction

log_message "Preprocessing module (orientation + modality-aware denoising + N4) loaded"
