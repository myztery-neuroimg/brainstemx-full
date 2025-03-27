#!/usr/bin/env bash
#
# preprocess.sh - Preprocessing functions for the brain MRI processing pipeline
#
# This module contains:
# - Multi-axial integration
# - N4 bias field correction
# - Brain extraction
# - Dimension standardization
# - Cropping with padding
#

# Function to detect 3D isotropic sequences
# This function identifies 3D sequences like MPRAGE, SPACE, or 3D FLAIR
# Returns 0 (true) if the sequence is detected as 3D isotropic, 1 (false) otherwise
is_3d_isotropic_sequence() {
  local file="$1"
  local filename=$(basename "$file")
  
  # Check filename first (fast path)
  if [[ "$filename" == *"MPRAGE"* ]] || 
     [[ "$filename" == *"SPACE"* ]] || 
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

# Common brain extraction function to remove duplication
perform_brain_extraction() {
  local input_file="$1"
  local output_prefix="$2"
  
  # Validate input file
  if ! validate_nifti "$input_file" "Input file for brain extraction"; then
    log_error "Invalid input file for brain extraction: $input_file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  log_message "Running brain extraction on: $(basename "$input_file")"
  
  # Run ANTs brain extraction
  antsBrainExtraction.sh -d 3 \
    -a "$input_file" \
    -k 1 \
    -o "$output_prefix" \
    -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
    -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
    -f "$TEMPLATE_DIR/$REGISTRATION_MASK"
    
  # Validate output files
  local brain_file="${output_prefix}BrainExtractionBrain.nii.gz"
  local mask_file="${output_prefix}BrainExtractionMask.nii.gz"
  
  if [ ! -f "$brain_file" ] || [ ! -f "$mask_file" ]; then
    log_error "Brain extraction failed to produce output files" $ERR_PREPROC
    return $ERR_PREPROC
  fi
  
  return 0
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
    log_error "DICOM extraction directory not found: $EXTRACT_DIR" $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi

  # Find SAG, COR, AX
  local sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  
  local ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  #iStore all files for 3D detection
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
      validate_nifti "$out_file" "3D volume (single orientation)"
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
    antsMultivariateTemplateConstruction2.sh \
      -d 3 \
      -o "${output_dir}/${sequence_type}_template_" \
      -i $TEMPLATE_ITERATIONS \
      -g $TEMPLATE_GRADIENT_STEP \
      -j $ANTS_THREADS \
      -f $TEMPLATE_SHRINK_FACTORS \
      -s $TEMPLATE_SMOOTHING_SIGMAS \
      -q $TEMPLATE_WEIGHTS \
      -t $TEMPLATE_TRANSFORM_MODEL \
      -m $TEMPLATE_SIMILARITY_METRIC \
      -c 0 \
      "$best_sag" "$best_cor" "$best_ax"

    mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$out_file"
    standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
    validate_nifti "$out_file" "Combined high-res image"
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
      validate_nifti "$out_file" "Combined fallback image"
      log_formatted "SUCCESS" "Used single orientation: $best_file"
      return 0
    else
      log_error "No $sequence_type files found" $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi
  fi
}

# Function to combine multi-axial images with high resolution
combine_multiaxis_images_highres() {
  local sequence_type="$1"
  local output_dir="$2"
  local resolution="${3:-1}"  # Default to 1mm isotropic

  # Create output directory
  output_dir=$(create_module_dir "combined")
  
  log_message "Combining multi-axis images for $sequence_type with high resolution"
  
  # First combine using the standard function
  combine_multiaxis_images "$sequence_type" "$output_dir"
  local combine_status=$?
  if [ $combine_status -ne 0 ]; then
    log_error "Failed to combine multi-axial images" $combine_status
    return $combine_status
  fi
  
  # Get the combined file
  local combined_file=$(get_output_path "combined" "${sequence_type}" "_combined_highres")
  
  # Validate combined file
  if ! validate_nifti "$combined_file" "Combined file"; then
    log_error "Combined file validation failed: $combined_file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  # Resample to high resolution
  local highres_file=$(get_output_path "combined" "${sequence_type}" "_combined_highres_${resolution}mm")
  
  log_message "Resampling to ${resolution}mm isotropic resolution"
  ResampleImage 3 "$combined_file" "$highres_file" ${resolution}x${resolution}x${resolution} 0 4
  
  # Validate highres file
  validate_nifti "$highres_file" "High-resolution image"
  
  log_message "High-resolution combined image created: $highres_file"
  return 0
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
    log_error "Invalid input file for N4 correction: $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$file" .nii.gz)
  local output_file=$(get_output_path "bias_corrected" "$basename" "_n4")
  local output_dir=$(get_module_dir "bias_corrected")
  
  # Ensure output directory exists
  mkdir -p "$output_dir"

  log_message "N4 bias correction: $file"
  
  # Generate brain mask output paths
  local brain_prefix="${output_dir}/${basename}_"
  local brain_mask="${brain_prefix}BrainExtractionMask.nii.gz"
  
  # Brain extraction for a better mask
  perform_brain_extraction "$file" "$brain_prefix"
  
  # Check if brain mask was created
  if [ ! -f "$brain_mask" ]; then
    log_error "Brain extraction failed to create mask: $brain_mask" $ERR_PREPROC
    return $ERR_PREPROC
  fi

  # Get sequence-specific parameters
  local params=($(get_n4_parameters "$file"))
  local iters=${params[0]}
  local conv=${params[1]}
  local bspl=${params[2]}
  local shrk=${params[3]}

  # Run N4 bias correction
  N4BiasFieldCorrection -d 3 \
    -i "$file" \
    -x "$brain_mask" \
    -o "$output_file" \
    -b "[$bspl]" \
    -s "$shrk" \
    -c "[$iters,$conv]"

  # Validate output file
  validate_nifti "$output_file" "N4 bias-corrected image"
  log_message "Saved bias-corrected image: $output_file"
  return 0
}

