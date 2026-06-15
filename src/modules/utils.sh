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

    # FLIRT only accepts trilinear|nearestneighbour|sinc|spline; callers may pass
    # ANTs-style names (Linear, NearestNeighbor, GenericLabel). Normalise the FSL
    # interpolation so a label-aware request still maps to nearest-neighbour.
    local flirt_interp="$interp"
    case "$interp" in
        NearestNeighbor|GenericLabel|MultiLabel|nearestneighbour) flirt_interp="nearestneighbour" ;;
        Linear|trilinear)                                          flirt_interp="trilinear" ;;
    esac

    # Handle usesqform flag (skip init matrix)
    if [ "${transform_file}" == "-usesqform" ]; then
        log_message "Applying transform with FLIRT using sform/qform: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -usesqform -out "${output_file}" -interp "${flirt_interp}"
        return $?
    fi

    if [ "${USE_ANTS_SYN}" = "true" ]; then
        # Map interpolation to ANTs options.  A nearest-neighbour / label request
        # implies a discrete label/mask, so flag it as a label image for label-aware
        # interpolation; intensity images keep Linear.
        local ants_interp="Linear"
        local ants_is_label="false"
        case "${interp}" in
            nearestneighbour|NearestNeighbor|GenericLabel|MultiLabel)
                ants_interp="NearestNeighbor"
                ants_is_label="true"
                ;;
        esac
        # Use centralized apply_transformation function for consistent SyN transform handling
        log_message "Using centralized apply_transformation function..."

        # Extract transform prefix from transform file path
        local transform_prefix="${transform_file%0GenericAffine.mat}"
        if apply_transformation "${input_file}" "${ref_file}" "${output_file}" "$transform_prefix" "${ants_interp}" "inverse" "${ants_is_label}"; then
            log_message "✓ Successfully applied transform using centralized function"
        else
            log_formatted "ERROR" "Failed to apply transform using centralized function"
            return 1
        fi
    else
        log_message "Applying transform with FLIRT: ${input_file} -> ${output_file}"
        flirt -in "${input_file}" -ref "${ref_file}" -applyxfm -init "${transform_file}" \
            -out "${output_file}" -interp "${flirt_interp}"
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
#   - -R (robust centre estimation) plus a centre-of-gravity (-c) anchor
#   - modality-specific -f (lower for FLAIR/T2 which BET tends to over-strip)
# Neck/large-FOV removal is handled upstream by the shared robustfov
# FOV-normalization pre-step in perform_brain_extraction() (BRAIN_EXTRACTION_ROBUSTFOV),
# so this function no longer crops; it receives whichever image the dispatcher
# chose (cropped or original) and never double-crops.
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

  # Determine a centre-of-gravity (-c) from the input volume when fslstats is
  # available. This keeps BET's robust centre estimation anchored near the brain.
  local center_args=()
  if command -v fslstats &> /dev/null; then
    local cog
    cog=$(fslstats "$input_file" -C 2>/dev/null || echo "")
    if [ -n "$cog" ]; then
      # shellcheck disable=SC2206
      local cog_arr=($cog)
      if [ "${#cog_arr[@]}" -eq 3 ]; then
        center_args=(-c "${cog_arr[0]}" "${cog_arr[1]}" "${cog_arr[2]}")
        log_message "Using BET centre-of-gravity: ${cog_arr[0]} ${cog_arr[1]} ${cog_arr[2]}"
      fi
    fi
  fi

  log_message "Running bet \"$input_file\" \"$brain_file\" -R -m -f ${bet_f} ${center_args[*]:-}"
  if ! bet "$input_file" "$brain_file" -R -m -f "$bet_f" "${center_args[@]}"; then
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

