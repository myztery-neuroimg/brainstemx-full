#!/usr/bin/env bash
#
# utils.sh - Utility functions for the brain MRI processing pipeline
#

# Legacy wrapper function for ANTs commands - only kept for backwards compatibility
# Use the enhanced version from environment.sh for new code
#
# NOTE: This function is deprecated and will be removed in a future version.
# Please use the execute_ants_command from environment.sh which provides:
# - Better progress indication
# - Step descriptions
# - Execution time tracking
# - Visualization suggestions
legacy_execute_ants_command() {
    log_formatted "WARNING" "Using legacy_execute_ants_command - please update to new version from environment.sh"
    
    local log_prefix="$1"
    shift
    
    # Create logs directory if it doesn't exist
    mkdir -p "$RESULTS_DIR/logs"
    
    # Full log file path
    local full_log="$RESULTS_DIR/logs/${log_prefix}_full.log"
    local filtered_log="$RESULTS_DIR/logs/${log_prefix}_filtered.log"
    
    log_message "Running ANTs command: $1 (full logs: $full_log)"
    
    # Execute the command and redirect ALL output to the log file
    "$@" > "$full_log" 2>&1
    local status=$?
    
    # Create a filtered version without the diagnostic lines
    grep -v "DIAGNOSTIC" "$full_log" | grep -v "^$" > "$filtered_log"
    
    # Show a summary of what happened (last few non-empty lines)
    if [ $status -eq 0 ]; then
        log_formatted "SUCCESS" "ANTs command completed successfully."
        log_message "Summary (last 3 lines):"
        tail -n 3 "$filtered_log" 
    else
        log_formatted "ERROR" "ANTs command failed with status $status"
        log_message "Error summary (last 5 lines):"
        tail -n 5 "$filtered_log" 
    fi
    
    return $status
}

# Export functions
export -f legacy_execute_ants_command

log_message "Utilities module loaded"

# Wrapper to apply transforms using FLIRT or ANTs based on USE_ANTS_SYN flag
apply_transform() {
    local input_file="$1"
    local ref_file="$2"
    local transform_file="$3"
    local output_file="$4"
    local interp="${5:-trilinear}"

    # Handle usesqform flag (skip init matrix)
    if [ "${transform_file}" == "-usesqform" ]; then
        log_message "Applying transform with FLIRT using sform/qform: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -usesqform -out "${output_file}" -interp "${interp}"
        return $?
    fi

    if [ "${USE_ANTS_SYN}" = "true" ]; then
        # Map interpolation to ANTs options
        local ants_interp="Linear"
        if [[ "${interp}" == "nearestneighbour" ]]; then
            ants_interp="NearestNeighbor"
        fi
        # Use centralized apply_transformation function for consistent SyN transform handling
        log_message "Using centralized apply_transformation function..."
        
        # Extract transform prefix from transform file path
        local transform_prefix="${transform_file%0GenericAffine.mat}"
        if apply_transformation "${input_file}" "${ref_file}" "${output_file}" "$transform_prefix" "${ants_interp}"; then
            log_message "✓ Successfully applied transform using centralized function"
        else
            log_formatted "ERROR" "Failed to apply transform using centralized function"
            return 1
        fi
    else
        log_message "Applying transform with FLIRT: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -init "${transform_file}" \
            -out "${output_file}" -interp "${interp}"
    fi
}

# Detect whether SynthStrip (FreeSurfer) is available on this system.
# Returns 0 if usable, 1 otherwise. Never hard-crashes.
synthstrip_available() {
  if command -v mri_synthstrip &> /dev/null; then
    return 0
  fi
  return 1
}

# Brain extraction via FreeSurfer SynthStrip (contrast-agnostic, current best
# practice; safest for brainstem/cerebellum preservation).
# Args: <input_file> <brain_file> <mask_file>
brain_extraction_synthstrip() {
  local input_file="$1"
  local brain_file="$2"
  local mask_file="$3"

  log_message "Using SynthStrip (FreeSurfer) brain extraction for: $input_file"

  if ! execute_with_logging "mri_synthstrip -i \"$input_file\" -o \"$brain_file\" -m \"$mask_file\"" "synthstrip"; then
    log_formatted "ERROR" "SynthStrip failed."
    return 1
  fi

  if [ -f "$brain_file" ] && [ -f "$mask_file" ]; then
    log_formatted "SUCCESS" "SynthStrip brain extraction completed successfully."
    log_message "Brain mask saved: $mask_file"
    log_message "Brain-extracted image saved: $brain_file"
    return 0
  fi

  log_formatted "ERROR" "SynthStrip reported success but expected outputs are missing."
  return 1
}