# Function to standardize dimensions
standardize_dimensions() {
  local input_file="$1"
  
  # Validate input file
  if ! validate_nifti "$input_file" "Input file for standardization"; then
    log_error "Invalid input file for standardization: $input_file" $ERR_DATA_CORRUPT
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

  # Determine target dimensions based on sequence type
  local target_dims=""
  if [[ "$basename" == *"T1"* ]]; then
    # T1 => 1mm isotropic
    target_dims="1x1x1"
  elif [[ "$basename" == *"FLAIR"* ]]; then
    # FLAIR => keep z-dimension, standardize x,y
    target_dims="1x1x${z_pix}"
  else
    # Default => keep original resolution
    target_dims="${x_pix}x${y_pix}x${z_pix}"
  fi

  log_message "Resampling to $target_dims mm resolution"
  ResampleImage 3 "$input_file" "$output_file" "$target_dims" 0 4

  # Validate output file
  validate_nifti "$output_file" "Standardized image"
  
  log_message "Saved standardized image: $output_file"
  return 0
}

# ------------------------------------------------------------------------------
# Parallel processing functions
# ------------------------------------------------------------------------------

# Function to run N4 bias field correction in parallel
run_parallel_n4_correction() {
  local input_dir="${1:-$EXTRACT_DIR}"
  local pattern="${2:-*.nii.gz}"
  local jobs="${3:-$PARALLEL_JOBS}"
  local max_depth="${4:-1}"
  
  log_message "Running N4 bias correction in parallel on files matching '$pattern' in $input_dir"
  
  # Ensure output directory exists
  create_module_dir "bias_corrected"
  
  # Export required functions for parallel execution
  export -f process_n4_correction get_n4_parameters log_message log_formatted
  export -f log_error validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  
  # Run in parallel using the common function
  run_parallel "process_n4_correction" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  if [ $status -ne 0 ]; then
    log_error "Parallel N4 bias correction failed with status $status" $ERR_PREPROC
    return $status
  fi
  
  log_formatted "SUCCESS" "Completed parallel N4 bias correction"
  return 0
}

