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
#   -t, --start-stage STAGE  Start pipeline from STAGE (default: import)
#   --quiet              Minimal output (errors and completion only)
#   --verbose            Detailed output with technical parameters
#   --debug              Full output including all ANTs technical details
#   -h, --help           Show this help message and exit
#

# Set strict error handling
#set -e
#set -u
#set -o pipefail

# Source modules
source src/modules/environment.sh
source src/modules/utils.sh     # Load utilities module with execute_ants_command
source src/modules/fast_wrapper.sh # Load FAST wrapper with parallel processing
source src/modules/dicom_analysis.sh
source src/modules/import.sh
source src/modules/preprocess.sh
source src/modules/registration.sh
source src/modules/segmentation.sh
source src/modules/analysis.sh
source src/modules/visualization.sh
source src/modules/qa.sh
source src/modules/scan_selection.sh  # Add scan selection module
source src/modules/reference_space_selection.sh  # Add reference space selection module
source src/modules/enhanced_registration_validation.sh  # Add enhanced registration validation
#source src/modules/extract_dicom_metadata.py

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
  echo "  -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM) (default: FULL)"
  echo "  -t, --start-stage STAGE  Start pipeline from STAGE (default: import)"
  echo "  --quiet              Minimal output (errors and completion only)"
  echo "  --verbose            Detailed output with technical parameters"
  echo "  --debug              Full output including all ANTs technical details"
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
  echo ""
  echo "Verbosity Levels:"
  echo "  normal (default): Balanced output with stage progression and key information"
  echo "  --quiet:          Minimal output, only errors and completion status"
  echo "  --verbose:        Detailed output including technical parameters"
  echo "  --debug:          Full output with all ANTs technical details saved to logs"
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
  SRC_DIR="..../DiCOM"
  RESULTS_DIR="../mri_results"
  SUBJECT_ID=""
  QUALITY_PRESET="MEIDUM"
  PIPELINE_TYPE="FULL"
  START_STAGE_NAME="import"
  
  # Set default verbosity level
  export PIPELINE_VERBOSITY="normal"
  
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
      --quiet)
        export PIPELINE_VERBOSITY="quiet"
        shift
        ;;
      --verbose)
        export PIPELINE_VERBOSITY="verbose"
        shift
        ;;
      --debug)
        export PIPELINE_VERBOSITY="debug"
        shift
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
  
  # Convert stage name to number and validate
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
  
  log_message "Arguments parsed: SRC_DIR=$SRC_DIR, RESULTS_DIR=$RESULTS_DIR, SUBJECT_ID=$SUBJECT_ID, QUALITY_PRESET=$QUALITY_PRESET, PIPELINE_TYPE=$PIPELINE_TYPE, VERBOSITY=$PIPELINE_VERBOSITY"
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
  
  # Create DICOM header analysis for better scan selection
  log_message "Analyzing DICOM headers for scan selection..."
  analyze_dicom_headers "$SRC_DIR" "${RESULTS_DIR}/metadata/dicom_header_analysis.txt"
  
  # Use adaptive reference space selection
  log_message "Running adaptive reference space selection..."
  local selection_result=$(select_optimal_reference_space "$SRC_DIR" "$EXTRACT_DIR" "${REFERENCE_SPACE_SELECTION_MODE:-adaptive}")
  
  # Parse the selection result: modality|file|rationale
  local selected_modality=$(echo "$selection_result" | cut -d'|' -f1)
  local selected_file=$(echo "$selection_result" | cut -d'|' -f2)
  local selection_rationale=$(echo "$selection_result" | cut -d'|' -f3)
  
  log_formatted "SUCCESS" "Reference space selected: $selected_modality"
  log_message "Selected file: $(basename "$selected_file")"
  log_message "Rationale: $selection_rationale"
  
  # Assign files based on selection result
  if [ "$selected_modality" = "T1" ]; then
    local t1_file="$selected_file"
    # Find the best FLAIR for this T1
    local flair_file=$(select_best_scan "FLAIR" "*FLAIR*.nii.gz" "$EXTRACT_DIR" "$t1_file" "${FLAIR_SELECTION_MODE:-registration_optimized}")
  elif [ "$selected_modality" = "FLAIR" ]; then
    local flair_file="$selected_file"
    # Find the best T1 for this FLAIR
    local t1_file=$(select_best_scan "T1" "*T1*.nii.gz" "$EXTRACT_DIR" "$flair_file" "${T1_SELECTION_MODE:-highest_resolution}")
  else
    log_error "Reference space selection failed: $selection_rationale" $ERR_DATA_MISSING
    return $ERR_DATA_MISSING
  fi
  
  # Log detailed resolution information about selected scans
  if [ -n "$t1_file" ] && [ -n "$flair_file" ]; then
    log_message "======== Selected Scan Information ========"
    log_message "T1 scan: $t1_file"
    log_message "T1 dimensions: $(fslinfo "$t1_file" | grep -E "^dim[1-3]" | awk '{print $1 "=" $2}' | tr '\n' ' ')"
    log_message "T1 voxel size: $(fslinfo "$t1_file" | grep -E "^pixdim[1-3]" | awk '{print $1 "=" $2}' | tr '\n' ' ')"
    log_message ""
    log_message "FLAIR scan: $flair_file"
    log_message "FLAIR dimensions: $(fslinfo "$flair_file" | grep -E "^dim[1-3]" | awk '{print $1 "=" $2}' | tr '\n' ' ')"
    log_message "FLAIR voxel size: $(fslinfo "$flair_file" | grep -E "^pixdim[1-3]" | awk '{print $1 "=" $2}' | tr '\n' ' ')"
    log_message ""
    log_message "Resolution comparison: $(calculate_pixdim_similarity "$t1_file" "$flair_file")/100"
    log_message "======================================="
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
  
  # Early orientation consistency checking
  log_formatted "INFO" "===== ORIENTATION CONSISTENCY CHECK ====="
  log_message "Checking if T1 and FLAIR have consistent orientations..."
  
  if check_orientation_consistency "$t1_file" "$flair_file"; then
    log_formatted "SUCCESS" "No orientation issues detected"
  else
    log_formatted "WARNING" "Orientation inconsistencies found - this may cause FSL warnings"
    log_message "Performing detailed orientation matrix comparison..."
    check_detailed_orientation_matrices "$t1_file" "$flair_file"
    log_message "Note: These warnings typically don't affect analysis quality"
    log_message "Smart standardization will ensure consistent coordinate spaces"
  fi
  
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
  # Launch visual QA for brain extraction (non-blocking)
  # Moving this after standardization since t1_std is defined later
  # Will be launched after line 315 where t1_std is defined
  
  # Smart standardization: detect optimal resolution across T1 and FLAIR
  log_formatted "INFO" "===== SMART RESOLUTION DETECTION ====="
  local optimal_resolution=$(detect_optimal_resolution "$t1_brain" "$flair_brain")
  
  # Validate the resolution format
  if [ -z "$optimal_resolution" ] || ! echo "$optimal_resolution" | grep -E "^[0-9.]+x[0-9.]+x[0-9.]+$" > /dev/null; then
    log_error "Invalid optimal resolution format: '$optimal_resolution'" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  log_formatted "SUCCESS" "Optimal resolution detected: $optimal_resolution mm"
  log_message "T1 will be used as reference space for segmentation consistency"
  
  # Standardize dimensions using optimal resolution with reference grid approach
  log_message "Running smart dimension standardization with reference grid approach"
  log_message "This ensures T1 and FLAIR have IDENTICAL matrix dimensions while preserving highest resolution"
  
  # Always use T1 as reference for segmentation consistency
  local ref_file="$t1_brain"
  local other_file="$flair_brain"
  local ref_name="T1"
  local other_name="FLAIR"
  
  # Check if we're downsampling FLAIR
  local t1_inplane=$(echo "scale=6; ($(fslval "$t1_brain" pixdim1) + $(fslval "$t1_brain" pixdim2)) / 2" | bc -l)
  local flair_inplane=$(echo "scale=6; ($(fslval "$flair_brain" pixdim1) + $(fslval "$flair_brain" pixdim2)) / 2" | bc -l)
  
  if (( $(echo "$flair_inplane < $t1_inplane" | bc -l) )); then
    log_formatted "INFO" "FLAIR has higher resolution (${flair_inplane}mm vs ${t1_inplane}mm) but using T1 as reference"
    log_message "This maintains 'T1 native space' consistency for atlas-based segmentation"
    log_message "FLAIR will be downsampled to match T1 grid for identical dimensions"
  else
    log_formatted "SUCCESS" "T1 has equal or higher resolution - optimal for segmentation"
  fi
  
  # Step 1: Standardize T1 first (always reference for segmentation)
  log_message "Standardizing T1 with optimal resolution: $optimal_resolution"
  standardize_dimensions "$ref_file" "$optimal_resolution"
  
  # Get the standardized T1 file path
  local ref_basename=$(basename "$ref_file" .nii.gz)
  local ref_std=$(get_output_path "standardized" "$ref_basename" "_std")
  
  # Step 2: Standardize FLAIR using T1 as reference grid
  log_message "Standardizing FLAIR using T1 as reference grid for identical dimensions"
  standardize_dimensions "$other_file" "$optimal_resolution" "$ref_std"
  
  # Update file paths - T1 is always reference
  local t1_brain_basename=$(basename "$t1_brain" .nii.gz)
  local flair_brain_basename=$(basename "$flair_brain" .nii.gz)
  
  t1_std=$(get_output_path "standardized" "$t1_brain_basename" "_std")      # Reference T1 (native space)
  flair_std=$(get_output_path "standardized" "$flair_brain_basename" "_std") # FLAIR resampled to T1 grid
  
  log_formatted "SUCCESS" "Both scans standardized in T1 native space with identical dimensions"
  
  # Validate standardization step
  validate_step "Standardize dimensions" "$(basename "$t1_std"),$(basename "$flair_std")" "standardized"
  
  # Launch enhanced visual QA for brain extraction with better error handling and guidance
  enhanced_launch_visual_qa "$t1_std" "$t1_brain" ":colormap=heat:opacity=0.5" "brain-extraction" "sagittal"
  
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
      
      # Clean up any previous registration outputs when starting from this stage
      log_message "Cleaning up previous registration outputs for fresh start..."
      local reg_dir="$RESULTS_DIR/registered"
      if [ -d "$reg_dir" ]; then
        rm -rf "$reg_dir"
        log_message "Removed previous registration directory: $reg_dir"
      fi
    else
      # Only run registration fix if we're continuing from previous stages
      # This will check for coordinate space mismatches and fix datatypes
      log_message "Running registration issue fixing tool for data continuity..."
      run_registration_fix
    fi
    
    # Create output directory for registration
    local reg_dir=$(create_module_dir "registered")
    
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
      # MAIN REGISTRATION EXECUTION - This was missing!
      log_formatted "INFO" "===== EXECUTING MAIN REGISTRATION ====="
      log_message "Registering FLAIR to T1 using enhanced ANTs pipeline"
      
      # Check if registration already exists (for resume functionality)
      local reg_prefix="${reg_dir}/$(basename "$flair_std" .nii.gz)_to_t1"
      local existing_registered="${reg_prefix}Warped.nii.gz"
      
      if [ -f "$existing_registered" ] && [ -s "$existing_registered" ]; then
        log_message "Found existing registration: $existing_registered"
        log_message "Skipping registration (use clean output directory to force re-registration)"
        flair_registered="$existing_registered"
      else
        log_message "Running FLAIR to T1 registration..."
        log_message "Input T1: $t1_std"
        log_message "Input FLAIR: $flair_std"
        log_message "Output prefix: $reg_prefix"
        
        # Call the main registration function
        register_modality_to_t1 "$t1_std" "$flair_std" "FLAIR" "$reg_prefix"
        local reg_status=$?
        
        if [ $reg_status -eq 0 ] && [ -f "${reg_prefix}Warped.nii.gz" ]; then
          log_formatted "SUCCESS" "Registration completed successfully"
          flair_registered="${reg_prefix}Warped.nii.gz"
        else
          log_formatted "ERROR" "Registration failed with status $reg_status"
          return $ERR_REGISTRATION
        fi
      fi
      
      log_message "Registration output: $flair_registered"
      # Validate coordinate spaces and datatypes
      log_formatted "INFO" "===== VALIDATING DATA BEFORE REGISTRATION ====="
      local val_dir="${reg_dir}/validation"
      mkdir -p "$val_dir"
      
      # Check datatypes and report findings
      local t1_datatype=$(fslinfo "$t1_std" | grep "^data_type" | awk '{print $2}')
      local flair_datatype=$(fslinfo "$flair_std" | grep "^data_type" | awk '{print $2}')
      
      log_message "Original datatypes - T1: $t1_datatype, FLAIR: $flair_datatype"
      
      # Standardize datatypes but preserve FLOAT32 for intensity data
      local t1_fmt="$t1_std"
      local flair_fmt="$flair_std"
      
      if [ "$t1_datatype" != "FLOAT32" ]; then
        log_message "Converting T1 to FLOAT32 for optimal precision..."
        t1_fmt="${reg_dir}/t1_FLOAT32.nii.gz"
        standardize_image_format "$t1_std" "" "$t1_fmt" "FLOAT32"
      fi
      
      if [ "$flair_datatype" != "FLOAT32" ]; then
        log_message "Converting FLAIR to FLOAT32 for optimal precision..."
        flair_fmt="${reg_dir}/flair_FLOAT32.nii.gz"
        standardize_image_format "$flair_std" "" "$flair_fmt" "FLOAT32"
      fi
      
      # STEP 1: Register FLAIR to T1 in native high resolution space
      # This maintains the high resolution of FLAIR & T1 data
      log_formatted "INFO" "===== REGISTERING FLAIR TO T1 IN NATIVE SPACE ====="
      log_message "This preserves the original resolution of both scans"
      
      local reg_prefix="${reg_dir}/t1_to_flair"
      log_message "Running registration with standardized datatypes..."
      register_t2_flair_to_t1mprage "$t1_fmt" "$flair_fmt" "$reg_prefix"
      flair_registered="${reg_prefix}Warped.nii.gz"
      
      # STEP 2: Calculate and store transforms between spaces but don't apply them yet
      log_formatted "INFO" "===== CALCULATING TRANSFORMS BETWEEN SPACES ====="
      local transform_dir="${reg_dir}/transforms"
      mkdir -p "$transform_dir"
      
      # Calculate T1 to MNI transform (but don't actually resample the high-res data)
      log_message "Calculating bidirectional transforms between native and MNI space..."
      local t1_mni_transform="${transform_dir}/t1_to_mni.mat"
      local mni_to_t1_transform="${transform_dir}/mni_to_t1.mat"
      
      # Create transforms in both directions
      flirt -in "$t1_fmt" -ref "$MNI_TEMPLATE" -omat "$t1_mni_transform" -dof 12
      convert_xfm -omat "$mni_to_t1_transform" -inverse "$t1_mni_transform"
      
      log_message "Transforms created for bidirectional conversion between spaces"
      log_message "Native → MNI: $t1_mni_transform"
      log_message "MNI → Native: $mni_to_t1_transform"
      
      # For QA/validation, optionally create MNI space version of T1
      local mni_dir="${reg_dir}/mni_space"
      mkdir -p "$mni_dir"
      local t1_mni="${mni_dir}/t1_to_mni.nii.gz"
      apply_transform "$t1_fmt" "$MNI_TEMPLATE" "$t1_mni_transform" "$t1_mni"
      
      # STEP 3: Create functions for applying standard masks
      log_formatted "INFO" "===== PREPARING FOR STANDARD ATLAS USAGE ====="
      
      # Create function to transform standard masks to subject space
      transform_standard_mask_to_subject() {
        local standard_mask="$1"    # Mask in MNI space
        local output="$2"           # Output in subject space
        
        log_message "Transforming standard mask to subject space: $standard_mask"
        apply_transform "$standard_mask" "$t1_fmt" "$mni_to_t1_transform" "$output" "nearestneighbour"
      }
      
      # Export the function for use downstream
      export -f transform_standard_mask_to_subject
      
      # Transform key Harvard masks as an example
      local harvard_dir="${reg_dir}/harvard_masks"
      mkdir -p "$harvard_dir"
      
      if [ -f "$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-Cortical-Maxprob-thr25-1mm.nii.gz" ]; then
        transform_standard_mask_to_subject \
          "$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-Cortical-Maxprob-thr25-1mm.nii.gz" \
          "${harvard_dir}/harvard_cortical_native.nii.gz"
        log_message "Harvard cortical atlas transformed to subject space"
      else
        log_formatted "WARNING" "Harvard cortical atlas not found"
      fi
    fi
    
    # Validate registration step
    validate_step "Registration" "t1_to_flairWarped.nii.gz" "registered"
    
    # Launch enhanced visual QA for registration (non-blocking) with better error handling
    enhanced_launch_visual_qa "$t1_std" "$flair_registered" ":colormap=heat:opacity=0.5" "registration" "axial"
    
    # Create registration visualizations
    local validation_dir=$(create_module_dir "validation/registration")
    
    # Log final datatypes of all files to verify proper handling of UINT8 vs INT16 issues
    log_formatted "INFO" "===== FINAL DATATYPE VERIFICATION ====="
    log_message "T1 standardized: $(fslinfo "$t1_std" | grep "^data_type" | awk '{print $2}')"
    log_message "FLAIR standardized: $(fslinfo "$flair_std" | grep "^data_type" | awk '{print $2}')"
    log_message "FLAIR registered: $(fslinfo "$flair_registered" | grep "^data_type" | awk '{print $2}')"
    
    # Check binary masks (they should be UINT8)
    log_message "MNI template mask: $(fslinfo "$FSLDIR/data/standard/MNI152_T1_1mm_brain_mask.nii.gz" 2>/dev/null | grep "^data_type" | awk '{print $2}' || echo "Not found")"
    
    # Verify registration quality specifically with our enhanced metrics
    verify_registration_quality "$t1_std" "$flair_registered" "${validation_dir}/quality_metrics"
    
    # Create standard registration visualizations
    create_registration_visualizations "$t1_std" "$flair_std" "$flair_registered" "$validation_dir"
    
    # Validate visualization step
    validate_step "Registration visualizations" "*.png,quality.txt" "validation/registration"
  else
    log_message "Skipping Step 3 Registration as requested"
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
    if ! extract_brainstem_final "$t1_std"; then
        log_formatted "ERROR" "Segmentation failed - critical pipeline step failed"
        log_formatted "ERROR" "Cannot proceed without valid segmentation data"
        return 1
    fi
    
    log_formatted "SUCCESS" "Segmentation completed successfully"
    
    # Get output files (should have been created by extract_brainstem_final)
    # Use the basename of the T1 file, not subject_id
    local t1_basename=$(basename "$t1_std" .nii.gz)
    local brainstem_output=$(get_output_path "segmentation/brainstem" "${t1_basename}" "_brainstem")
    local pons_output=$(get_output_path "segmentation/pons" "${t1_basename}" "_pons")
    local dorsal_pons=$(get_output_path "segmentation/pons" "${t1_basename}" "_dorsal_pons")
    local ventral_pons=$(get_output_path "segmentation/pons" "${t1_basename}" "_ventral_pons")
    
    # Validate files exist
    log_message "Validating output files exist..."
    [ ! -f "$brainstem_output" ] && log_formatted "WARNING" "Brainstem file not found: $brainstem_output"
    [ ! -f "$pons_output" ] && log_formatted "WARNING" "Pons file not found: $pons_output"
    
    # Note: Dorsal/ventral pons subdivision is not available from Juelich atlas
    # These files are created as compatibility placeholders by the segmentation module
    if [ ! -f "$dorsal_pons" ]; then
        log_formatted "INFO" "Dorsal pons placeholder not found (will be created): $dorsal_pons"
    fi
    if [ ! -f "$ventral_pons" ]; then
        log_formatted "INFO" "Ventral pons placeholder not found (will be created): $ventral_pons"
    fi

    # Validate main segmentation files (dorsal/ventral are just compatibility placeholders)
    validate_step "Segmentation" "${t1_basename}_brainstem.nii.gz,${t1_basename}_pons.nii.gz" "segmentation"
  
    # The brainstem output already contains intensity values, no need to create another
    log_message "Using existing intensity segmentation masks for visualization..."
    local brainstem_intensity="$brainstem_output"  # This already contains T1 intensities
    local dorsal_pons_intensity="$dorsal_pons"      # For consistency
    
    # Only create intensity versions if the outputs are binary masks
    if [ -f "$brainstem_output" ]; then
        local max_val=$(fslstats "$brainstem_output" -R | awk '{print $2}')
        if (( $(echo "$max_val <= 1" | bc -l) )); then
            log_message "Brainstem output appears to be binary, creating intensity version..."
            brainstem_intensity="${RESULTS_DIR}/segmentation/brainstem/${t1_basename}_brainstem_intensity.nii.gz"
            create_intensity_mask "$brainstem_output" "$t1_std" "$brainstem_intensity"
        fi
    fi
    
    if [ -f "$dorsal_pons" ]; then
        local max_val=$(fslstats "$dorsal_pons" -R | awk '{print $2}')
        if (( $(echo "$max_val <= 1" | bc -l) )); then
            log_message "Dorsal pons output appears to be binary, creating intensity version..."
            dorsal_pons_intensity="${RESULTS_DIR}/segmentation/pons/${t1_basename}_dorsal_pons_intensity.nii.gz"
            create_intensity_mask "$dorsal_pons" "$t1_std" "$dorsal_pons_intensity"
        fi
    fi
    
    # Note: Segmentation location verification moved to QA module
    # Use qa_verify_all_segmentations function for comprehensive validation
    
    # Launch enhanced visual QA for brainstem segmentation (non-blocking)
    enhanced_launch_visual_qa "$t1_std" "$brainstem_intensity" ":colormap=heat:opacity=0.5" "brainstem-segmentation" "coronal"
  else
    log_message 'Skipping Step 4 (Segmentation) as requested'
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
    
    # Find original T1 and FLAIR files (needed for space transformation)
    log_message "Looking for original T1 and FLAIR files..."
    # Look for brain-extracted files first, avoid mask files
    local orig_t1=$(find "${RESULTS_DIR}/brain_extraction" -name "*T1*brain.nii.gz" | head -1)
    local orig_flair=$(find "${RESULTS_DIR}/brain_extraction" -name "*FLAIR*brain.nii.gz" | head -1)
    
    if [[ -z "$orig_t1" || -z "$orig_flair" ]]; then
      log_formatted "WARNING" "Brain-extracted files not found, trying bias_corrected directory"
      # Avoid mask files by excluding them explicitly
      orig_t1=$(find "${RESULTS_DIR}/bias_corrected" -name "*T1*.nii.gz" ! -name "*Mask*" | head -1)
      orig_flair=$(find "${RESULTS_DIR}/bias_corrected" -name "*FLAIR*.nii.gz" ! -name "*Mask*" | head -1)
    fi
    
    if [[ -z "$orig_t1" || -z "$orig_flair" ]]; then
      log_formatted "WARNING" "Files not found in bias_corrected, trying extracted directory"
      orig_t1=$(find "${EXTRACT_DIR}" -name "*T1*.nii.gz" ! -name "*Mask*" | head -1)
      orig_flair=$(find "${EXTRACT_DIR}" -name "*FLAIR*.nii.gz" ! -name "*Mask*" | head -1)
    fi
    
    if [[ -z "$orig_t1" || -z "$orig_flair" ]]; then
      log_formatted "ERROR" "Original T1 or FLAIR file not found" $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi
    
    log_message "Found original T1: $orig_t1"
    log_message "Found original FLAIR: $orig_flair"
    
    # Find segmentation files
    log_message "Looking for segmentation files..."
    # Use main pons instead of dorsal subdivision (Juelich atlas doesn't provide subdivisions)
    local pons_mask=$(find "$RESULTS_DIR/segmentation/pons" -name "*pons.nii.gz" ! -name "*dorsal*" ! -name "*ventral*" | head -1)

    if [ -z "$pons_mask" ]; then
      log_formatted "ERROR" "Pons segmentation not found" $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi

    log_message "Found pons segmentation: $pons_mask"
    
    # Transform segmentation from standard space to original space
    log_message "Transforming segmentation from standard to original space..."
    local orig_space_dir=$(create_module_dir "segmentation/original_space")
    mkdir -p "$orig_space_dir"
    # Use the basename of the pons mask to create the output filename
    local pons_orig="${orig_space_dir}/$(basename "$pons_mask" .nii.gz)_orig.nii.gz"
    
    transform_segmentation_to_original "$pons_mask" "$orig_flair" "$pons_orig"
    if [ $? -ne 0 ]; then
      log_formatted "ERROR" "Failed to transform segmentation to original space" $ERR_PROCESSING
      return $ERR_PROCESSING
    fi   

    
    if [ ! -f "$pons_orig" ]; then
      log_formatted "ERROR" "Failed to transform segmentation to original space" $ERR_PROCESSING
      return $ERR_PROCESSING
    fi
    
    log_message "Successfully transformed segmentation to original space: $pons_orig"
    
    # Note: Intensity mask creation is handled by segmentation module
    # The segmentation functions should create both T1 and FLAIR intensity versions
    log_message "Segmentation transformation to original space complete"
    
    # Run QA validation to ensure all segmentation outputs are properly created
    log_message "Running comprehensive QA validation for all segmentations..."
    if ! qa_verify_all_segmentations "$RESULTS_DIR"; then
      log_formatted "WARNING" "Some segmentation QA checks failed - see reports for details"
    fi
    
    # Verify dimensions consistency
    log_message "Verifying dimensions consistency across pipeline stages..."
    verify_dimensions_consistency "$orig_flair" "$orig_flair" "$pons_orig" "${RESULTS_DIR}/validation/dimensions_report.txt"
    
    # Note: Segmentation location verification moved to QA module
    # Use qa_verify_all_segmentations function for comprehensive validation
    
    # Find or create registered FLAIR
    local flair_registered=$(find "$reg_dir" -name "*FLAIR*Warped.nii.gz" -o -name "t1_to_flairWarped.nii.gz" | head -1)
    
    if [ -z "$flair_registered" ]; then
      log_formatted "ERROR" "No registered FLAIR found. Will register now."
      if [ -n "$t1_std" ] && [ -n "$flair_std" ]; then
        local reg_prefix="${reg_dir}/t1_to_flair"
        register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
        flair_registered="${reg_prefix}Warped.nii.gz"
      else
        log_formatted "ERROR" "Cannot find or create registered FLAIR file" $ERR_DATA_MISSING
        return $ERR_DATA_MISSING
      fi
    fi
    
    log_message "Using registered FLAIR: $flair_registered"
    
    # Run comprehensive analysis instead of just dorsal pons hyperintensity detection
    # This analyzes ALL segmentation masks and validates registration
    local comprehensive_dir=$(create_module_dir "comprehensive_analysis")
    
    log_formatted "INFO" "===== RUNNING COMPREHENSIVE ANALYSIS ====="
    log_message "This will analyze hyperintensities in ALL segmentation masks"
    log_message "and validate registration quality across spaces"
    
    # Pass all relevant images and directories to the comprehensive analysis
    run_comprehensive_analysis \
      "$orig_t1" \
      "$orig_flair" \
      "$t1_std" \
      "$flair_std" \
      "$RESULTS_DIR/segmentation" \
      "$comprehensive_dir"
    
    # For backward compatibility, create a link to the traditional hyperintensity mask
    local hyperintensities_dir=$(create_module_dir "hyperintensities")
    local hyperintensity_mask="${comprehensive_dir}/hyperintensities/pons/hyperintensities_bin.nii.gz"
    
    if [ -f "$hyperintensity_mask" ]; then
      # Use the basename from the pons mask
      local pons_basename=$(basename "$pons_mask" .nii.gz | sed 's/_pons$//')
      local legacy_mask="${hyperintensities_dir}/${pons_basename}_pons_thresh${THRESHOLD_WM_SD_MULTIPLIER:-1.25}_bin.nii.gz"
      ln -sf "$hyperintensity_mask" "$legacy_mask"
      log_message "Created link to comprehensive analysis result: $legacy_mask"
    else
      log_formatted "WARNING" "Comprehensive analysis didn't produce expected hyperintensity mask"
      log_message "Falling back to traditional hyperintensity detection using main pons..."
      
      # Fall back to traditional hyperintensity detection using main pons
      # Use the basename from the pons mask, not subject_id
      local pons_basename=$(basename "$pons_mask" .nii.gz | sed 's/_pons$//')
      local hyperintensities_prefix="${hyperintensities_dir}/${pons_basename}_pons"
      detect_hyperintensities "$orig_flair" "$hyperintensities_prefix" "$orig_t1"
      hyperintensity_mask="${hyperintensities_prefix}_thresh${THRESHOLD_WM_SD_MULTIPLIER:-1.25}_bin.nii.gz"
      analyze_hyperintensity_clusters "$hyperintensity_mask" "$pons_orig" "$orig_t1" "${hyperintensities_dir}/clusters" 5
    fi
    
    # Validate hyperintensities detection
    # Use the basename from the pons mask
    local pons_basename=$(basename "$pons_mask" .nii.gz | sed 's/_pons$//')
    validate_step "Hyperintensity detection" "${pons_basename}_pons*.nii.gz" "hyperintensities"
    
    # Launch enhanced visual QA for hyperintensity detection (non-blocking)
    # Show both the FLAIR and the hyperintensity mask
    enhanced_launch_visual_qa "$orig_flair" "$hyperintensity_mask" ":colormap=heat:opacity=0.7" "hyperintensity-detection" "axial"
    
    # Also show all segmentation masks in one view for comparison
    local all_masks="${comprehensive_dir}/hyperintensities/all_masks_overlay.nii.gz"
    if [ -f "$all_masks" ]; then
      enhanced_launch_visual_qa "$orig_flair" "$all_masks" ":colormap=heat:opacity=0.7" "all-segmentations-hyperintensities" "axial"
    fi
  else
    log_message 'Skipping Step 5 (Analysis) as requested'
    log_message "Checking if segmentation data exists..."
    
    # Check if essential files exist to continue
    local segmentation_dir="$RESULTS_DIR/segmentation"
    if [ ! -d "$segmentation_dir" ]; then
      log_error "Segmentation data is missing. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi
    
    # Find key segmentation files (use main pons instead of dorsal subdivision)
    pons_mask=$(find "$segmentation_dir" -name "*pons.nii.gz" ! -name "*dorsal*" ! -name "*ventral*" | head -1)
    
    if [ -z "$pons_mask" ]; then
      log_error "Pons segmentation not found. Cannot skip to Step $START_STAGE." $ERR_DATA_MISSING
      return $ERR_DATA_MISSING
    fi
    
    log_message "Found segmentation data: $pons_mask"
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
    log_message 'Skipping Step 6 (Visualization) as requested'
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
    log_message 'Skipping Step 7 (Pipeline progress tracking) as requested'
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
      
      # Get hyperintensity volume (using main pons instead of dorsal subdivision)
      local threshold_multiplier="${THRESHOLD_WM_SD_MULTIPLIER:-1.25}"
      local hyperintensity_file=$(get_output_path "hyperintensities" "${subject_id}" "_pons_thresh${threshold_multiplier}")
      if [ -f "$hyperintensity_file" ]; then
        hyperintensity_vol=$(fslstats "$hyperintensity_file" -V | awk '{print $1}')
        
        # Get largest cluster size if clusters file exists
        local clusters_file="${hyperintensities_dir}/${subject_id}_pons_clusters_sorted.txt"
        if [ -f "$clusters_file" ]; then
          largest_cluster_vol=$(head -1 "$clusters_file" | awk '{print $2}')
        fi
      fi
      
      # Add to summary (note: dorsal_pons_vol is now just pons_vol since no subdivision)
      echo "${subject_id},${status_text},${brainstem_vol},${pons_vol},${pons_vol},${hyperintensity_vol},${largest_cluster_vol},${reg_quality}" >> "$summary_file"
      
  done < "$subject_list"
  fi
  echo "Batch processing complete. Summary available at: $summary_file"
  return 0
}

# Main function
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  log_message "Pipeline will start from stage $START_STAGE"
  
  # Initialize environment
  initialize_environment
  
  # Load parallel configuration if available
  load_parallel_config "config/parallel_config.sh"
  
  # Check all dependencies thoroughly
  check_all_dependencies
  
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
  else
    run_pipeline
    status=$?
  fi
  
  if [ $status -ne 0 ]; then
    log_error "Pipeline failed with $PIPELINE_ERROR_COUNT errors $status" $ERR_VALIDATION
    exit $status
  fi
  
  log_message "Pipeline completed successfully"
  return 0
}

# Run main function with all arguments
main $@