# Decide whether the shared robustfov FOV-normalization pre-step should run for
# a given input. Returns 0 (run crop) / 1 (skip crop). Never hard-crashes.
# Gated by BRAIN_EXTRACTION_ROBUSTFOV and the availability of robustfov; an
# optional BRAIN_EXTRACTION_ROBUSTFOV_MIN_Z_MM heuristic restricts cropping to
# large superior-inferior FOV acquisitions (the sagittal 3D slabs that benefit).
should_run_fov_crop() {
  local input_file="$1"

  if [ "${BRAIN_EXTRACTION_ROBUSTFOV:-true}" != "true" ]; then
    log_message "FOV-normalization (robustfov) disabled via BRAIN_EXTRACTION_ROBUSTFOV; extracting on original image"
    return 1
  fi

  if ! command -v robustfov &> /dev/null; then
    log_formatted "WARNING" "robustfov not found; skipping FOV normalization (extracting on original image)"
    return 1
  fi

  # Optional heuristic: only crop when the Z (superior-inferior) extent in mm is
  # large. A value of 0 (or an unreadable dimension) means crop unconditionally.
  local min_z_mm="${BRAIN_EXTRACTION_ROBUSTFOV_MIN_Z_MM:-0}"
  if [ "$min_z_mm" != "0" ] && command -v fslval &> /dev/null; then
    local zdim zpix z_extent
    zdim=$(fslval "$input_file" dim3 2>/dev/null | xargs)
    zpix=$(fslval "$input_file" pixdim3 2>/dev/null | xargs)
    # Require numeric dims; a non-numeric pixdim would make bc treat it as 0 and
    # wrongly skip the crop, so fall through to "crop unconditionally" instead.
    if [[ "$zdim" =~ ^[0-9]+$ ]] && [[ "$zpix" =~ ^[0-9]*\.?[0-9]+$ ]]; then
      z_extent=$(echo "$zdim * $zpix" | bc -l 2>/dev/null || echo "")
      if [ -n "$z_extent" ] && (( $(echo "$z_extent < $min_z_mm" | bc -l 2>/dev/null || echo 0) )); then
        log_message "FOV-normalization skipped: Z extent ${z_extent}mm below threshold ${min_z_mm}mm (likely already tight FOV)"
        return 1
      fi
      log_message "FOV-normalization enabled: Z extent ${z_extent}mm >= threshold ${min_z_mm}mm"
    else
      log_message "FOV-normalization: could not read Z extent; applying crop unconditionally"
    fi
  fi

  return 0
}

# Shared pre-extraction FOV-normalization. Runs robustfov on <input_file> to
# remove the neck/large-FOV slab and writes:
#   <cropped_file>  - neck-removed image (extract the brain on THIS)
#   <roi2full_mat>  - robustfov ROI->full FLIRT affine (used later to map the
#                     cropped-space mask back onto the original full grid)
# Returns 0 on success (outputs present), 1 on any failure (caller falls back to
# extracting on the original image). Never hard-crashes.
# Args: <input_file> <cropped_file> <roi2full_mat>
compute_fov_cropped_for_extraction() {
  local input_file="$1"
  local cropped_file="$2"
  local roi2full_mat="$3"

  log_message "FOV-normalization: running robustfov on $input_file"

  if ! execute_with_logging "robustfov -i \"$input_file\" -r \"$cropped_file\" -m \"$roi2full_mat\"" "robustfov"; then
    log_formatted "WARNING" "robustfov failed; will extract on original image"
    return 1
  fi

  if [ ! -f "$cropped_file" ] || [ ! -f "$roi2full_mat" ]; then
    log_formatted "WARNING" "robustfov reported success but expected outputs missing; will extract on original image"
    return 1
  fi

  log_message "FOV-normalization: cropped image $cropped_file (ROI->full affine $roi2full_mat)"
  return 0
}

