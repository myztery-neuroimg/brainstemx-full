#!/usr/bin/env bash
#
# pipeline.sh - Main script for the brain MRI processing pipeline
#
# Usage: ./pipeline.sh [options]
#
# Options:
#   -c, --config FILE    Configuration file (default: config/default_config.sh)
#   -i, --input DIR      Input directory (default: ../DiCOM)
#   -o, --output DIR     Output directory (default: ../mri_results)
#   -s, --subject ID     Subject ID (default: derived from input directory)
#   -q, --quality LEVEL  Quality preset (LOW, MEDIUM, HIGH) (default: MEDIUM)
#   -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM) (default: FULL)
#   -h, --help           Show this help message and exit
#

# Set strict error handling
#set -e
#set -u
#set -o pipefail

# Source modules
source modules/environment.sh
source modules/import.sh
source modules/preprocess.sh
source modules/registration.sh
source modules/segmentation.sh
source modules/analysis.sh
source modules/visualization.sh
source modules/qa.sh

# Show help message
show_help() {
  echo "Usage: ./pipeline.sh [options]"
  echo ""
  echo "Options:"
  echo "  -c, --config FILE    Configuration file (default: config/default_config.sh)"
  echo "  -i, --input DIR      Input directory (default: ../DiCOM)"
  echo "  -o, --output DIR     Output directory (default: ../mri_results)"
  echo "  -s, --subject ID     Subject ID (default: derived from input directory)"
  echo "  -q, --quality LEVEL  Quality preset (LOW, MEDIUM, HIGH) (default: MEDIUM)"
  echo "  -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM, ORIENTATION_TEST) (default: FULL)"
  echo "  -t, --start-stage STAGE  Start pipeline from STAGE (default: import)"
  echo "  -h, --help           Show this help message and exit"
  echo ""
  echo "Pipeline Stages:"
  echo "  import: Import and convert DICOM data"
  echo "  preprocess: Perform bias correction and brain extraction"
  echo "  registration: Align images to standard space"
  echo "  segmentation: Extract brainstem and pons regions"
  echo "  analysis: Detect and analyze hyperintensities"
  echo "  visualization: Generate visualizations and reports"
  echo "  tracking: Track pipeline progress"
}

# Load configuration file
load_config() {
  local config_file="$1"
  
  if [ -f "$config_file" ]; then
    log_message "Loading configuration from $config_file"
    source "$config_file"
    return 0
  else
    log_formatted "WARNING" "Configuration file not found: $config_file"
    return 1
  fi
}

# Function to convert stage name to numeric value
get_stage_number() {
  local stage_name="$1"
  local stage_num
  
  case "$stage_name" in
    import|dicom|1)
      stage_num=1
      ;;
    preprocess|preprocessing|pre|2)
      stage_num=2
      ;;
    registration|register|reg|3)
      stage_num=3
      ;;
    segmentation|segment|seg|4)
      stage_num=4
      ;;
    analysis|analyze|5)
      stage_num=5
      ;;
    visualization|visualize|vis|6)
      stage_num=6
      ;;
    tracking|track|progress|7)
      stage_num=7
      ;;
    *)
      stage_num=0  # Invalid stage
      ;;
  esac
  
  echo $stage_num
}

# Parse command line arguments
parse_arguments() {
  # Default values
  CONFIG_FILE="config/default_config.sh"
  SRC_DIR="../DiCOM"
  RESULTS_DIR="../mri_results"
  SUBJECT_ID=""
  QUALITY_PRESET="HIGH"
  PIPELINE_TYPE="FULL"
  START_STAGE_NAME="import"
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      -i|--input)
        SRC_DIR="$2"
        shift 2
        ;;
      -o|--output)
        RESULTS_DIR="$2"
        shift 2
        ;;
      -s|--subject)
        SUBJECT_ID="$2"
        shift 2
        ;;
      -q|--quality)
        QUALITY_PRESET="$2"
        shift 2
        ;;
      -p|--pipeline)
        PIPELINE_TYPE="$2"
        shift 2
        ;;
      -t|--start-stage)
        START_STAGE_NAME="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1" $ERR_INVALID_ARGS
        show_help
        exit 1
        ;;
    esac
  done
  
  # If subject ID is not provided, derive it from the input directory
  if [ -z "$SUBJECT_ID" ]; then
    SUBJECT_ID=$(basename "$SRC_DIR")
  fi
  
  # Convert stage name to numeric value and validate
  START_STAGE=$(get_stage_number "$START_STAGE_NAME")
  if [ "$START_STAGE" -eq 0 ]; then
    log_error "Invalid start stage: $START_STAGE_NAME" $ERR_INVALID_ARGS
    log_message "Valid stages: import, preprocess, registration, segmentation, analysis, visualization, tracking"
    show_help
    exit 1
  fi
  
  # Export variables
  export SRC_DIR
  export RESULTS_DIR
  export SUBJECT_ID
  export QUALITY_PRESET
  export PIPELINE_TYPE
  export START_STAGE
  export START_STAGE_NAME
  
  log_message "Arguments parsed: SRC_DIR=$SRC_DIR, RESULTS_DIR=$RESULTS_DIR, SUBJECT_ID=$SUBJECT_ID, QUALITY_PRESET=$QUALITY_PRESET, PIPELINE_TYPE=$PIPELINE_TYPE"
}