# Brain extraction via the template-free ANTs path
# (N4 -> Otsu -> largest component -> morphological open -> fill holes).
# Args: <input_file> <output_prefix> <brain_file> <mask_file>
brain_extraction_ants() {
  local input_file="$1"
  local output_prefix="$2"
  local brain_file="$3"
  local mask_file="$4"

  log_message "Using ANTs template-free brain extraction for: $input_file"

  # Create output directory for intermediate files based on output prefix
  local output_dir
  output_dir=$(dirname "$output_prefix")
  local basename_prefix
  basename_prefix=$(basename "$output_prefix")
  local intermediate_dir="${output_dir}/brain_extraction_intermediate"
  mkdir -p "$intermediate_dir"

  # Define intermediate file paths (keep N4-corrected as permanent output)
  local n4_corrected="${output_prefix}N4Corrected.nii.gz"
  local initial_mask="${intermediate_dir}/${basename_prefix}InitialMask.nii.gz"
  local largest_component_mask="${intermediate_dir}/${basename_prefix}LargestComponent.nii.gz"
  local refined_mask="${intermediate_dir}/${basename_prefix}RefinedMask.nii.gz"

  # Morphological open radius (config-driven). Softened from the legacy value of
  # 4 to avoid severing the brainstem->cord taper or rounding off the pons.
  local morph_radius="${BRAIN_MASK_MORPH_RADIUS:-1}"

  # 1. N4 Bias Field Correction
  log_message "Step 1: Performing N4 Bias Field Correction: N4BiasFieldCorrection -d 3 -i $input_file -o $n4_corrected -s $N4_SHRINK -c $N4_CONVERGENCE -b [$N4_BSPLINE] n4_correction"
  if ! execute_with_logging "N4BiasFieldCorrection -d 3 -i \"$input_file\" -o \"$n4_corrected\" -s $N4_SHRINK -c \"$N4_CONVERGENCE\" -b \"[$N4_BSPLINE]\"" "n4_correction"; then
      log_formatted "ERROR" "N4BiasFieldCorrection failed."
      rm -rf "$intermediate_dir"
      return 1
  fi

  # 2. Otsu Thresholding for initial brain mask
  log_message "Step 2: Creating initial brain mask with Otsu thresholding"
  if ! execute_with_logging "ThresholdImage 3 \"$n4_corrected\" \"$initial_mask\" Otsu 1" "otsu_threshold"; then
      log_formatted "ERROR" "Otsu thresholding failed."
      rm -rf "$intermediate_dir"
      return 1
  fi

  # 3. Keep largest connected component
  log_message "Step 3: Identifying largest connected component"
  if ! execute_with_logging "ImageMath 3 \"$largest_component_mask\" GetLargestComponent \"$initial_mask\"" "largest_component"; then
      log_formatted "ERROR" "Failed to get largest component."
      rm -rf "$intermediate_dir"
      return 1
  fi

  # 4. Morphological operations for mask refinement (radius config-driven)
  log_message "Step 4a: Dilating mask (radius ${morph_radius})"
  if ! execute_with_logging "ImageMath 3 \"$refined_mask\" MD \"$largest_component_mask\" ${morph_radius}" "mask_refinement_dilate"; then
      log_formatted "ERROR" "Mask dilation failed."
      rm -rf "$intermediate_dir"
      return 1
  fi

  log_message "Step 4b: Eroding mask to refine boundaries (radius ${morph_radius})"
  if ! execute_with_logging "ImageMath 3 \"$refined_mask\" ME \"$refined_mask\" ${morph_radius}" "mask_refinement_erode"; then
      log_formatted "ERROR" "Mask erosion failed."
      rm -rf "$intermediate_dir"
      return 1
  fi

  log_message "Step 4c: Filling holes in the final mask"
  if ! execute_with_logging "ImageMath 3 \"$mask_file\" FillHoles \"$refined_mask\"" "mask_refinement_fill"; then
      log_formatted "ERROR" "Mask hole filling failed."
      rm -rf "$intermediate_dir"
      return 1
  fi

  # 5. Create brain-extracted image by multiplying the corrected image with the final mask
  log_message "Step 5: Applying final mask to create brain-extracted image"
  if ! execute_with_logging "ImageMath 3 \"$brain_file\" m \"$n4_corrected\" \"$mask_file\"" "apply_mask"; then
      log_formatted "ERROR" "Failed to create brain-extracted image."
      rm -rf "$intermediate_dir"
      return 1
  fi

  if [ -f "$mask_file" ]; then
      log_formatted "SUCCESS" "ANTs template-free brain extraction completed successfully."
      log_message "N4-corrected image saved: $n4_corrected"
      log_message "Brain mask saved: $mask_file"
      log_message "Brain-extracted image saved: $brain_file"
      log_message "Removing intermediate directory: $intermediate_dir"
      rm -rf "$intermediate_dir"
      return 0
  fi

  # Clean up only intermediate processing files, keep N4-corrected image
  rm -rf "$intermediate_dir"
  return 1
}

