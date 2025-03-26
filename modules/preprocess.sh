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

# Function to combine multi-axial images
combine_multiaxis_images() {
  local sequence_type="$1"
  local output_dir="$2"
  mkdir -p "$output_dir"
  log_message "Combining multi-axis images for $sequence_type"

  # Find SAG, COR, AX
  local sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  local ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # pick best resolution from each orientation
  local best_sag="" best_cor="" best_ax=""
  local best_sag_res=0 best_cor_res=0 best_ax_res=0

  for file in "${sag_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_sag_res ]; then
      best_sag="$file"; best_sag_res=$res
    fi
  done
  for file in "${cor_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_cor_res ]; then
      best_cor="$file"; best_cor_res=$res
    fi
  done
  for file in "${ax_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_ax_res ]; then
      best_ax="$file"; best_ax_res=$res
    fi
  done

  local out_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"

  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG, COR, AX with antsMultivariateTemplateConstruction2.sh"
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
    log_formatted "SUCCESS" "Created high-res combined: $out_file"

  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    if [ -n "$best_sag" ]; then best_file="$best_sag"
    elif [ -n "$best_cor" ]; then best_file="$best_cor"
    elif [ -n "$best_ax" ]; then best_file="$best_ax"
    fi
    if [ -n "$best_file" ]; then
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_message "Used single orientation: $best_file"
    else
      log_formatted "ERROR" "No $sequence_type files found"
    fi
  fi
}

# Function to combine multi-axial images with high resolution
combine_multiaxis_images_highres() {
  local sequence_type="$1"
  local output_dir="$2"
  local resolution="${3:-1}"  # Default to 1mm isotropic
  
  log_message "Combining multi-axis images for $sequence_type with high resolution"
  
  # First combine using the standard function
  combine_multiaxis_images "$sequence_type" "$output_dir"
  
  # Get the combined file
  local combined_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"
  
  if [ ! -f "$combined_file" ]; then
    log_formatted "ERROR" "Combined file not found: $combined_file"
    return 1
  fi
  
  # Resample to high resolution
  local highres_file="${output_dir}/${sequence_type}_combined_highres_${resolution}mm.nii.gz"
  
  log_message "Resampling to ${resolution}mm isotropic resolution"
  ResampleImage 3 "$combined_file" "$highres_file" ${resolution}x${resolution}x${resolution} 0 4
  
  log_message "High-resolution combined image created: $highres_file"
  return 0
}

# Function to calculate in-plane resolution
calculate_inplane_resolution() {
  local file="$1"
  
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
  mkdir -p "${RESULTS_DIR}/metadata"
  if [ ! -f "$metadata_file" ]; then
    log_message "No metadata found. Using default ANTs parameters."
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
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"

  log_message "N4 bias correction: $file"
  mkdir -p "${RESULTS_DIR}/bias_corrected"
  
  # Brain extraction for a better mask
  antsBrainExtraction.sh -d 3 \
    -a "$file" \
    -k 1 \
    -o "${RESULTS_DIR}/bias_corrected/${basename}_" \
    -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
    -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
    -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

  local params=($(get_n4_parameters "$file"))
  local iters=${params[0]}
  local conv=${params[1]}
  local bspl=${params[2]}
  local shrk=${params[3]}

  N4BiasFieldCorrection -d 3 \
    -i "$file" \
    -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
    -o "$output_file" \
    -b "[$bspl]" \
    -s "$shrk" \
    -c "[$iters,$conv]"

  log_message "Saved bias-corrected image: $output_file"
  return 0
}

# Function to standardize dimensions
standardize_dimensions() {
  local input_file="$1"
  local basename=$(basename "$input_file" .nii.gz)
  local output_file="${RESULTS_DIR}/standardized/${basename}_std.nii.gz"

  log_message "Standardizing dimensions for $basename"
  mkdir -p "${RESULTS_DIR}/standardized"

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

  log_message "Saved standardized image: $output_file"
  return 0
}

# Function to process cropping with padding
process_cropping_with_padding() {
  local file="$1"
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"

  mkdir -p "${RESULTS_DIR}/cropped"
  log_message "Cropping w/ padding: $file"

  # Check if brain extraction mask exists
  local mask_file="${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz"
  if [ ! -f "$mask_file" ]; then
    log_formatted "WARNING" "Brain extraction mask not found: $mask_file"
    log_message "Running brain extraction first..."
    
    # Create temporary directory for brain extraction
    local temp_dir="${RESULTS_DIR}/temp_brain_extraction"
    mkdir -p "$temp_dir"
    
    # Run brain extraction
    antsBrainExtraction.sh -d 3 \
      -a "$file" \
      -k 1 \
      -o "${temp_dir}/${basename}_" \
      -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
      -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
      -f "$TEMPLATE_DIR/$REGISTRATION_MASK"
    
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

  log_message "Saved cropped file: $output_file"
  return 0
}

# Function to extract brain
extract_brain() {
  local input_file="$1"
  local basename=$(basename "$input_file" .nii.gz)
  local output_file="${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz"
  local mask_file="${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz"

  mkdir -p "${RESULTS_DIR}/brain_extraction"
  log_message "Extracting brain from $basename"

  # Run ANTs brain extraction
  antsBrainExtraction.sh -d 3 \
    -a "$input_file" \
    -k 1 \
    -o "${RESULTS_DIR}/brain_extraction/${basename}_" \
    -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
    -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
    -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

  # Rename output files to standard names
  mv "${RESULTS_DIR}/brain_extraction/${basename}_BrainExtractionBrain.nii.gz" "$output_file"
  mv "${RESULTS_DIR}/brain_extraction/${basename}_BrainExtractionMask.nii.gz" "$mask_file"

  log_message "Saved brain extraction: $output_file"
  log_message "Saved brain mask: $mask_file"
  return 0
}

# Export functions
export -f combine_multiaxis_images
export -f combine_multiaxis_images_highres
export -f calculate_inplane_resolution
export -f get_n4_parameters
export -f optimize_ants_parameters
export -f process_n4_correction
export -f standardize_dimensions
export -f process_cropping_with_padding
export -f extract_brain

log_message "Preprocessing module loaded"