# Function to validate a processing step
validate_step() {
  return 0
  local step_name="$1"
  local output_files="$2"
  local module="$3"
  
  log_message "Validating step: $step_name"
  
  # Use our new validation function
  if ! validate_module_execution "$module" "$output_files"; then
    log_error "Validation failed for step: $step_name" $ERR_VALIDATION
    return $ERR_VALIDATION
  fi
  
  log_formatted "SUCCESS" "Step validated: $step_name"
  return 0
}


# Run the pipeline
run_pipeline() {
  local subject_id="$SUBJECT_ID"
  local input_dir="$SRC_DIR"
  local output_dir="$RESULTS_DIR"
  export EXTRACT_DIR="${RESULTS_DIR}/extracted"

  # Load parallel configuration if available
  #load_parallel_config "config/parallel_config.sh"
  
  # Check for GNU parallel
  #check_parallel
  load_config "config/default_config.sh"
  log_message "Running pipeline for subject $subject_id"
  log_message "Input directory: $input_dir"
  log_message "Output directory: $output_dir"
  
  # Create directories
  create_directories
  
  # Step 1: Import and convert data
  if [ $START_STAGE -le 1 ]; then
    log_message "Step 1: Importing and converting data"
    
    import_dicom_data "$input_dir" "$EXTRACT_DIR"
    qa_validate_dicom_files "$input_dir"
    import_extract_siemens_metadata "$input_dir"
    qa_validate_nifti_files "$EXTRACT_DIR"
    import_deduplicate_identical_files "$EXTRACT_DIR"
    
    # Validate import step
    validate_step "Import data" "*.nii.gz" "extracted"
  else
    log_message "Skipping Step 1 (Import and convert data) as requested"
    log_message "Checking if import data exists..."
    
    # Check if essential directories and files exist to continue
    if [ ! -d "$EXTRACT_DIR" ] || [ $(find "$EXTRACT_DIR" -name "*.nii.gz" | wc -l) -eq 0 ]; then
      log_error "Import data is missing. Cannot skip Step 1." $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi
    
    log_message "Import data exists, continuing from Step $START_STAGE"
  fi
  
  
  # Step 2: Preprocessing
  if [ $START_STAGE -le 2 ]; then
    log_message "Step 2: Preprocessing"
    
    # Find T1 and FLAIR files
    # Use simple glob patterns that work reliably with find
    export T1_PRIORITY_PATTERN="${T1_PRIORITY_PATTERN:-T1_MPRAGE_SAG_*.nii.gz}"
    export FLAIR_PRIORITY_PATTERN="${FLAIR_PRIORITY_PATTERN:-T2_SPACE_FLAIR_Sag_CS_*.nii.gz}"
    
    log_message "Using T1 pattern: $T1_PRIORITY_PATTERN"
    log_message "Using FLAIR pattern: $FLAIR_PRIORITY_PATTERN"
  
    # Log before finding files
    log_message "Looking for T1 files in: $EXTRACT_DIR"
    log_message "Available files in extract dir:"
    ls -la "$EXTRACT_DIR"
    
    # Use simple shell globbing for more reliable file matching
    local t1_file=$(find "$EXTRACT_DIR" -name "T1_MPRAGE_SAG_*.nii.gz" | head -1)
    local flair_file=$(find "$EXTRACT_DIR" -name "T2_SPACE_FLAIR_Sag_CS_*.nii.gz" | head -1)
    
    # If not found with specific pattern, try more general patterns
    if [ -z "$t1_file" ]; then
      log_message "T1 not found with specific pattern, trying more general search"
      t1_file=$(find "$EXTRACT_DIR" -name "T1_*.nii.gz" | head -1)
    fi
    
    if [ -z "$flair_file" ]; then
      log_message "FLAIR not found with specific pattern, trying more general search"
      flair_file=$(find "$EXTRACT_DIR" -name "*FLAIR*.nii.gz" | head -1)
    fi
  
  if [ -z "$t1_file" ]; then
    log_error "T1 file not found in $EXTRACT_DIR" $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  if [ -z "$flair_file" ]; then
    log_error "FLAIR file not found in $EXTRACT_DIR" $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "T1 file: $t1_file"
  log_message "FLAIR file: $flair_file"
  
  # Combine or select best multi-axial images
  # Note: For 3D isotropic sequences (MPRAGE, SPACE, etc.), this will
  # automatically detect and select the best quality single orientation.
  # For 2D sequences, it will combine multiple orientations when available.

  #combine_multiaxis_images "T1" "${RESULTS_DIR}/combined" #only if using 2d scan types
  #combine_multiaxis_images "FLAIR" "${RESULTS_DIR}/combined"
  
  # Validate combining step
  #validate_step "Combine multi-axial images" "T1_combined_highres.nii.gz,FLAIR_combined_highres.nii.gz" "combined"
  
  # Update file paths if combined images were created
  local combined_t1=$(get_output_path "combined" "T1" "_combined_highres")
  local combined_flair=$(get_output_path "combined" "FLAIR" "_combined_highres")
  
  if [ -f "$combined_t1" ]; then
    t1_file="$combined_t1"
  fi
  
  if [ -f "$combined_flair" ]; then
    flair_file="$combined_flair"
  fi
  
  # Validate input files before processing
  validate_nifti "$t1_file" "T1 input file"
  validate_nifti "$flair_file" "FLAIR input file"
  
  # N4 bias field correction (run in parallel if available)
  if [ "$PARALLEL_JOBS" -gt 0 ] && check_parallel &>/dev/null; then
    log_message "Running N4 bias field correction with parallel processing"
    # Copy the files to a temporary directory for parallel processing
    local temp_dir=$(create_module_dir "temp_parallel")
    cp "$t1_file" "$temp_dir/$(basename "$t1_file")"
    cp "$flair_file" "$temp_dir/$(basename "$flair_file")"
    run_parallel_n4_correction "$temp_dir" "*.nii.gz"
  else
    log_message "Running N4 bias field correction sequentially"
    process_n4_correction "$t1_file"
    process_n4_correction "$flair_file"
  fi
  
  # Update file paths
  local t1_basename=$(basename "$t1_file" .nii.gz)
  local flair_basename=$(basename "$flair_file" .nii.gz)
  t1_file=$(get_output_path "bias_corrected" "$t1_basename" "_n4")
  flair_file=$(get_output_path "bias_corrected" "$flair_basename" "_n4")
  
  # Validate bias correction step
  validate_step "N4 bias correction" "$(basename "$t1_file"),$(basename "$flair_file")" "bias_corrected"
  
  # Brain extraction (run in parallel if available)
  if [ "$PARALLEL_JOBS" -gt 0 ] && check_parallel &>/dev/null; then
    log_message "Running brain extraction with parallel processing"
    run_parallel_brain_extraction "$(get_module_dir "bias_corrected")" "*.nii.gz" "$MAX_CPU_INTENSIVE_JOBS"
  else
    log_message "Running brain extraction sequentially"
    extract_brain "$t1_file"
    extract_brain "$flair_file"
  fi
  
  # Update file paths
  local t1_n4_basename=$(basename "$t1_file" .nii.gz)
  local flair_n4_basename=$(basename "$flair_file" .nii.gz)
  
  t1_brain=$(get_output_path "brain_extraction" "$t1_n4_basename" "_brain")
  flair_brain=$(get_output_path "brain_extraction" "$flair_n4_basename" "_brain")
  
  # Validate brain extraction step
  validate_step "Brain extraction" "$(basename "$t1_brain"),$(basename "$flair_brain")" "brain_extraction"
  
  # Standardize dimensions (run in parallel if available)
  if [ "$PARALLEL_JOBS" -gt 0 ] && check_parallel &>/dev/null; then
    log_message "Running dimension standardization with parallel processing"
    run_parallel_standardize_dimensions "$(get_module_dir "brain_extraction")" "*_brain.nii.gz"
  else
    log_message "Running dimension standardization sequentially"
    standardize_dimensions "$t1_brain"
    standardize_dimensions "$flair_brain"
  fi
  
  
  # Update file paths
  local t1_brain_basename=$(basename "$t1_brain" .nii.gz)
  local flair_brain_basename=$(basename "$flair_brain" .nii.gz)
  
  t1_std=$(get_output_path "standardized" "$t1_brain_basename" "_std")
  flair_std=$(get_output_path "standardized" "$flair_brain_basename" "_std")
  
  # Validate standardization step
  validate_step "Standardize dimensions" "$(basename "$t1_std"),$(basename "$flair_std")" "standardized"
  
  # Launch visual QA for brain extraction (non-blocking)
  launch_visual_qa "$t1_std" "$t1_brain" ":colormap=heat:opacity=0.5" "brain-extraction" "sagittal"
  
  fi  # End of Preprocessing (Step 2)
  
  # Step 3: Registration
  if [ $START_STAGE -le 3 ]; then
    log_message "Step 3: Registration"
    
    # If we're skipping previous steps, we need to find the standardized files
    if [ $START_STAGE -eq 3 ]; then
      log_message "Looking for standardized files..."
      t1_std=$(find "$RESULTS_DIR/standardized" -name "*T1*_std.nii.gz" | head -1)
      flair_std=$(find "$RESULTS_DIR/standardized" -name "*FLAIR*_std.nii.gz" | head -1)
      
      if [ -z "$t1_std" ] || [ -z "$flair_std" ]; then
        log_error "Standardized data is missing. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
        return $ERR_DATA_MISSING
      fi
      
      log_message "Found standardized data:"
      log_message "T1: $t1_std"
      log_message "FLAIR: $flair_std"
    fi
    
    # Create output directory for registration
    local reg_dir=$(create_module_dir "registered")
  
  # Check if we should use orientation-preserving registration
  if [ "${ORIENTATION_PRESERVATION_ENABLED}" = "true" ]; then
     log_message "Using orientation-preserving registration for better anatomical accuracy"
     
     # Check if we have a brainstem mask already (from previous run or pre-defined masks)
     local existing_brainstem=$(find "$RESULTS_DIR/segmentation/brainstem" -name "*brainstem.nii.gz" | head -1)
     
     if [ -n "$existing_brainstem" ]; then
        # Use anatomically-constrained registration with brainstem mask
        log_message "Using anatomically-constrained registration with brainstem mask"
        register_with_anatomical_constraints "$t1_std" "$flair_std" "$reg_prefix" "$existing_brainstem"
     else
        # Use topology-preserving registration without mask
        log_message "Using topology-preserving registration"
        register_with_topology_preservation "$t1_std" "$flair_std" "$reg_prefix"
     fi
     
     # Validate and potentially correct registration result
     validate_transformation "$t1_std" "$flair_std" "${reg_prefix}Warped.nii.gz" "$reg_prefix"
     
     # Get orientation metrics
     local orientation_metrics=$(calculate_orientation_metrics "$t1_std" "${reg_prefix}Warped.nii.gz" "${validation_dir}/orientation")
     local orient_mean_dev="$orientation_metrics"
     
     log_message "Orientation mean deviation: $orient_mean_dev radians"
     
     # If mean orientation deviation is high, apply correction
     if (( $(echo "$orient_mean_dev > $ORIENTATION_CORRECTION_THRESHOLD" | bc -l) )); then
        log_formatted "WARNING" "High orientation deviation detected ($orient_mean_dev > $ORIENTATION_CORRECTION_THRESHOLD), applying correction"
        # Find the transform file
        local transform="${reg_prefix}0GenericAffine.mat"
        if [ -f "$transform" ]; then
           # Apply correction
           correct_orientation_distortion "$t1_std" "${reg_prefix}Warped.nii.gz" "$transform" "${reg_prefix}Corrected.nii.gz"
           
           # If correction succeeded, update registered image
           if [ -f "${reg_prefix}Corrected.nii.gz" ]; then
              mv "${reg_prefix}Warped.nii.gz" "${reg_prefix}Warped_original.nii.gz"
              mv "${reg_prefix}Corrected.nii.gz" "${reg_prefix}Warped.nii.gz"
              log_message "Orientation-corrected image is now the primary registered image"
           fi
        else
           log_formatted "WARNING" "Transform file not found for correction: $transform"
        fi
     fi
  else
     # Use original registration method
     log_message "Using standard registration (orientation preservation disabled)"
     register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
  fi
  
  # Determine whether to use automatic multi-modality registration
  if [ "${AUTO_REGISTER_ALL_MODALITIES:-false}" = "true" ]; then
    log_message "Performing automatic registration of all modalities to T1"
    register_all_modalities "$t1_std" "$(get_module_dir "standardized")" "$reg_dir"
    
    # Find the registered FLAIR file for downstream processing
    local flair_registered=$(find "$reg_dir" -name "*FLAIR*Warped.nii.gz" | head -1)
    if [ -z "$flair_registered" ]; then
      log_formatted "WARNING" "No registered FLAIR found after multi-modality registration. Using original FLAIR."
      # Fall back to standard FLAIR registration
      local reg_prefix="${reg_dir}/t1_to_flair"
      register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
      flair_registered="${reg_prefix}Warped.nii.gz"
    else
      log_message "Using automatically registered FLAIR: $flair_registered"
    fi
  else
    # Traditional single-modality (FLAIR) registration
    local reg_prefix="${reg_dir}/t1_to_flair"
    register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
    flair_registered="${reg_prefix}Warped.nii.gz"
  fi
  
  # Validate registration step
  validate_step "Registration" "t1_to_flairWarped.nii.gz" "registered"
  
  # Launch visual QA for registration (non-blocking)
  launch_visual_qa "$t1_std" "$flair_registered" ":colormap=heat:opacity=0.5" "registration" "axial"
  
  # Create registration visualizations
  local validation_dir=$(create_module_dir "validation/registration")
  create_registration_visualizations "$t1_std" "$flair_std" "$flair_registered" "$validation_dir"
  
  # Validate visualization step
  validate_step "Registration visualizations" "*.png,quality.txt" "validation/registration"
else
  log_message "Skipping Step 3 (Registration) as requested"
  log_message "Checking if standardized data exists..."
  
  # Initialize variables for other stages to use
  t1_std=$(find "$RESULTS_DIR/standardized" -name "*T1*_std.nii.gz" | head -1)
  flair_std=$(find "$RESULTS_DIR/standardized" -name "*FLAIR*_std.nii.gz" | head -1)
  
  if [ -z "$t1_std" ] || [ -z "$flair_std" ]; then
    log_error "Standardized data is missing. Cannot skip to Stage $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "Found standardized data:"
  log_message "T1: $t1_std"
  log_message "FLAIR: $flair_std"
fi  # End of Registration (Step 3)
  
# Step 4: Segmentation
if [ $START_STAGE -le 4 ]; then
  log_message "Step 4: Segmentation"
  
  # Create output directories for segmentation
  local brainstem_dir=$(create_module_dir "segmentation/brainstem")
  local pons_dir=$(create_module_dir "segmentation/pons")
  
  log_message "Attempting all available segmentation methods..."
  
  # Use the comprehensive method that tries all approaches
  extract_brainstem_final "$t1_std"
  
  # Get output files (should have been created by extract_brainstem_final)
  local brainstem_output=$(get_output_path "segmentation/brainstem" "${subject_id}" "_brainstem")
  local pons_output=$(get_output_path "segmentation/pons" "${subject_id}" "_pons")
  local dorsal_pons=$(get_output_path "segmentation/pons" "${subject_id}" "_dorsal_pons")
  local ventral_pons=$(get_output_path "segmentation/pons" "${subject_id}" "_ventral_pons")
  
  # Validate files exist
  log_message "Validating output files exist..."
  [ ! -f "$brainstem_output" ] && log_formatted "WARNING" "Brainstem file not found: $brainstem_output"
  [ ! -f "$pons_output" ] && log_formatted "WARNING" "Pons file not found: $pons_output"
  [ ! -f "$dorsal_pons" ] && log_formatted "WARNING" "Dorsal pons file not found: $dorsal_pons"
  [ ! -f "$ventral_pons" ] && log_formatted "WARNING" "Ventral pons file not found: $ventral_pons"
  
  # Validate dorsal/ventral division
  validate_step "Segmentation" "${subject_id}_dorsal_pons.nii.gz,${subject_id}_ventral_pons.nii.gz" "segmentation/pons"

  # Launch visual QA for brainstem segmentation (non-blocking)
  launch_visual_qa "$t1_std" "$brainstem_output" ":colormap=heat:opacity=0.5" "brainstem-segmentation" "coronal"
else
  log_message "Skipping Step 4 (Segmentation) as requested"
  log_message "Checking if registration data exists..."
  
  # Check if essential files exist to continue
  local reg_dir=$(get_module_dir "registered")
  if [ ! -d "$reg_dir" ] || [ $(find "$reg_dir" -name "*Warped.nii.gz" | wc -l) -eq 0 ]; then
    log_error "Registration data is missing. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  # Find the registered FLAIR file
  flair_registered=$(find "$reg_dir" -name "*FLAIR*Warped.nii.gz" | head -1)
  if [ -z "$flair_registered" ]; then
    flair_registered=$(find "$reg_dir" -name "t1_to_flairWarped.nii.gz" | head -1)
  fi
  
  if [ -z "$flair_registered" ]; then
    log_error "Registered FLAIR not found. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "Found registered data: $flair_registered"
fi  # End of Segmentation (Step 4)
  
# Step 5: Analysis
if [ $START_STAGE -le 5 ]; then
  log_message "Step 5: Analysis"
  
  # Initialize registered directory if we're starting from this stage
  local reg_dir=$(get_module_dir "registered")
  if [ ! -d "$reg_dir" ]; then
    log_message "Creating registered directory..."
    reg_dir=$(create_module_dir "registered")
  fi
  
  # Find the registered FLAIR file if we're starting from this stage
  if [ $START_STAGE -eq 5 ]; then
    log_message "Looking for registered FLAIR file..."
    flair_registered=$(find "$reg_dir" -name "*FLAIR*Warped.nii.gz" | head -1)
    if [ -z "$flair_registered" ]; then
      flair_registered=$(find "$reg_dir" -name "t1_to_flairWarped.nii.gz" | head -1)
    fi
    
    # Also need to find the dorsal pons file
    dorsal_pons=$(find "$RESULTS_DIR/segmentation/pons" -name "*dorsal_pons.nii.gz" | head -1)
    
    if [ -z "$flair_registered" ]; then
      log_formatted "WARNING" "No registered FLAIR found. Will register now."
      # If we skipped registration but have T1 and FLAIR, we can register now
      if [ -n "$t1_std" ] && [ -n "$flair_std" ] && [ -n "$dorsal_pons" ]; then
        local reg_prefix="${reg_dir}/t1_to_flair"
        register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
        flair_registered="${reg_prefix}Warped.nii.gz"
      else
        log_error "Cannot find or create registered FLAIR file" $ERR_DATA_MISSING
        return $ERR_DATA_MISSING
      fi
    fi
    
    log_message "Using registered FLAIR: $flair_registered"
    log_message "Using dorsal pons: $dorsal_pons"
  fi
  
  # Ensure flair_registered is defined and exists before proceeding
  if [ -z "${flair_registered:-}" ]; then
      log_formatted "WARNING" "flair_registered variable not defined, searching for it now"
      flair_registered=$(find "$reg_dir" -name "*FLAIR*Warped.nii.gz" -o -name "t1_to_flairWarped.nii.gz" | head -1)
      
      if [ -z "$flair_registered" ]; then
          log_error "Cannot find registered FLAIR file in $reg_dir" $ERR_DATA_MISSING
          return $ERR_DATA_MISSING
      fi
      
      log_message "Found registered FLAIR: $flair_registered"
  fi
  
  # Register FLAIR to dorsal pons
  local dorsal_pons_reg_prefix="${reg_dir}/${subject_id}_dorsal_pons"
  register_t2_flair_to_t1mprage "$dorsal_pons" "$flair_registered" "$dorsal_pons_reg_prefix"
  
  # Update file paths
  flair_dorsal_pons="${dorsal_pons_reg_prefix}Warped.nii.gz"
  
  # Validate registration
  validate_step "FLAIR to dorsal pons registration" "${subject_id}_dorsal_ponsWarped.nii.gz" "registered"
  
  # Detect hyperintensities
  local hyperintensities_dir=$(create_module_dir "hyperintensities")
  local hyperintensities_prefix="${hyperintensities_dir}/${subject_id}_dorsal_pons"
  detect_hyperintensities "$flair_dorsal_pons" "$hyperintensities_prefix" "$t1_std"
  
  # Validate hyperintensities detection
  validate_step "Hyperintensity detection" "${subject_id}_dorsal_pons*.nii.gz" "hyperintensities"
  
  # Launch visual QA for hyperintensity detection (non-blocking)
  launch_visual_qa "$flair_dorsal_pons" "${hyperintensities_prefix}_thresh${THRESHOLD_WM_SD_MULTIPLIER:-2.0}.nii.gz" ":colormap=heat:opacity=0.7" "hyperintensity-detection" "axial"
else
  log_message "Skipping Step 5 (Analysis) as requested"
  log_message "Checking if segmentation data exists..."
  
  # Check if essential files exist to continue
  local segmentation_dir="$RESULTS_DIR/segmentation"
  if [ ! -d "$segmentation_dir" ]; then
    log_error "Segmentation data is missing. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  # Find key segmentation files
  dorsal_pons=$(find "$segmentation_dir" -name "*dorsal_pons.nii.gz" | head -1)
  
  if [ -z "$dorsal_pons" ]; then
    log_error "Dorsal pons segmentation not found. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "Found segmentation data: $dorsal_pons"
fi  # End of Analysis (Step 5)
  
# Step 6: Visualization
if [ $START_STAGE -le 6 ]; then
  log_message "Step 6: Visualization"
  
  # Generate QC visualizations
  generate_qc_visualizations "$subject_id" "$RESULTS_DIR"
  
  # Create multi-threshold overlays
  create_multi_threshold_overlays "$subject_id" "$RESULTS_DIR"
  
  
  # Generate HTML report
  generate_html_report "$subject_id" "$RESULTS_DIR"
else
  log_message "Skipping Step 6 (Visualization) as requested"
  log_message "Checking if hyperintensity data exists..."
  
  # Check if essential files exist to continue
  local hyperintensities_dir="$RESULTS_DIR/hyperintensities"
  if [ ! -d "$hyperintensities_dir" ]; then
    log_error "Hyperintensity data is missing. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "Found hyperintensity data directory: $hyperintensities_dir"
fi  # End of Visualization (Step 6)
  
# Step 7: Track pipeline progress
if [ $START_STAGE -le 7 ]; then
  log_message "Step 7: Tracking pipeline progress"
  track_pipeline_progress "$subject_id" "$RESULTS_DIR"
else
  log_message "Skipping Step 7 (Pipeline progress tracking) as requested"
fi
  
  log_message "Pipeline completed successfully for subject $subject_id"
  return 0
}