# Hardened FSL BET brain extraction with posterior-fossa-safe settings:
#   - robustfov first to remove neck/large-FOV sagittal slabs (T1_MPRAGE_SAG,
#     T2_SPACE_FLAIR_Sag) which otherwise drag BET's centre of mass too low
#   - -R (robust centre estimation) plus the robustfov -c centre when available
#   - modality-specific -f (lower for FLAIR/T2 which BET tends to over-strip)
# Args: <input_file> <output_prefix> <brain_file> <mask_file>
brain_extraction_bet() {
  local input_file="$1"
  local output_prefix="$2"
  local brain_file="$3"
  local mask_file="$4"

  log_formatted "WARNING" "Falling back to FSL BET for brain extraction on: $input_file"

  # Modality-specific fractional intensity threshold.
  local bet_f="${BET_F_T1:-0.3}"
  local basename_input
  basename_input=$(basename "$input_file")
  if [[ "$basename_input" == *"FLAIR"* ]] || [[ "$basename_input" == *"T2"* ]]; then
    bet_f="${BET_F_FLAIR:-0.2}"
    log_message "Detected FLAIR/T2 modality; using BET -f ${bet_f}"
  else
    log_message "Assuming T1-like modality; using BET -f ${bet_f}"
  fi

  # Stage neck removal with robustfov when available (non-fatal if missing).
  local output_dir
  output_dir=$(dirname "$output_prefix")
  local basename_prefix
  basename_prefix=$(basename "$output_prefix")
  local cropped_input="$input_file"
  local center_args=()

  if command -v robustfov &> /dev/null; then
    local rfov_dir="${output_dir}/brain_extraction_intermediate"
    mkdir -p "$rfov_dir"
    local rfov_cropped="${rfov_dir}/${basename_prefix}robustfov.nii.gz"
    local rfov_matrix="${rfov_dir}/${basename_prefix}robustfov.mat"

    log_message "Step 1: Removing neck/large-FOV with robustfov"
    if execute_with_logging "robustfov -i \"$input_file\" -r \"$rfov_cropped\" -m \"$rfov_matrix\"" "robustfov"; then
      if [ -f "$rfov_cropped" ]; then
        cropped_input="$rfov_cropped"
      else
        log_formatted "WARNING" "robustfov reported success but cropped output missing; using original input"
      fi
    else
      log_formatted "WARNING" "robustfov failed; proceeding with original input for BET"
    fi
  else
    log_formatted "WARNING" "robustfov not found; skipping neck removal (BET may clip on large-FOV sagittal inputs)"
  fi

  # Determine a centre-of-gravity (-c) from the cropped volume when fslstats is
  # available. This keeps BET's robust centre estimation anchored near the brain.
  if command -v fslstats &> /dev/null; then
    local cog
    cog=$(fslstats "$cropped_input" -C 2>/dev/null || echo "")
    if [ -n "$cog" ]; then
      # shellcheck disable=SC2206
      local cog_arr=($cog)
      if [ "${#cog_arr[@]}" -eq 3 ]; then
        center_args=(-c "${cog_arr[0]}" "${cog_arr[1]}" "${cog_arr[2]}")
        log_message "Using BET centre-of-gravity: ${cog_arr[0]} ${cog_arr[1]} ${cog_arr[2]}"
      fi
    fi
  fi

  log_message "Step 2: Running bet \"$cropped_input\" \"$brain_file\" -R -m -f ${bet_f} ${center_args[*]:-}"
  if ! bet "$cropped_input" "$brain_file" -R -m -f "$bet_f" "${center_args[@]}"; then
    log_formatted "ERROR" "FSL BET failed. Command returned error."
    return 1
  fi

  # BET names the mask <brain_file_without_ext>_mask.nii.gz; normalise it.
  local bet_mask="${brain_file%.nii.gz}_mask.nii.gz"
  if [ -f "$bet_mask" ]; then
    if [ "$bet_mask" != "$mask_file" ]; then
      mv "$bet_mask" "$mask_file"
    fi
    log_formatted "SUCCESS" "FSL BET completed successfully. Output saved to ${mask_file}"
    return 0
  fi

  log_formatted "ERROR" "FSL BET failed. Command returned successfully but ${bet_mask} not found"
  return 1
}

