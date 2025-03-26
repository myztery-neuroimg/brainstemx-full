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

# Parse command line arguments
parse_arguments() {
  # Default values
  CONFIG_FILE="config/default_config.sh"
  SRC_DIR="../DiCOM"
  RESULTS_DIR="../mri_results"
  SUBJECT_ID=""
  QUALITY_PRESET="MEDIUM"
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
        log_formatted "ERROR" "Unknown option: $1"
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

# Run the pipeline
run_pipeline() {
  local subject_id="$SUBJECT_ID"
  local input_dir="$SRC_DIR"
  local output_dir="$RESULTS_DIR"
  
  log_message "Running pipeline for subject $subject_id"
  log_message "Input directory: $input_dir"
  log_message "Output directory: $output_dir"
  
  # Create directories
  create_directories
  
  # Step 1: Import and convert data
  log_message "Step 1: Importing and converting data"
  import_dicom_data "$input_dir" "$EXTRACT_DIR"
  validate_dicom_files "$input_dir"
  extract_siemens_metadata "$input_dir"
  validate_nifti_files "$EXTRACT_DIR"
  deduplicate_identical_files "$EXTRACT_DIR"
  
  # Step 2: Preprocessing
  log_message "Step 2: Preprocessing"
  
  # Find T1 and FLAIR files
  local t1_file=$(find "$EXTRACT_DIR" -name "*T1*.nii.gz" | head -1)
  local flair_file=$(find "$EXTRACT_DIR" -name "*FLAIR*.nii.gz" | head -1)
  
  if [ -z "$t1_file" ]; then
    log_formatted "ERROR" "T1 file not found in $EXTRACT_DIR"
    return 1
  fi
  
  if [ -z "$flair_file" ]; then
    log_formatted "ERROR" "FLAIR file not found in $EXTRACT_DIR"
    return 1
  }
  
  log_message "T1 file: $t1_file"
  log_message "FLAIR file: $flair_file"
  
  # Combine multi-axial images if available
  combine_multiaxis_images "T1" "${RESULTS_DIR}/combined"
  combine_multiaxis_images "FLAIR" "${RESULTS_DIR}/combined"
  
  # Update file paths if combined images were created
  if [ -f "${RESULTS_DIR}/combined/T1_combined_highres.nii.gz" ]; then
    t1_file="${RESULTS_DIR}/combined/T1_combined_highres.nii.gz"
  fi
  
  if [ -f "${RESULTS_DIR}/combined/FLAIR_combined_highres.nii.gz" ]; then
    flair_file="${RESULTS_DIR}/combined/FLAIR_combined_highres.nii.gz"
  fi
  
  # N4 bias field correction
  process_n4_correction "$t1_file"
  process_n4_correction "$flair_file"
  
  # Update file paths
  t1_file="${RESULTS_DIR}/bias_corrected/$(basename "$t1_file" .nii.gz)_n4.nii.gz"
  flair_file="${RESULTS_DIR}/bias_corrected/$(basename "$flair_file" .nii.gz)_n4.nii.gz"
  
  # Brain extraction
  extract_brain "$t1_file"
  extract_brain "$flair_file"
  
  # Update file paths
  t1_brain="${RESULTS_DIR}/brain_extraction/$(basename "$t1_file" .nii.gz)_brain.nii.gz"
  flair_brain="${RESULTS_DIR}/brain_extraction/$(basename "$flair_file" .nii.gz)_brain.nii.gz"
  
  # Standardize dimensions
  standardize_dimensions "$t1_brain"
  standardize_dimensions "$flair_brain"
  
  # Update file paths
  t1_std="${RESULTS_DIR}/standardized/$(basename "$t1_brain" .nii.gz)_std.nii.gz"
  flair_std="${RESULTS_DIR}/standardized/$(basename "$flair_brain" .nii.gz)_std.nii.gz"
  
  # Step 3: Registration
  log_message "Step 3: Registration"
  register_t2_flair_to_t1mprage "$t1_std" "$flair_std" "${RESULTS_DIR}/registered/t1_to_flair"
  
  # Update file paths
  flair_registered="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
  
  # Create registration visualizations
  create_registration_visualizations "$t1_std" "$flair_std" "$flair_registered" "${RESULTS_DIR}/validation/registration"
  
  # Step 4: Segmentation
  log_message "Step 4: Segmentation"
  
  # Extract brainstem
  extract_brainstem_ants "$t1_std" "${RESULTS_DIR}/segmentation/brainstem/${subject_id}_brainstem.nii.gz"
  
  # Extract pons from brainstem
  extract_pons_from_brainstem "${RESULTS_DIR}/segmentation/brainstem/${subject_id}_brainstem.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_pons.nii.gz"
  
  # Divide pons into dorsal and ventral regions
  divide_pons "${RESULTS_DIR}/segmentation/pons/${subject_id}_pons.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_ventral_pons.nii.gz"
  
  # Validate segmentation
  validate_segmentation "$t1_std" "${RESULTS_DIR}/segmentation/brainstem/${subject_id}_brainstem.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_pons.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz" "${RESULTS_DIR}/segmentation/pons/${subject_id}_ventral_pons.nii.gz"
  
  # Step 5: Analysis
  log_message "Step 5: Analysis"
  
  # Register FLAIR to dorsal pons
  register_t2_flair_to_t1mprage "${RESULTS_DIR}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz" "$flair_registered" "${RESULTS_DIR}/registered/${subject_id}_dorsal_pons"
  
  # Update file paths
  flair_dorsal_pons="${RESULTS_DIR}/registered/${subject_id}_dorsal_ponsWarped.nii.gz"
  
  # Detect hyperintensities
  detect_hyperintensities "$flair_dorsal_pons" "${RESULTS_DIR}/hyperintensities/${subject_id}_dorsal_pons" "$t1_std"
  
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
  
  echo "Running brainstem analysis pipeline on subject list: $subject_list"
  
  # Create summary directory
  local summary_dir="${output_base}/summary"
  mkdir -p "$summary_dir"
  
  # Initialize summary report
  local summary_file="${summary_dir}/batch_summary.csv"
  echo "Subject,Status,BrainstemVolume,PonsVolume,DorsalPonsVolume,HyperintensityVolume,LargestClusterVolume,RegistrationQuality" > "$summary_file"
  
  # Process each subject
  while read -r subject_id t2_flair t1; do
    echo "Processing subject: $subject_id"
    
    # Create subject output directory
    local subject_dir="${output_base}/${subject_id}"
    
    # Set global variables for this subject
    export SUBJECT_ID="$subject_id"
    export SRC_DIR="$base_dir/$subject_id"
    export RESULTS_DIR="$subject_dir"
    
    # Run processing
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
    
    if [ -f "${subject_dir}/segmentation/brainstem/${subject_id}_brainstem.nii.gz" ]; then
      brainstem_vol=$(fslstats "${subject_dir}/segmentation/brainstem/${subject_id}_brainstem.nii.gz" -V | awk '{print $1}')
    fi
    
    if [ -f "${subject_dir}/segmentation/pons/${subject_id}_pons.nii.gz" ]; then
      pons_vol=$(fslstats "${subject_dir}/segmentation/pons/${subject_id}_pons.nii.gz" -V | awk '{print $1}')
    fi
    
    if [ -f "${subject_dir}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz" ]; then
      dorsal_pons_vol=$(fslstats "${subject_dir}/segmentation/pons/${subject_id}_dorsal_pons.nii.gz" -V | awk '{print $1}')
    fi
    
    if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
      hyperintensity_vol=$(fslstats "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -V | awk '{print $1}')
      
      # Get largest cluster size if clusters file exists
      if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_clusters_sorted.txt" ]; then
        largest_cluster_vol=$(head -1 "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_clusters_sorted.txt" | awk '{print $2}')
      fi
    fi
    
    if [ -f "${subject_dir}/validation/registration/quality.txt" ]; then
      reg_quality=$(cat "${subject_dir}/validation/registration/quality.txt")
    fi
    
    # Add to summary
    echo "${subject_id},${status_text},${brainstem_vol},${pons_vol},${dorsal_pons_vol},${hyperintensity_vol},${largest_cluster_vol},${reg_quality}" >> "$summary_file"
    
  done < "$subject_list"
  
  echo "Batch processing complete. Summary available at: $summary_file"
  return 0
}

# Main function
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  # Initialize environment
  initialize_environment
  
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
      log_formatted "ERROR" "Subject list file not provided for batch processing"
      exit 1
    fi
    
    run_pipeline_batch "$SUBJECT_LIST" "$SRC_DIR" "$RESULTS_DIR"
  else
    run_pipeline
  fi
  
  log_message "Pipeline completed successfully"
  return 0
}

# Run main function with all arguments
main "$@"