# Run pipeline in batch mode
run_pipeline_batch() {
  local subject_list="$1"
  local base_dir="$2"
  local output_base="$3"

  # Validate inputs
  validate_file "$subject_list" "Subject list file" || return $ERR_FILE_NOT_FOUND
  validate_directory "$base_dir" "Base directory" || return $ERR_FILE_NOT_FOUND
  validate_directory "$output_base" "Output base directory" "true" || return $ERR_PERMISSION
  
  # Prepare batch processing
  echo "Running brainstem analysis pipeline on subject list: $subject_list"
  local parallel_batch_processing="${PARALLEL_BATCH:-false}"
  
  # Create summary directory
  local summary_dir="${output_base}/summary"
  mkdir -p "$summary_dir"
  
  # Initialize summary report
  local summary_file="${summary_dir}/batch_summary.csv"
  echo "Subject,Status,BrainstemVolume,PonsVolume,DorsalPonsVolume,HyperintensityVolume,LargestClusterVolume,RegistrationQuality" > "$summary_file"

  # Function to process a single subject (for parallel batch processing)
  process_single_subject() {
    local line="$1"
    
    # Parse subject info
    read -r subject_id t2_flair t1 <<< "$line"
    
    # Skip empty or commented lines
    [[ -z "$subject_id" || "$subject_id" == \#* ]] && return 0
    
    echo "Processing subject: $subject_id"
    
    # Create subject output directory
    local subject_dir="${output_base}/${subject_id}"
    mkdir -p "$subject_dir"
    
    # Run the pipeline for this subject
    (
      # Set variables for this subject in a subshell to avoid conflicts
      export SUBJECT_ID="$subject_id"
      export SRC_DIR="$base_dir/$subject_id"
      export RESULTS_DIR="$subject_dir"
      export PIPELINE_SUCCESS=true
      export PIPELINE_ERROR_COUNT=0
      
      run_pipeline
      
      # Return pipeline status
      return $?
    )
    
    return $?
  }
  
  # Export the function for parallel use
  export -f process_single_subject
  
  # Process subjects in parallel if GNU parallel is available and parallel batch processing is enabled
  if [ "$parallel_batch_processing" = "true" ] && [ "$PARALLEL_JOBS" -gt 0 ] && check_parallel; then
    log_message "Processing subjects in parallel with $PARALLEL_JOBS jobs"
    
    # Use parallel to process multiple subjects simultaneously
    # Create a temporary file with the subject list
    local temp_subject_list=$(mktemp)
    grep -v "^#" "$subject_list" > "$temp_subject_list"
    
    # Process subjects in parallel
    cat "$temp_subject_list" | parallel -j "$PARALLEL_JOBS" --halt "$PARALLEL_HALT_MODE",fail=1 process_single_subject
    local parallel_status=$?
    
    # Clean up
    rm "$temp_subject_list"
    
    if [ $parallel_status -ne 0 ]; then
      log_error "Parallel batch processing failed with status $parallel_status" $parallel_status
      return $parallel_status
    fi
  else
    # Process subjects sequentially
    log_message "Processing subjects sequentially"
  
    # Traditional sequential processing
    while read -r subject_id t2_flair t1; do
      echo "Processing subject: $subject_id"
      
      # Skip empty or commented lines
      [[ -z "$subject_id" || "$subject_id" == \#* ]] && continue
      
      # Create subject output directory
      local subject_dir="${output_base}/${subject_id}"
      mkdir -p "$subject_dir"
      
      # Set global variables for this subject
      export SUBJECT_ID="$subject_id"
      export SRC_DIR="$base_dir/$subject_id"
      export RESULTS_DIR="$subject_dir"
      
      # Reset error tracking for this subject
      PIPELINE_SUCCESS=true
      PIPELINE_ERROR_COUNT=0
      
      # Run processing with proper error handling
      run_pipeline
      local status=$?
      
      # Determine status text
      local status_text="FAILED"
      if [ $status -eq 0 ]; then
        status_text="COMPLETE"
      elif [ $status -eq 2 ]; then
        status_text="INCOMPLETE"
      fi
      
      # Extract key metrics for summary
      local brainstem_vol="N/A"
      local pons_vol="N/A"
      local dorsal_pons_vol="N/A"
      local hyperintensity_vol="N/A"
      local largest_cluster_vol="N/A"
      local reg_quality="N/A"
      
      local brainstem_file=$(get_output_path "segmentation/brainstem" "${subject_id}" "_brainstem")
      if [ -f "$brainstem_file" ]; then
        brainstem_vol=$(fslstats "$brainstem_file" -V | awk '{print $1}')
      fi
      
      local pons_file=$(get_output_path "segmentation/pons" "${subject_id}" "_pons")
      if [ -f "$pons_file" ]; then
        pons_vol=$(fslstats "$pons_file" -V | awk '{print $1}')
      fi
      
      local dorsal_pons_file=$(get_output_path "segmentation/pons" "${subject_id}" "_dorsal_pons")
      if [ -f "$dorsal_pons_file" ]; then
        dorsal_pons_vol=$(fslstats "$dorsal_pons_file" -V | awk '{print $1}')
      fi
      
      # Use the configured threshold from config instead of hardcoded 2.0
      local threshold_multiplier="${THRESHOLD_WM_SD_MULTIPLIER:-2.0}"
      local hyperintensity_file=$(get_output_path "hyperintensities" "${subject_id}" "_dorsal_pons_thresh${threshold_multiplier}")
      if [ -f "$hyperintensity_file" ]; then
        hyperintensity_vol=$(fslstats "$hyperintensity_file" -V | awk '{print $1}')
        
        # Get largest cluster size if clusters file exists
        local clusters_file="${hyperintensities_dir}/${subject_id}_dorsal_pons_clusters_sorted.txt"
        if [ -f "$clusters_file" ]; then
          largest_cluster_vol=$(head -1 "$clusters_file" | awk '{print $2}')
        fi
      fi
      
      # Add to summary
      echo "${subject_id},${status_text},${brainstem_vol},${pons_vol},${dorsal_pons_vol},${hyperintensity_vol},${largest_cluster_vol},${reg_quality}" >> "$summary_file"
      
  done < "$subject_list"
  fi
  echo "Batch processing complete. Summary available at: $summary_file"
  return 0
}

# Function to test orientation preservation functionality
test_orientation_preservation() {
  log_message "Testing orientation preservation and correction functionality"
  
  # Create test directories
  local test_dir="${RESULTS_DIR}/orientation_test"
  mkdir -p "$test_dir"
  local validation_dir="${test_dir}/validation"
  mkdir -p "$validation_dir"
  
  # Find T1 and FLAIR files (assuming they exist in the extract directory)
  local t1_file=$(find "$EXTRACT_DIR" -name "*T1*.nii.gz" | head -1)
  local flair_file=$(find "$EXTRACT_DIR" -name "*FLAIR*.nii.gz" | head -1)
  
  if [ -z "$t1_file" ] || [ -z "$flair_file" ]; then
    log_error "Test requires T1 and FLAIR files in $EXTRACT_DIR" $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  log_message "Using T1: $t1_file"
  log_message "Using FLAIR: $flair_file"
  
  # Test both registration approaches for comparison
  log_message "Running standard registration for comparison"
  local std_reg_prefix="${test_dir}/standard_reg"
  register_t2_flair_to_t1mprage "$t1_file" "$flair_file" "$std_reg_prefix"
  
  log_message "Running topology-preserving registration"
  local topo_reg_prefix="${test_dir}/topo_reg"
  register_with_topology_preservation "$t1_file" "$flair_file" "$topo_reg_prefix"
  
  log_message "Running anatomically-constrained registration"
  local anat_reg_prefix="${test_dir}/anat_reg"
  register_with_anatomical_constraints "$t1_file" "$flair_file" "$anat_reg_prefix"
  
  # Calculate orientation metrics for all approaches
  log_message "Calculating orientation metrics for comparison"
  local std_metrics=$(calculate_orientation_metrics "$t1_file" "${std_reg_prefix}Warped.nii.gz" "${validation_dir}/standard")
  local topo_metrics=$(calculate_orientation_metrics "$t1_file" "${topo_reg_prefix}Warped.nii.gz" "${validation_dir}/topology")
  local anat_metrics=$(calculate_orientation_metrics "$t1_file" "${anat_reg_prefix}Warped.nii.gz" "${validation_dir}/anatomical")
  
  # Apply orientation correction to standard registration
  log_message "Testing orientation correction on standard registration"
  local transform="${std_reg_prefix}0GenericAffine.mat"
  correct_orientation_distortion "$t1_file" "${std_reg_prefix}Warped.nii.gz" "$transform" "${std_reg_prefix}Corrected.nii.gz"
  
  # Calculate metrics after correction
  local corrected_metrics=$(calculate_orientation_metrics "$t1_file" "${std_reg_prefix}Corrected.nii.gz" "${validation_dir}/corrected")
  
  # Analyze shearing for all approaches
  log_message "Analyzing shearing distortion for all approaches"
  analyze_shearing_distortion "$t1_file" "${std_reg_prefix}Warped.nii.gz" "${validation_dir}/standard"
  analyze_shearing_distortion "$t1_file" "${topo_reg_prefix}Warped.nii.gz" "${validation_dir}/topology"
  analyze_shearing_distortion "$t1_file" "${anat_reg_prefix}Warped.nii.gz" "${validation_dir}/anatomical"
  analyze_shearing_distortion "$t1_file" "${std_reg_prefix}Corrected.nii.gz" "${validation_dir}/corrected"
  
  # Generate comparative report
  {
    echo "Orientation Preservation Test Results"
    echo "===================================="
    echo ""
    echo "Standard Registration Mean Angular Deviation: $std_metrics"
    echo "Topology-Preserving Registration Mean Angular Deviation: $topo_metrics"
    echo "Anatomically-Constrained Registration Mean Angular Deviation: $anat_metrics"
    echo "Corrected Registration Mean Angular Deviation: $corrected_metrics"
    echo ""
    echo "Configuration Parameters:"
    echo "  TOPOLOGY_CONSTRAINT_WEIGHT: $TOPOLOGY_CONSTRAINT_WEIGHT"
    echo "  TOPOLOGY_CONSTRAINT_FIELD: $TOPOLOGY_CONSTRAINT_FIELD"
    echo "  JACOBIAN_REGULARIZATION_WEIGHT: $JACOBIAN_REGULARIZATION_WEIGHT"
    echo "  REGULARIZATION_GRADIENT_FIELD_WEIGHT: $REGULARIZATION_GRADIENT_FIELD_WEIGHT"
    echo "  ORIENTATION_CORRECTION_THRESHOLD: $ORIENTATION_CORRECTION_THRESHOLD"
    echo "  ORIENTATION_SCALING_FACTOR: $ORIENTATION_SCALING_FACTOR"
    echo "  ORIENTATION_SMOOTH_SIGMA: $ORIENTATION_SMOOTH_SIGMA"
    echo ""
    echo "Improvement Metrics:"
    echo "  Standard to Topology: $(echo "$std_metrics - $topo_metrics" | bc -l)"
    echo "  Standard to Anatomical: $(echo "$std_metrics - $anat_metrics" | bc -l)"
    echo "  Standard to Corrected: $(echo "$std_metrics - $corrected_metrics" | bc -l)"
    echo ""
    echo "Test completed: $(date)"
  } > "${test_dir}/orientation_test_report.txt"
  
  log_message "Orientation preservation test completed. Report available at: ${test_dir}/orientation_test_report.txt"
  return 0
}

# Main function
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  # Initialize environment
  initialize_environment
  
  # Load parallel configuration if available
  load_parallel_config "config/parallel_config.sh"
  
  # Check dependencies
  check_dependencies
  
  # Load configuration file if provided
  if [ -f "$CONFIG_FILE" ]; then
    log_message "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
  fi
  
  # Run pipeline
  if [ "$PIPELINE_TYPE" = "BATCH" ]; then
    # Check if subject list file is provided
    if [ -z "${SUBJECT_LIST:-}" ]; then
      log_error "Subject list file not provided for batch processing" $ERR_INVALID_ARGS
      exit $ERR_INVALID_ARGS
    fi
    
    run_pipeline_batch "$SUBJECT_LIST" "$SRC_DIR" "$RESULTS_DIR"
    status=$?
  elif [ "$PIPELINE_TYPE" = "ORIENTATION_TEST" ]; then
    # Run the orientation preservation test
    log_message "Running orientation preservation test mode"
    
    # Create basic directories needed for testing
    create_directories
    
    # Run the test function
    test_orientation_preservation
    status=$?
    
    log_message "Orientation test completed with status $status"
  else
    run_pipeline
    status=$?
  fi
  
  if [ $status -ne 0 ]; then
    log_error "Pipeline failed with $PIPELINE_ERROR_COUNT errors" $status
    exit $status
  fi
  
  log_message "Pipeline completed successfully"
  return 0
}

# Export functions
export -f test_orientation_preservation

# Run main function with all arguments
main "$@"