# Posterior-fossa QC gate. Checks that the brain mask plausibly includes the
# cerebellum/brainstem by measuring the fraction of mask voxels lying in the
# inferior portion of the volume. Logs a non-fatal WARNING if it looks clipped.
# Even SynthStrip drops the cerebellum in ~1/3 of T2 cases, so this never fails
# the pipeline; it surfaces a flag for downstream review.
# Args: <mask_file>
qc_posterior_fossa_coverage() {
  local mask_file="$1"
  local min_fraction="${BRAIN_QC_INFERIOR_FRACTION:-0.06}"

  if [ ! -f "$mask_file" ]; then
    log_formatted "WARNING" "Posterior-fossa QC skipped: mask not found ($mask_file)"
    return 0
  fi

  if ! command -v fslstats &> /dev/null || ! command -v fslval &> /dev/null; then
    log_formatted "WARNING" "Posterior-fossa QC skipped: fslstats/fslval not available"
    return 0
  fi

  # Total non-zero voxels in the mask.
  local total_voxels
  total_voxels=$(fslstats "$mask_file" -V 2>/dev/null | awk '{print $1}')
  if [ -z "$total_voxels" ] || [ "$total_voxels" = "0" ]; then
    log_formatted "WARNING" "Posterior-fossa QC: mask appears empty ($mask_file)"
    return 0
  fi

  # Build an inferior-slab mask covering the bottom ~25% of the Z (axial) extent,
  # which is where the cerebellum/brainstem sit in a brain-only mask.
  local zdim
  zdim=$(fslval "$mask_file" dim3 2>/dev/null | xargs)
  if ! [[ "$zdim" =~ ^[0-9]+$ ]] || [ "$zdim" -le 0 ]; then
    log_formatted "WARNING" "Posterior-fossa QC skipped: could not read a valid Z dimension (got '${zdim}')"
    return 0
  fi

  local inferior_extent=$(( zdim / 4 ))
  if [ "$inferior_extent" -le 0 ]; then
    inferior_extent=1
  fi

  local qc_dir
  qc_dir=$(dirname "$mask_file")
  local inferior_mask="${qc_dir}/$(basename "${mask_file%.nii.gz}")_qc_inferior.nii.gz"

  # Use safe_fslmaths (macOS-safe wrapper) to extract the inferior slab.
  if ! safe_fslmaths "qc_inferior_slab" "$mask_file" -roi 0 -1 0 -1 0 "$inferior_extent" 0 1 "$inferior_mask"; then
    log_formatted "WARNING" "Posterior-fossa QC skipped: failed to build inferior-slab mask"
    rm -f "$inferior_mask"
    return 0
  fi

  local inferior_voxels
  inferior_voxels=$(fslstats "$inferior_mask" -V 2>/dev/null | awk '{print $1}')
  rm -f "$inferior_mask"
  if [ -z "$inferior_voxels" ]; then
    inferior_voxels=0
  fi

  local fraction
  fraction=$(echo "scale=4; $inferior_voxels / $total_voxels" | bc -l 2>/dev/null || echo "0")

  if (( $(echo "$fraction < $min_fraction" | bc -l 2>/dev/null || echo 0) )); then
    log_formatted "WARNING" "Posterior-fossa QC: only ${fraction} of mask voxels in inferior slab (expected >= ${min_fraction}). Cerebellum/brainstem may be clipped in $mask_file - review extraction."
  else
    log_message "Posterior-fossa QC passed: inferior-slab fraction ${fraction} (>= ${min_fraction})"
  fi
  return 0
}

