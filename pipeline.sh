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
set -e
set -u
set -o pipefail

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
  echo "  -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM) (default: FULL)"
  echo "  -h, --help           Show this help message and exit"
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

# Parse command line arguments
parse_arguments() {
  # Default values
  CONFIG_FILE="config/default_config.sh"
  SRC_DIR="../DiCOM"
  RESULTS_DIR="../mri_results"
  SUBJECT_ID=""
  QUALITY_PRESET="HIGH"
  PIPELINE_TYPE="FULL"
  
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
  
  # Export variables
  export SRC_DIR
  export RESULTS_DIR
  export SUBJECT_ID
  export QUALITY_PRESET
  export PIPELINE_TYPE
  
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
  load_config "/Users/davidbrewster/Documents/workspace/2025/brainMRI-ants-e2e-pipeline/config/default_config.sh" 
  log_message "Running pipeline for subject $subject_id"
  log_message "Input directory: $input_dir"
  log_message "Output directory: $output_dir"
  
  # Create directories
  create_directories
  
  # Step 1: Import and convert data
  log_message "Step 1: Importing and converting data"
  
  #import_dicom_data "$input_dir" "$EXTRACT_DIR"
  #qa_validate_dicom_files "$input_dir" 
  #import_extract_siemens_metadata "$input_dir"
  #qa_validate_nifti_files "$EXTRACT_DIR"
  #import_deduplicate_identical_files "$EXTRACT_DIR"
  
  # Validate import step
  #validate_step "Import data" "*.nii.gz" "extracted"
  
  
  # Step 2: Preprocessing
  log_message "Step 2: Preprocessing"
  
  # Find T1 and FLAIR files
  export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_12.nii.gz"
  export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS_17.nii.gz"

  local t1_file=$(find "$EXTRACT_DIR" -name "${T1_PRIORITY_PATTERN}" | head -1)
  local flair_file=$(find "$EXTRACT_DIR" -name "${FLAIR_PRIORITY_PATTERN}" | head -1)
  
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
  #combine_multiaxis_images "T1" "${RESULTS_DIR}/combined"
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
  
  # Step 3: Registration
  log_message "Step 3: Registration"
  
  # Create output directory for registration
  local reg_dir=$(create_module_dir "registered")
  local reg_prefix="${reg_dir}/t1_to_flair"
  
  register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "$reg_prefix"
  
  # Update file paths
  flair_registered="${reg_prefix}Warped.nii.gz"
  
  # Validate registration step
  validate_step "Registration" "t1_to_flairWarped.nii.gz" "registered"
  
  # Create registration visualizations
  local validation_dir=$(create_module_dir "validation/registration")
  create_registration_visualizations "$t1_std" "$flair_std" "$flair_registered" "$validation_dir"
  
  # Validate visualization step
  validate_step "Registration visualizations" "*.png,quality.txt" "validation/registration"
  
  # Step 4: Segmentation
  log_message "Step 4: Segmentation"
  
  # Create output directories for segmentation
  local brainstem_dir=$(create_module_dir "segmentation/brainstem")
  local pons_dir=$(create_module_dir "segmentation/pons")
  
  # Extract brainstem
  local brainstem_output=$(get_output_path "segmentation/brainstem" "${subject_id}" "_brainstem")
  extract_brainstem_ants "$t1_std" "$brainstem_output"
  
  # Validate brainstem extraction
  validate_step "Brainstem extraction" "${subject_id}_brainstem.nii.gz" "segmentation/brainstem"
  
  # Extract pons from brainstem
  local pons_output=$(get_output_path "segmentation/pons" "${subject_id}" "_pons")
  extract_pons_from_brainstem "$brainstem_output" "$pons_output"
  
  # Validate pons extraction
  validate_step "Pons extraction" "${subject_id}_pons.nii.gz" "segmentation/pons"
  
  # Divide pons into dorsal and ventral regions
  local dorsal_pons=$(get_output_path "segmentation/pons" "${subject_id}" "_dorsal_pons")
  local ventral_pons=$(get_output_path "segmentation/pons" "${subject_id}" "_ventral_pons")
  divide_pons "$pons_output" "$dorsal_pons" "$ventral_pons"
  
  # Validate dorsal/ventral division
  validate_step "Pons division" "${subject_id}_dorsal_pons.nii.gz,${subject_id}_ventral_pons.nii.gz" "segmentation/pons"
  
  # Validate segmentation
  validate_segmentation "$t1_std" "$brainstem_output" "$pons_output" "$dorsal_pons" "$ventral_pons"
  
  # Step 5: Analysis
  log_message "Step 5: Analysis"
  
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
  
  # Step 6: Visualization
  log_message "Step 6: Visualization"
  
  # Generate QC visualizations
  generate_qc_visualizations "$subject_id" "$RESULTS_DIR"
  
  # Create multi-threshold overlays
  create_multi_threshold_overlays "$subject_id" "$RESULTS_DIR"
  
  
  # Generate HTML report
  generate_html_report "$subject_id" "$RESULTS_DIR"
  
  # Step 7: Track pipeline progress
  log_message "Step 7: Tracking pipeline progress"
  track_pipeline_progress "$subject_id" "$RESULTS_DIR"
  
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
      
      local hyperintensity_file=$(get_output_path "hyperintensities" "${subject_id}" "_dorsal_pons_thresh2.0")
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

# Run main function with all arguments
main "$@"