# Map a brain mask computed in robustfov cropped space back onto the ORIGINAL
# full image grid, then rebuild the brain-extracted image in native space by
# masking the original input. This keeps the final brain/mask outputs in the
# original geometry so nothing downstream (registration/segmentation) shifts.
# Args: <original_input> <cropped_mask> <roi2full_mat> <out_mask> <out_brain>
map_mask_to_original_grid() {
  local original_input="$1"
  local cropped_mask="$2"
  local roi2full_mat="$3"
  local out_mask="$4"
  local out_brain="$5"

  log_message "FOV-normalization: mapping cropped-space mask back to original grid ($original_input)"

  if ! command -v flirt &> /dev/null; then
    log_formatted "WARNING" "flirt not available; cannot map cropped mask back to original grid"
    return 1
  fi

  # robustfov's -m writes the ROI->full affine (its help text: "roi to full
  # fov"). FLIRT's -applyxfm -init matrix maps -in coords into -ref coords, and
  # here -in is the cropped (ROI) mask and -ref is the original (full) image, so
  # the ROI->full matrix is used DIRECTLY (no inversion). Empirically this
  # preserves the mask voxel count exactly; inverting it shifts the mask ~1 voxel
  # and drops voxels. Nearest-neighbour interpolation preserves the binary label.
  if ! execute_with_logging "flirt -in \"$cropped_mask\" -ref \"$original_input\" -applyxfm -init \"$roi2full_mat\" -interp nearestneighbour -out \"$out_mask\"" "robustfov_map_mask"; then
    log_formatted "WARNING" "Failed to resample cropped mask onto original grid"
    return 1
  fi

  if [ ! -f "$out_mask" ]; then
    log_formatted "WARNING" "Mapped mask missing after resampling onto original grid"
    return 1
  fi

  # Binarise defensively (NN resampling should already be 0/1, but guard against
  # any interpolation residue) and rebuild the brain image in native space.
  # Write to a distinct temp file (not in place) so safe_fslmaths can validate
  # the resampled mask as a real input, then move it into place.
  local binarised_mask="${out_mask%.nii.gz}_bin.nii.gz"
  if ! safe_fslmaths "robustfov_binarise_mask" "$out_mask" -thr 0.5 -bin "$binarised_mask"; then
    log_formatted "WARNING" "Failed to binarise mapped mask"
    rm -f "$binarised_mask"
    return 1
  fi
  mv "$binarised_mask" "$out_mask"

  if ! safe_fslmaths "robustfov_apply_mask" "$original_input" -mas "$out_mask" "$out_brain"; then
    log_formatted "WARNING" "Failed to rebuild brain-extracted image on original grid"
    return 1
  fi

  log_formatted "SUCCESS" "FOV-normalization: mask mapped back to original native space ($out_mask)"
  return 0
}

# Run the ordered method fallback chain (synthstrip/ants/bet) against a given
# input/prefix/brain/mask, honouring per-method tool availability. Returns 0 on
# the first method that succeeds, 1 if none does. Shared by both the FOV-cropped
# extraction path and the original-image (re-)extraction so the dispatch logic
# lives in one place. Args: <input> <prefix> <brain> <mask> <chain...>
run_extraction_chain() {
  local input_file="$1"
  local output_prefix="$2"
  local brain_file="$3"
  local mask_file="$4"
  shift 4
  local chain=("$@")

  local method
  for method in "${chain[@]}"; do
    case "$method" in
      synthstrip)
        if synthstrip_available; then
          if brain_extraction_synthstrip "$input_file" "$brain_file" "$mask_file"; then
            return 0
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
            return 0
          fi
          log_formatted "WARNING" "ANTs template-free extraction failed; trying next method"
        else
          log_message "ANTs core tools not found; skipping to next method"
        fi
        ;;
      bet)
        if command -v bet &> /dev/null; then
          if brain_extraction_bet "$input_file" "$output_prefix" "$brain_file" "$mask_file"; then
            return 0
          fi
          log_formatted "WARNING" "FSL BET extraction failed; trying next method"
        else
          log_message "FSL BET not found; skipping to next method"
        fi
        ;;
    esac
  done

  return 1
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

  # Shared pre-extraction FOV-normalization (robustfov). When enabled/applicable,
  # extraction runs on a neck-removed CROPPED image and the resulting mask is
  # mapped back to the original full grid so final outputs stay in native space.
  # When skipped (disabled, tool missing, or heuristic), extraction runs on the
  # original input exactly as before.
  local extract_input="$input_file"
  local extract_prefix="$output_prefix"
  local extract_brain="$brain_file"
  local extract_mask="$mask_file"
  local fov_cropped=false
  local fov_dir=""
  local fov_roi2full=""
  if should_run_fov_crop "$input_file"; then
    fov_dir="$(dirname "$output_prefix")/fov_normalization"
    mkdir -p "$fov_dir"
    local fov_basename
    fov_basename="$(basename "$output_prefix")"
    local fov_cropped_img="${fov_dir}/${fov_basename}robustfov.nii.gz"
    fov_roi2full="${fov_dir}/${fov_basename}robustfov.mat"
    if compute_fov_cropped_for_extraction "$input_file" "$fov_cropped_img" "$fov_roi2full"; then
      fov_cropped=true
      # Run the chain against cropped-space inputs/outputs.
      extract_input="$fov_cropped_img"
      extract_prefix="${fov_dir}/${fov_basename}"
      extract_brain="${fov_dir}/${fov_basename}BrainExtractionBrain.nii.gz"
      extract_mask="${fov_dir}/${fov_basename}BrainExtractionMask.nii.gz"
    else
      log_formatted "WARNING" "FOV-normalization unavailable; extracting on original image"
    fi
  fi

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

  if ! run_extraction_chain "$extract_input" "$extract_prefix" "$extract_brain" "$extract_mask" "${chain[@]}"; then
    log_formatted "ERROR" "Brain extraction failed: no available method (SynthStrip/ANTs/BET) succeeded for $input_file"
    [ -n "$fov_dir" ] && rm -rf "$fov_dir"
    return 1
  fi

  # When extraction ran on the cropped image, map the mask back to the original
  # grid and rebuild the brain image in native space. If mapping fails, fall back
  # to re-extracting on the original image so we never emit cropped-geometry
  # outputs downstream.
  if [ "$fov_cropped" = "true" ]; then
    if ! map_mask_to_original_grid "$input_file" "$extract_mask" "$fov_roi2full" "$mask_file" "$brain_file"; then
      log_formatted "WARNING" "Failed to map cropped mask to original grid; re-extracting on original image"
      [ -n "$fov_dir" ] && rm -rf "$fov_dir"
      fov_dir=""
      log_message "Re-running brain extraction on original image (no FOV crop): $input_file"
      if ! run_extraction_chain "$input_file" "$output_prefix" "$brain_file" "$mask_file" "${chain[@]}"; then
        log_formatted "ERROR" "Brain extraction failed on original image after FOV-normalization fallback for $input_file"
        return 1
      fi
    fi
  fi

  # Always clean up the FOV-normalization scratch directory if one was created.
  if [ -n "$fov_dir" ]; then
    rm -rf "$fov_dir"
  fi

  # Verify the final mask is aligned to the original image grid (non-fatal).
  verify_mask_alignment "$input_file" "$mask_file"

  # Posterior-fossa sanity check (non-fatal).
  qc_posterior_fossa_coverage "$mask_file"

  return 0
}

