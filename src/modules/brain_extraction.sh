#!/usr/bin/env bash
#
# brain_extraction.sh - Brain extraction, standardization, and cropping functions
#
# This module contains:
# - Multi-axial integration
# - Brain extraction
# - Dimension standardization
# - Cropping with padding
# - Parallel processing for all of the above
#

source_module "utils.sh"

# Function to detect 3D isotropic sequences
# This function identifies 3D sequences like MPRAGE, SPACE, or 3D FLAIR
# Returns 0 (true) if the sequence is detected as 3D isotropic, 1 (false) otherwise
is_3d_isotropic_sequence() {
  local file="$1"
  local filename=$(basename "$file")
  
  # Check filename first (fast path)
  if [[ "$filename" == *"T1"*"14" ]] || 
     [[ "$filename" == *"T2_SPACE"*"SAG"*"17"* ]] || 
     [[ "$filename" == *"MP2RAGE"* ]] || 
     [[ "$filename" == *"3D"* ]]; then
    log_message "3D sequence detected by filename pattern: $filename"
    return 0  # true
  fi
  
  # Check metadata if available
  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  if [ -f "$metadata_file" ]; then
    # Check if we have access to jq for JSON parsing
    if command -v jq &> /dev/null; then
      # Check for acquisition type
      local acquisitionType=$(jq -r '.acquisitionType // ""' "$metadata_file")
      if [[ "$acquisitionType" == "3D" ]]; then
        log_message "3D sequence detected by DICOM acquisitionType: 3D"
        return 0  # true
      fi

      # Check explicitly set is3D flag
      local is3D=$(jq -r '.is3D // false' "$metadata_file")
      if [[ "$is3D" == "true" ]]; then
        log_message "3D sequence detected by DICOM metadata is3D flag"
        return 0  # true
      fi
    fi
  fi
  
  # Check if voxels are approximately isotropic
  local pixdim1=$(fslval "$file" pixdim1)
  local pixdim2=$(fslval "$file" pixdim2)
  local pixdim3=$(fslval "$file" pixdim3)
  
  # Calculate max difference between dimensions
  local max_diff=$(echo "scale=3; m=($pixdim1-$pixdim2); if(m<0) m=-m; 
                  n=($pixdim1-$pixdim3); if(n<0) n=-n;
                  o=($pixdim2-$pixdim3); if(o<0) o=-o;
                  if(m>n) { if(m>o) m else o } else { if(n>o) n else o }" | bc -l)
  
  # Check if approximately isotropic (within 15%)
  local max_dim=$(echo "scale=3; m=$pixdim1; 
                 if(m<$pixdim2) m=$pixdim2; 
                 if(m<$pixdim3) m=$pixdim3; m" | bc -l)
  
  local threshold=$(echo "scale=3; $max_dim * 0.15" | bc -l)
  
  if (( $(echo "$max_diff <= $threshold" | bc -l) )); then
    log_message "3D sequence detected by isotropic voxel analysis: max_diff=$max_diff, threshold=$threshold"
    return 0  # true
  fi
  
  return 1  # false
}

# Function to calculate a resolution quality metric
# Higher values indicate better quality based on voxel dimensions and isotropy
calculate_resolution_quality() {
  local file="$1"
  
  # Get dimensions in voxels
  local d1=$(fslval "$file" dim1)
  local d2=$(fslval "$file" dim2)
  local d3=$(fslval "$file" dim3)
  
  # Get physical dimensions in mm
  local p1=$(fslval "$file" pixdim1)
  local p2=$(fslval "$file" pixdim2)
  local p3=$(fslval "$file" pixdim3)
  
  # Calculate in-plane resolution (average of x and y)
  local inplane_res=$(echo "scale=3; ($p1 + $p2) / 2" | bc -l)
  
  # Calculate anisotropy factor (penalizes highly anisotropic voxels)
  local anisotropy=$(echo "scale=3; $p3 / $inplane_res" | bc -l)
  
  # Calculate quality metric:
  # Higher for more voxels, lower for more anisotropy
  # Prioritizes in-plane resolution for 2D sequences
  local quality=$(echo "scale=3; ($d1 * $d2 * $d3) / ($inplane_res * $inplane_res * $p3 * sqrt($anisotropy))" | bc -l)
  
  echo "$quality"
}

# Function to calculate in-plane resolution
calculate_inplane_resolution() {
  local file="$1"

  # Validate input file
  if ! validate_file "$file" "Input file"; then
    return $ERR_FILE_NOT_FOUND
  fi
  
  # Get pixel dimensions
  local pixdim1=$(fslval "$file" pixdim1)
  local pixdim2=$(fslval "$file" pixdim2)
  
  # Calculate in-plane resolution (average of x and y dimensions)
  local inplane_res=$(echo "scale=3; ($pixdim1 + $pixdim2) / 2" | bc -l)
  
  echo "$inplane_res"
}

# Function to check for orientation consistency between images
check_orientation_consistency() {
  local files=("$@")
  local reference_orient=""
  local reference_file=""
  local inconsistent_files=()
  
  log_message "Checking orientation consistency across ${#files[@]} files..."
  
  for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
      log_formatted "WARNING" "File not found for orientation check: $file"
      continue
    fi
    
    # Get orientation string
    local orient=$(fslorient -getorient "$file" 2>/dev/null || echo "UNKNOWN")
    local filename=$(basename "$file")
    
    if [ -z "$reference_orient" ]; then
      reference_orient="$orient"
      reference_file="$filename"
      log_message "Reference orientation: $orient (from $filename)"
    else
      if [ "$orient" != "$reference_orient" ]; then
        inconsistent_files+=("$filename:$orient")
        log_formatted "WARNING" "Orientation mismatch: $filename has $orient (expected $reference_orient)"
      else
        log_message "Orientation match: $filename has $orient ✓"
      fi
    fi
  done
  
  if [ ${#inconsistent_files[@]} -gt 0 ]; then
    log_formatted "WARNING" "Orientation inconsistencies detected:"
    log_message "Reference: $reference_file ($reference_orient)"
    for mismatch in "${inconsistent_files[@]}"; do
      log_message "Mismatch: $mismatch"
    done
    log_message "This may cause FSL registration warnings but should not affect analysis"
    return 1
  else
    log_formatted "SUCCESS" "All images have consistent orientation: $reference_orient"
    return 0
  fi
}

# Function to perform detailed orientation matrix comparison
check_detailed_orientation_matrices() {
  local file1="$1"
  local file2="$2"
  
  log_message "Detailed orientation matrix comparison:"
  log_message "  File 1: $(basename "$file1")"
  log_message "  File 2: $(basename "$file2")"
  
  # Get sform and qform matrices
  local sform1=$(fslinfo "$file1" | grep -E "^sto_xyz:" | head -4)
  local sform2=$(fslinfo "$file2" | grep -E "^sto_xyz:" | head -4)
  local qform1=$(fslinfo "$file1" | grep -E "^qto_xyz:" | head -4)
  local qform2=$(fslinfo "$file2" | grep -E "^qto_xyz:" | head -4)
  
  # Compare sform matrices
  if [ "$sform1" = "$sform2" ]; then
    log_message "  Sform matrices: identical ✓"
    local sform_match=true
  else
    log_formatted "WARNING" "  Sform matrices: different"
    local sform_match=false
  fi
  
  # Compare qform matrices
  if [ "$qform1" = "$qform2" ]; then
    log_message "  Qform matrices: identical ✓"
    local qform_match=true
  else
    log_formatted "WARNING" "  Qform matrices: different"
    local qform_match=false
  fi
  
  if [ "$sform_match" = true ] && [ "$qform_match" = true ]; then
    log_formatted "SUCCESS" "Orientation matrices are fully identical"
    return 0
  else
    log_formatted "WARNING" "Orientation matrices show differences - may cause FSL warnings"
    return 1
  fi
}

# Function to detect optimal resolution across multiple images
detect_optimal_resolution() {
  local files=("$@")
  local best_resolution=999.0  # Start with very poor resolution
  local best_file=""
  
  log_message "Detecting optimal resolution across ${#files[@]} files..."
  
  for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
      log_formatted "WARNING" "File not found for resolution detection: $file"
      continue
    fi
    
    # Get pixel dimensions (trim whitespace)
    local pixdim1=$(fslval "$file" pixdim1 | xargs)
    local pixdim2=$(fslval "$file" pixdim2 | xargs)
    local pixdim3=$(fslval "$file" pixdim3 | xargs)
    
    # Calculate average in-plane resolution (finest detail indicator)
    local inplane_res=$(echo "scale=6; ($pixdim1 + $pixdim2) / 2" | bc -l)
    
    # Track the finest (smallest) resolution
    if (( $(echo "$inplane_res < $best_resolution" | bc -l) )); then
      best_resolution="$inplane_res"
      best_file="$file"
    fi
    
    log_message "$(basename "$file"): ${pixdim1}x${pixdim2}x${pixdim3}mm (in-plane avg: ${inplane_res}mm)"
  done
  
  if [ -n "$best_file" ]; then
    # Get the optimal file's dimensions for the target grid (trim whitespace)
    local opt_pixdim1=$(fslval "$best_file" pixdim1 | xargs)
    local opt_pixdim2=$(fslval "$best_file" pixdim2 | xargs)
    local opt_pixdim3=$(fslval "$best_file" pixdim3 | xargs)
    
    log_formatted "SUCCESS" "Optimal resolution detected from $(basename "$best_file")"
    log_message "Target grid: ${opt_pixdim1}x${opt_pixdim2}x${opt_pixdim3}mm"
    
    # Return the optimal dimensions (T1 always used as reference for segmentation)
    echo "${opt_pixdim1}x${opt_pixdim2}x${opt_pixdim3}"
  else
    log_formatted "WARNING" "No valid files for resolution detection, using default 1x1x1"
    echo "1x1x1"
  fi
}

# Function to combine multi-axial images
# 
# This function detects and handles different types of MRI sequences:
# 
# 1. 3D Isotropic Sequences (e.g., T1-MPRAGE, T2-SPACE-FLAIR):
#    - Automatically detected via filename or metadata
#    - Skips multi-axis combination (which would degrade quality)
#    - Uses the highest quality single view
# 
# 2. 2D Sequences (e.g., conventional T2-FLAIR, T2-TSE):
#    - Combines views from different orientations when available
#    - Uses enhanced resolution selection that considers anisotropy
#    - Falls back to best single orientation when needed
# 
# Resolution selection considers:
#    - Physical dimensions (in mm)
#    - Anisotropy (penalizes highly anisotropic voxels)
#    - Total voxel count
combine_multiaxis_images() {
  local sequence_type="$1"
  local output_dir="$2"
  
  local all_files=()  # To store all files for 3D detection
  
  # Create output directory
  output_dir=$(create_module_dir "combined")
  
  log_message "Combining multi-axis images for $sequence_type"
  
  # Validate input directory
  if ! validate_directory "$EXTRACT_DIR" "DICOM extracted directory"; then
    log_formatted "ERROR" "DICOM extraction directory not found: $EXTRACT_DIR"
    return $ERR_DATA_MISSING
  fi

  # Find SAG, COR, AX
  local sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  
  local ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # Store all files for 3D detection
  all_files=("${sag_files[@]}" "${cor_files[@]}" "${ax_files[@]}")

  # Check if sequence is 3D isotropic
  local is_3d=false
  for file in "${all_files[@]}"; do
    if is_3d_isotropic_sequence "$file"; then
      is_3d=true
      log_message "Detected 3D isotropic sequence: $file"
      break
    fi
  done
  
  local out_file=$(get_output_path "combined" "${sequence_type}" "_combined_highres")
  
  # If 3D isotropic sequence detected, skip combination
  if [ "$is_3d" = true ]; then
    log_message "3D isotropic sequence detected, skipping multi-axis combination"
    
    local best_file=""
    local best_quality=0
    
    # Find best quality 3D file across all orientations
    for file in "${all_files[@]}"; do
      if is_3d_isotropic_sequence "$file"; then
        local quality=$(calculate_resolution_quality "$file")
        if (( $(echo "$quality > $best_quality" | bc -l) )); then
          best_file="$file"
          best_quality="$quality"
        fi
      fi
    done
    
    if [ -n "$best_file" ]; then
      log_message "Using highest quality 3D volume: $best_file (quality score: $best_quality)"
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      if ! validate_nifti "$out_file" "3D volume (single orientation)"; then
        log_formatted "ERROR" "3D volume validation failed: $out_file"
        return $ERR_DATA_CORRUPT
      fi
      log_formatted "SUCCESS" "Used high-quality 3D image: $out_file"
      return 0
    else
      log_message "Warning: 3D sequence detected but no suitable file found, falling back to standard method"
    fi
  fi
 
  # For 2D sequences, pick best resolution from each orientation using enhanced quality metric
  local best_sag="" best_cor="" best_ax=""
  local best_sag_qual=0 best_cor_qual=0 best_ax_qual=0
 
  for file in "${sag_files[@]}"; do
    local quality=$(calculate_resolution_quality "$file")
    if (( $(echo "$quality > $best_sag_qual" | bc -l) )); then
      best_sag="$file"; best_sag_qual=$quality
    fi
  done
  for file in "${cor_files[@]}"; do
    local quality=$(calculate_resolution_quality "$file")
    if (( $(echo "$quality > $best_cor_qual" | bc -l) )); then
      best_cor="$file"; best_cor_qual=$quality
    fi
  done
  for file in "${ax_files[@]}"; do
    local quality=$(calculate_resolution_quality "$file")
    if (( $(echo "$quality > $best_ax_qual" | bc -l) )); then
      best_ax="$file"; best_ax_qual=$quality
    fi
  done

  # Original logic for 2D sequences
  log_message "Processing as 2D multi-orientation sequence"
  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG (quality: $best_sag_qual), COR (quality: $best_cor_qual), AX (quality: $best_ax_qual) with antsMultivariateTemplateConstruction2.sh"
    log_message "Running multi-axial template construction with diagnostic output filtering"
    
    # Build the template construction command
    local template_cmd="antsMultivariateTemplateConstruction2.sh -d 3 -o \"${output_dir}/${sequence_type}_template_\" -i $TEMPLATE_ITERATIONS -g $TEMPLATE_GRADIENT_STEP -j $ANTS_THREADS -f $TEMPLATE_SHRINK_FACTORS -s $TEMPLATE_SMOOTHING_SIGMAS -q $TEMPLATE_WEIGHTS -t $TEMPLATE_TRANSFORM_MODEL -m $TEMPLATE_SIMILARITY_METRIC -c 0 \"$best_sag\" \"$best_cor\" \"$best_ax\""
    
    # Execute with filtering
    execute_with_logging "$template_cmd" "ants_template_construction"

    if ! mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$out_file"; then
      log_formatted "ERROR" "Failed to move template output: ${output_dir}/${sequence_type}_template_template0.nii.gz"
      return $ERR_FILE_CREATION
    fi
    
    standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
    if ! validate_nifti "$out_file" "Combined high-res image"; then
      log_formatted "ERROR" "Combined image validation failed: $out_file"
      return $ERR_DATA_CORRUPT
    fi
    log_formatted "SUCCESS" "Created high-res combined: $out_file"

  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    local best_qual=0
    
    # Find best quality among available orientations
    if [ -n "$best_sag" ]; then 
      best_file="$best_sag"
      best_qual=$best_sag_qual
    fi
    
    if [ -n "$best_cor" ] && (( $(echo "$best_cor_qual > $best_qual" | bc -l) )); then
      best_file="$best_cor"
      best_qual=$best_cor_qual
    fi
    
    if [ -n "$best_ax" ] && (( $(echo "$best_ax_qual > $best_qual" | bc -l) )); then
      best_file="$best_ax"
      best_qual=$best_ax_qual
    fi
    
    if [ -n "$best_file" ]; then
      log_message "Using best quality orientation (quality score: $best_qual): $best_file"
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      if ! validate_nifti "$out_file" "Combined fallback image"; then
        log_formatted "ERROR" "Fallback image validation failed: $out_file"
        return $ERR_DATA_CORRUPT
      fi
      log_formatted "SUCCESS" "Used single orientation: $best_file"
      return 0
    else
      log_formatted "ERROR" "No $sequence_type files found"
      return $ERR_DATA_MISSING
    fi
  fi
}

# Function to combine multi-axial images with high resolution
combine_multiaxis_images_highres() {
  local sequence_type="$1"
  local output_dir="$2"
  local resolution=1 ##"${3:-1}"  # Default to 1mm isotropic

  # Create output directory
  output_dir=$(create_module_dir "combined")
  
  log_message "Combining multi-axis images for $sequence_type with high resolution"
  
  # First combine using the standard function
  if ! combine_multiaxis_images "$sequence_type" "$output_dir"; then
    local combine_status=$?
    log_formatted "ERROR" "Failed to combine multi-axial images with status $combine_status"
    return $combine_status
  fi
  
  # Get the combined file
  local combined_file=$(get_output_path "combined" "${sequence_type}" "_combined_highres")
  
  # Validate combined file
  if ! validate_nifti "$combined_file" "Combined file"; then
    log_formatted "ERROR" "Combined file validation failed: $combined_file"
    return $ERR_DATA_CORRUPT
  fi
  
  # Resample to high resolution
  local highres_file=$(get_output_path "combined" "${sequence_type}" "_combined_highres_${resolution}mm")
  
  log_message "Resampling to ${resolution}mm isotropic resolution"
  
  # Check if ResampleImage is available, if not use antsApplyTransforms
  if command -v ResampleImage &> /dev/null; then
    ResampleImage 3 "$combined_file" "$highres_file" ${resolution}x${resolution}x${resolution} 0 4
  else
    log_formatted "WARNING" "ResampleImage not available - using antsApplyTransforms for resampling"
    # Use antsApplyTransforms with a temporary reference
    local temp_ref="${output_dir}/temp_ref_${resolution}mm.nii.gz"
    
    if command -v c3d &> /dev/null; then
      c3d "$combined_file" -resample-mm ${resolution}x${resolution}x${resolution} -o "$temp_ref"
      antsApplyTransforms -d 3 -i "$combined_file" -r "$temp_ref" -o "$highres_file" -n Linear
      rm -f "$temp_ref"
    else
      log_formatted "ERROR" "Neither ResampleImage nor c3d available for high-resolution resampling"
      return 1
    fi
  fi
  
  # Validate highres file
  if ! validate_nifti "$highres_file" "High-resolution image"; then
    log_formatted "ERROR" "High-resolution image validation failed: $highres_file"
    return $ERR_DATA_CORRUPT
  fi
  
  log_message "High-resolution combined image created: $highres_file"
  return 0
}

# Function to standardize dimensions
standardize_dimensions() {
  local input_file="$1"
  local target_resolution="${2:-}"  # Optional target resolution parameter
  local reference_file="${3:-}"     # Optional reference file for matrix dimensions
  
  # Validate input file
  if ! validate_nifti "$input_file" "Input file for standardization"; then
    log_formatted "ERROR" "Invalid input file for standardization: $input_file"
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$input_file" .nii.gz)
  local output_dir=$(create_module_dir "standardized")
  local output_file=$(get_output_path "standardized" "$basename" "_std")

  log_message "Standardizing dimensions for $basename"
  
  # Get current dimensions and pixel sizes
  local x_dim=$(fslval "$input_file" dim1)
  local y_dim=$(fslval "$input_file" dim2)
  local z_dim=$(fslval "$input_file" dim3)
  local x_pix=$(fslval "$input_file" pixdim1)
  local y_pix=$(fslval "$input_file" pixdim2)
  local z_pix=$(fslval "$input_file" pixdim3)

  # Determine target dimensions
  local target_dims=""
  local use_reference_grid=false
  
  if [ -n "$reference_file" ] && [ -f "$reference_file" ]; then
    # Use reference file for identical matrix dimensions
    log_message "Using reference file for identical matrix dimensions: $(basename "$reference_file")"
    use_reference_grid=true
  elif [ -n "$target_resolution" ]; then
    # Use provided optimal resolution (smart standardization)
    target_dims="$target_resolution"
    log_message "Using smart standardization with optimal resolution: $target_dims mm"
  else
    # Legacy behavior: sequence-based standardization
    log_formatted "WARNING" "Using legacy standardization - consider using smart resolution detection"
    if [[ "$basename" == *"T1"* ]]; then
      # T1 => 1mm isotropic
      target_dims="1x1x1"
    elif [[ "$basename" == *"FLAIR"* ]]; then
      # FLAIR => keep z-dimension, standardize x,y to 1mm (THIS DESTROYS HIGH-RES DATA!)
      target_dims="1x1x${z_pix}"
    else
      # Default => keep original resolution
      target_dims="${x_pix}x${y_pix}x${z_pix}"
    fi
    log_formatted "WARNING" "Legacy mode may downsample high-resolution data"
  fi

  log_message "Current resolution: ${x_pix}x${y_pix}x${z_pix}mm"
  if [ "$use_reference_grid" = true ]; then
    log_message "Target: matching reference grid (ensures identical matrix dimensions)"
  else
    log_message "Target resolution: $target_dims mm"
  fi
  
  # Determine ANTs bin path
  local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
  
  # Execute resampling using enhanced ANTs command execution
  if [ "$use_reference_grid" = true ]; then
    # Resample to reference grid for identical matrix dimensions using antsApplyTransforms
    # NOTE: This is simple resampling, not transform application, so we use antsApplyTransforms directly
    execute_ants_command "resample_to_reference" "Resampling to reference grid for identical dimensions" \
      ${ants_bin}/antsApplyTransforms \
      -d 3 \
      -i "$input_file" \
      -r "$reference_file" \
      -o "$output_file" \
      -n Linear
  else
    # Standard resampling by voxel size
    # Check if ResampleImage is available, if not use antsApplyTransforms
    if command -v ResampleImage &> /dev/null; then
      execute_ants_command "resample_image" "Resampling image to standardized dimensions ($target_dims mm)" \
        ResampleImage \
        3 \
        "$input_file" \
        "$output_file" \
        "$target_dims" \
        0 \
        4
    else
      log_formatted "WARNING" "ResampleImage not available - using antsApplyTransforms for resampling"
      # Create a temporary reference image at the target resolution
      local temp_ref="${output_dir}/temp_reference.nii.gz"
      
      # Use c3d to create a reference image at target resolution if available
      if command -v c3d &> /dev/null; then
        c3d "$input_file" -resample-mm "$target_dims" -o "$temp_ref"
        execute_ants_command "resample_image" "Resampling image to standardized dimensions ($target_dims mm)" \
          antsApplyTransforms \
          -d 3 \
          -i "$input_file" \
          -r "$temp_ref" \
          -o "$output_file" \
          -n Linear
        rm -f "$temp_ref"
      else
        log_formatted "ERROR" "Neither ResampleImage nor c3d available for resampling"
        return 1
      fi
    fi
  fi

  local resample_status=$?
  if [ $resample_status -ne 0 ]; then
    log_formatted "ERROR" "Resampling failed with status $resample_status for: $input_file"
    return $ERR_PREPROC
  fi

  # Validate output file
  if ! validate_nifti "$output_file" "Standardized image"; then
    log_formatted "ERROR" "Standardized image validation failed: $output_file"
    return $ERR_DATA_CORRUPT
  fi
  
  log_message "Saved standardized image: $output_file"
  return 0
}

# Function to process cropping with padding
process_cropping_with_padding() {
  local file="$1"
  
  # Validate input file
  if ! validate_nifti "$file" "Input file for cropping"; then
    log_formatted "ERROR" "Invalid input file for cropping: $file"
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$file" .nii.gz)
  local output_dir=$(create_module_dir "cropped")
  local output_file=$(get_output_path "cropped" "$basename" "_cropped")

  log_message "Cropping w/ padding: $file"

  # Check if brain extraction mask exists
  local bias_dir=$(get_module_dir "bias_corrected")
  local mask_file="${bias_dir}/${basename}_BrainExtractionMask.nii.gz"
  
  if [ ! -f "$mask_file" ]; then
    log_formatted "WARNING" "Brain extraction mask not found: $mask_file"
    log_message "Running brain extraction first..."
    
    # Create temporary directory for brain extraction
    local temp_dir=$(create_module_dir "temp_brain_extraction")
    
    # Generate brain mask output paths
    local brain_prefix="${temp_dir}/${basename}_"

    # Run brain extraction with error checking
    if ! perform_brain_extraction "$file" "$brain_prefix"; then
      local brain_status=$?
      log_formatted "ERROR" "Brain extraction failed for cropping: $file (status: $brain_status)"
      return $ERR_PREPROC
    fi
    
    # Use the generated mask
    mask_file="${temp_dir}/${basename}_BrainExtractionMask.nii.gz"
    
    # Verify mask was created
    if [ ! -f "$mask_file" ]; then
      log_formatted "ERROR" "Brain extraction mask not created: $mask_file"
      return $ERR_PREPROC
    fi
  fi

  # Define cropping parameters (replace magic numbers)
  local crop_threshold="${C3D_CROP_THRESHOLD:-0.5}"  # Default threshold for brain mask
  local padding_mm="${C3D_PADDING_MM:-10}"           # Default padding in mm
  
  log_message "Using crop threshold: $crop_threshold, padding: ${padding_mm}mm"

  # c3d approach for cropping with padding
  if ! c3d "$file" -as S \
    "$mask_file" \
    -push S \
    -thresh "$crop_threshold" 1 1 0 \
    -trim "${padding_mm}mm" \
    -o "$output_file"; then
    local c3d_status=$?
    log_formatted "ERROR" "c3d cropping failed with status $c3d_status for: $file"
    return $ERR_PREPROC
  fi

  # Validate output file
  if ! validate_nifti "$output_file" "Cropped image"; then
    log_formatted "ERROR" "Cropped image validation failed: $output_file"
    return $ERR_DATA_CORRUPT
  fi
  
  log_message "Saved cropped file: $output_file"
  return 0
}

# Function to extract brain
extract_brain() {
  local input_file="$1"
  local output_prefix="$2"
  
  # Validate input file
  if ! validate_nifti "$input_file" "Input file for brain extraction"; then
    log_formatted "ERROR" "Invalid input file for brain extraction: $input_file"
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$input_file" .nii.gz)
  
  # Use provided output prefix if given, otherwise create default paths
  if [ -n "$output_prefix" ]; then
    local brain_prefix="$output_prefix"
    local output_file="${output_prefix}BrainExtractionBrain.nii.gz"
    local mask_file="${output_prefix}BrainExtractionMask.nii.gz"
  else
    local output_dir=$(create_module_dir "brain_extraction")
    local output_file=$(get_output_path "brain_extraction" "$basename" "_brain")
    local mask_file=$(get_output_path "brain_extraction" "$basename" "_brain_mask")
    local brain_prefix="${output_dir}/${basename}_"
  fi

  log_message "Extracting brain from $basename"

  # Run ANTs brain extraction with error checking
  if ! perform_brain_extraction "$input_file" "$brain_prefix"; then
    local brain_status=$?
    log_formatted "ERROR" "Brain extraction failed for $basename (status: $brain_status)"
    return $ERR_PREPROC
  fi

  # Source files from ANTs brain extraction
  local source_brain="${brain_prefix}BrainExtractionBrain.nii.gz"
  local source_mask="${brain_prefix}BrainExtractionMask.nii.gz"
  
  # Check if brain extraction was successful
  if [ ! -f "$source_brain" ] || [ ! -f "$source_mask" ]; then
    log_formatted "ERROR" "Brain extraction failed to create output files for $basename"
    return $ERR_PREPROC
  fi
  
  # Rename output files to standard names (only if using default paths)
  if [ -z "$output_prefix" ]; then
    if ! mv "$source_brain" "$output_file"; then
      log_formatted "ERROR" "Failed to move brain extraction output: $source_brain -> $output_file"
      return $ERR_FILE_CREATION
    fi
    
    if ! mv "$source_mask" "$mask_file"; then
      log_formatted "ERROR" "Failed to move brain mask: $source_mask -> $mask_file"
      return $ERR_FILE_CREATION
    fi
  else
    # When using custom output prefix, files are already in the correct location
    output_file="$source_brain"
    mask_file="$source_mask"
  fi
  
  # Validate output files
  if ! validate_nifti "$output_file" "Brain extraction output"; then
    log_formatted "ERROR" "Brain extraction output validation failed: $output_file"
    return $ERR_DATA_CORRUPT
  fi
  
  if ! validate_nifti "$mask_file" "Brain mask"; then
    log_formatted "ERROR" "Brain mask validation failed: $mask_file"
    return $ERR_DATA_CORRUPT
  fi

  log_message "Saved brain extraction: $output_file"
  log_message "Saved brain mask: $mask_file"
  return 0
}

# Function to run dimension standardization in parallel
run_parallel_standardize_dimensions() {
  local input_dir="${1:-$RESULTS_DIR/bias_corrected}"
  local pattern="${2:-*_n4.nii.gz}"
  local jobs="${3:-$PARALLEL_JOBS}"
  local max_depth="${4:-1}"
  local target_resolution="${5:-}"  # Optional optimal resolution
  
  log_message "Running standardize dimensions in parallel on files matching '$pattern' in $input_dir"
  
  if [ -n "$target_resolution" ]; then
    log_message "Using smart standardization with resolution: $target_resolution"
    # Export the target resolution for the parallel processes
    export PARALLEL_TARGET_RESOLUTION="$target_resolution"
  else
    log_formatted "WARNING" "No target resolution specified - using legacy mode"
    unset PARALLEL_TARGET_RESOLUTION
  fi
  
  # Ensure output directory exists
  create_module_dir "standardized"
  
  # Export required functions for parallel execution
  export -f standardize_dimensions log_message log_formatted
  export -f validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  export -f log_diagnostic execute_with_logging execute_ants_command
  
  # Create wrapper function for parallel execution that uses the exported resolution
  standardize_dimensions_wrapper() {
    local input_file="$1"
    if [ -n "${PARALLEL_TARGET_RESOLUTION:-}" ]; then
      standardize_dimensions "$input_file" "$PARALLEL_TARGET_RESOLUTION"
    else
      standardize_dimensions "$input_file"
    fi
  }
  export -f standardize_dimensions_wrapper
  
  # Run in parallel using the wrapper function
  run_parallel "standardize_dimensions_wrapper" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  # Clean up
  unset PARALLEL_TARGET_RESOLUTION
  
  if [ $status -ne 0 ]; then
    log_formatted "ERROR" "Parallel dimension standardization failed with status $status"
    return $status
  fi
  
  log_formatted "SUCCESS" "Completed parallel dimension standardization"
  return 0
}

# Function to run brain extraction in parallel
run_parallel_brain_extraction() {
  local input_dir="${1:-$RESULTS_DIR/bias_corrected}"
  local pattern="${2:-*_n4.nii.gz}"
  local jobs="${3:-$MAX_CPU_INTENSIVE_JOBS}"  # Use MAX_CPU_INTENSIVE_JOBS since this is CPU-intensive
  local max_depth="${4:-1}"
  
  log_message "Running brain extraction in parallel on files matching '$pattern' in $input_dir"
  
  # Ensure output directory exists
  create_module_dir "brain_extraction"
  
  # Export required functions for parallel execution
  export -f extract_brain log_message log_formatted
  export -f validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  export -f log_diagnostic execute_with_logging perform_brain_extraction execute_ants_command
  
  # Run in parallel using the common function
  run_parallel "extract_brain" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  if [ $status -ne 0 ]; then
    log_formatted "ERROR" "Parallel brain extraction failed with status $status"
    return $status
  fi
  
  log_formatted "SUCCESS" "Completed parallel brain extraction"
  return 0
}

# Export functions
export -f is_3d_isotropic_sequence
export -f calculate_resolution_quality
export -f calculate_inplane_resolution
export -f check_orientation_consistency
export -f check_detailed_orientation_matrices
export -f detect_optimal_resolution
export -f combine_multiaxis_images
export -f combine_multiaxis_images_highres
export -f standardize_dimensions
export -f process_cropping_with_padding
export -f extract_brain
export -f run_parallel_standardize_dimensions
export -f run_parallel_brain_extraction

log_message "Brain extraction module (extraction + standardization + cropping) loaded"