# Function to perform brain extraction.
#
# Primary method is SynthStrip (contrast-agnostic, best practice for
# brainstem/posterior-fossa preservation), with graceful fallback through the
# ANTs template-free path and finally a hardened FSL BET. The active method is
# controlled by BRAIN_EXTRACTION_METHOD (synthstrip|ants|bet); whichever is
# selected, missing/failing tools degrade to the next available method.
#
# Signature/output naming is unchanged for downstream callers:
#   <output_prefix>BrainExtractionBrain.nii.gz
#   <output_prefix>BrainExtractionMask.nii.gz
perform_brain_extraction() {
  local input_file="$1"
  local output_prefix="$2"
  local brain_file="${output_prefix}BrainExtractionBrain.nii.gz"
  local mask_file="${output_prefix}BrainExtractionMask.nii.gz"

  log_message "Brain extraction requested for: $input_file (method preference: ${BRAIN_EXTRACTION_METHOD:-synthstrip})"

  # Build an ordered fallback chain starting from the configured preference.
  local preferred="${BRAIN_EXTRACTION_METHOD:-synthstrip}"
  local chain=()
  case "$preferred" in
    bet)        chain=(bet synthstrip ants) ;;
    ants)       chain=(ants synthstrip bet) ;;
    synthstrip) chain=(synthstrip ants bet) ;;
    *)
      log_formatted "WARNING" "Unknown BRAIN_EXTRACTION_METHOD '$preferred'; defaulting to synthstrip"
      chain=(synthstrip ants bet)
      ;;
  esac

  local method
  local extracted=false
  for method in "${chain[@]}"; do
    case "$method" in
      synthstrip)
        if synthstrip_available; then
          if brain_extraction_synthstrip "$input_file" "$brain_file" "$mask_file"; then
            extracted=true
            break
          fi
          log_formatted "WARNING" "SynthStrip extraction failed; trying next method"
        else
          log_message "SynthStrip (mri_synthstrip) not found; skipping to next method"
        fi
        ;;
      ants)
        if command -v N4BiasFieldCorrection &> /dev/null && \
           command -v ThresholdImage &> /dev/null && \
           command -v ImageMath &> /dev/null; then
          if brain_extraction_ants "$input_file" "$output_prefix" "$brain_file" "$mask_file"; then
            extracted=true
            break
          fi
          log_formatted "WARNING" "ANTs template-free extraction failed; trying next method"
        else
          log_message "ANTs core tools not found; skipping to next method"
        fi
        ;;
      bet)
        if command -v bet &> /dev/null; then
          if brain_extraction_bet "$input_file" "$output_prefix" "$brain_file" "$mask_file"; then
            extracted=true
            break
          fi
          log_formatted "WARNING" "FSL BET extraction failed; trying next method"
        else
          log_message "FSL BET not found; skipping to next method"
        fi
        ;;
    esac
  done

  if [ "$extracted" != "true" ]; then
    log_formatted "ERROR" "Brain extraction failed: no available method (SynthStrip/ANTs/BET) succeeded for $input_file"
    return 1
  fi

  # Posterior-fossa sanity check (non-fatal).
  qc_posterior_fossa_coverage "$mask_file"

  return 0
}

export -f apply_transform perform_brain_extraction
export -f synthstrip_available brain_extraction_synthstrip brain_extraction_ants
export -f brain_extraction_bet qc_posterior_fossa_coverage