# Function to run dimension standardization in parallel
run_parallel_standardize_dimensions() {
  local input_dir="${1:-$RESULTS_DIR/bias_corrected}"
  local pattern="${2:-*_n4.nii.gz}"
  local jobs="${3:-$PARALLEL_JOBS}"
  local max_depth="${4:-1}"
  
  log_message "Running standardize dimensions in parallel on files matching '$pattern' in $input_dir"
  
  # Ensure output directory exists
  create_module_dir "standardized"
  
  # Export required functions for parallel execution
  export -f standardize_dimensions log_message log_formatted
  export -f log_error validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  
  # Run in parallel using the common function
  run_parallel "standardize_dimensions" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  if [ $status -ne 0 ]; then
    log_error "Parallel dimension standardization failed with status $status" $ERR_PREPROC
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
  export -f log_error validate_nifti validate_file
  export -f get_output_path get_module_dir create_module_dir
  
  # Run in parallel using the common function
  run_parallel "extract_brain" "$pattern" "$input_dir" "$jobs" "$max_depth"
  local status=$?
  
  if [ $status -ne 0 ]; then
    log_error "Parallel brain extraction failed with status $status" $ERR_PREPROC
    return $status
  fi
  
  log_formatted "SUCCESS" "Completed parallel brain extraction"
  return 0
}

# Function to process cropping with padding
process_cropping_with_padding() {
  local file="$1"
  
  # Validate input file
  if ! validate_nifti "$file" "Input file for cropping"; then
    log_error "Invalid input file for cropping: $file" $ERR_DATA_CORRUPT
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

    # Run brain extraction
    perform_brain_extraction "$file" "$brain_prefix"
    
    # Use the generated mask
    mask_file="${temp_dir}/${basename}_BrainExtractionMask.nii.gz"
  fi

  # c3d approach for cropping with padding
  c3d "$file" -as S \
    "$mask_file" \
    -push S \
    -thresh $C3D_CROP_THRESHOLD 1 1 0 \
    -trim ${C3D_PADDING_MM}mm \
    -o "$output_file"

  # Validate output file
  validate_nifti "$output_file" "Cropped image"
  
  log_message "Saved cropped file: $output_file"
  return 0
}

# Function to extract brain
extract_brain() {
  local input_file="$1"
  
  # Validate input file
  if ! validate_nifti "$input_file" "Input file for brain extraction"; then
    log_error "Invalid input file for brain extraction: $input_file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  local basename=$(basename "$input_file" .nii.gz)
  local output_dir=$(create_module_dir "brain_extraction")
  local output_file=$(get_output_path "brain_extraction" "$basename" "_brain")
  local mask_file=$(get_output_path "brain_extraction" "$basename" "_brain_mask")
  
  # Generate brain mask output paths
  local brain_prefix="${output_dir}/${basename}_"

  log_message "Extracting brain from $basename"

  # Run ANTs brain extraction
  perform_brain_extraction "$input_file" "$brain_prefix"

  # Source files from ANTs brain extraction
  local source_brain="${brain_prefix}BrainExtractionBrain.nii.gz"
  local source_mask="${brain_prefix}BrainExtractionMask.nii.gz"
  
  # Check if brain extraction was successful
  if [ ! -f "$source_brain" ] || [ ! -f "$source_mask" ]; then
    log_error "Brain extraction failed for $basename" $ERR_PREPROC
    return $ERR_PREPROC
  fi
  
  # Rename output files to standard names
  mv "$source_brain" "$output_file"
  mv "$source_mask" "$mask_file"
  
  # Validate output files
  validate_nifti "$output_file" "Brain extraction output" && validate_nifti "$mask_file" "Brain mask"

  log_message "Saved brain extraction: $output_file"
  log_message "Saved brain mask: $mask_file"
  return 0
}

# Export functions
export -f combine_multiaxis_images
export -f combine_multiaxis_images_highres
export -f is_3d_isotropic_sequence
export -f calculate_resolution_quality
export -f perform_brain_extraction
export -f calculate_inplane_resolution
export -f get_n4_parameters
export -f optimize_ants_parameters
export -f process_n4_correction
export -f run_parallel_n4_correction
export -f run_parallel_standardize_dimensions
export -f run_parallel_brain_extraction
export -f standardize_dimensions
export -f process_cropping_with_padding
export -f extract_brain

log_message "Preprocessing module loaded"