# Verify a brain mask shares the original image's voxel grid (dim1/2/3) and is
# non-empty. Logs a non-fatal WARNING on mismatch or an empty mask; this guards
# against the FOV-crop mapping leaving the mask in cropped geometry or producing
# an all-zero mask (e.g. a wrong-direction affine). Note: a same-FOV resample
# always matches dims, so the non-empty/voxel-count check is what catches a
# grossly mis-mapped mask. Args: <original_input> <mask_file>
verify_mask_alignment() {
  local original_input="$1"
  local mask_file="$2"

  if ! command -v fslval &> /dev/null; then
    return 0
  fi
  if [ ! -f "$mask_file" ]; then
    log_formatted "WARNING" "Mask alignment check skipped: mask not found ($mask_file)"
    return 0
  fi

  local dim
  for dim in dim1 dim2 dim3; do
    local in_v mask_v
    in_v=$(fslval "$original_input" "$dim" 2>/dev/null | xargs)
    mask_v=$(fslval "$mask_file" "$dim" 2>/dev/null | xargs)
    if [ -n "$in_v" ] && [ -n "$mask_v" ] && [ "$in_v" != "$mask_v" ]; then
      log_formatted "WARNING" "Mask alignment: ${dim} mismatch (input=${in_v}, mask=${mask_v}) for $mask_file - mask may not be on the original grid"
      return 0
    fi
  done

  # Non-empty sanity check: an all-zero mask after mapping signals a failed/empty
  # resample (e.g. a wrong-direction affine that mapped the brain off-grid).
  if command -v fslstats &> /dev/null; then
    local nvox
    nvox=$(fslstats "$mask_file" -V 2>/dev/null | awk '{print $1}')
    if [ -n "$nvox" ] && [ "$nvox" = "0" ]; then
      log_formatted "WARNING" "Mask alignment: mapped mask is empty ($mask_file) - extraction or FOV-crop mapping may have failed"
      return 0
    fi
  fi

  log_message "Mask alignment verified: $mask_file matches original grid of $original_input"
  return 0
}

export -f apply_transform perform_brain_extraction
export -f synthstrip_available brain_extraction_synthstrip brain_extraction_ants
export -f brain_extraction_bet qc_posterior_fossa_coverage
export -f should_run_fov_crop compute_fov_cropped_for_extraction
export -f map_mask_to_original_grid run_extraction_chain
export -f verify_mask_alignment
