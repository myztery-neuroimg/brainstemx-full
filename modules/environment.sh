#!/usr/bin/env bash
#
# environment.sh - Environment setup for the brain MRI processing pipeline
#
# This module contains:
# - Environment variables (paths, directories)
# - Logging functions
# - Configuration parameters
# - Dependency checks
#

# ------------------------------------------------------------------------------
# Shell Options
# ------------------------------------------------------------------------------
set -e
set -u
set -o pipefail

# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="../DICOM"          # DICOM input directory
export DICOM_PRIMARY_PATTERN='Image"*"'   # Filename pattern for your DICOM files, might be .dcm on some scanners, Image- for Siemens
export PIPELINE_SUCCESS=true       # Track overall pipeline success
export PIPELINE_ERROR_COUNT=0      # Count of errors in pipeline
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix

# Parallelization configuration (defaults, can be overridden by config file)
export PARALLEL_JOBS=1             # Number of parallel jobs to use
export MAX_CPU_INTENSIVE_JOBS=1    # Number of jobs for CPU-intensive operations
export PARALLEL_TIMEOUT=0          # Timeout for parallel operations (0 = no timeout)
export PARALLEL_HALT_MODE="soon"   # How to handle failed parallel jobs

export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
export ANTS_PATH="/Users/davidbrewster/ants"
export PATH="$PATH:${ANTS_PATH}/bin"
export LOG_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOG_DIR"
mkdir -p "$RESULTS_DIR"

# Log file capturing pipeline-wide logs
export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# ------------------------------------------------------------------------------
# Logging & Color Setup
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function for logging with timestamps
log_message() {
  local text="$1"
  # Write to both stderr and the LOG_FILE
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" | tee -a "$LOG_FILE" >&2
}

log_formatted() {
  local level=$1
  local message=$2
  case $level in
    "INFO")    echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR")   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
    *)         echo -e "[LOG] $message" >&2 ;;
  esac
}

# Log error and increment error counter
log_error() {
  local message="$1"
  local error_code="${2:-1}"  # Default error code is 1
  
  log_formatted "ERROR" "$message"
  
  # Update pipeline status
  PIPELINE_SUCCESS=false
  PIPELINE_ERROR_COUNT=$((PIPELINE_ERROR_COUNT + 1))
  return $error_code
}

export log_message log_error
export log_formatted

# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
PROCESSING_DATATYPE="float"  # internal float
OUTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # override if needed

# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi

# Parse out the fields for general sequences
N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
TEMPLATE_ITERATIONS=2
TEMPLATE_GRADIENT_STEP=0.2
TEMPLATE_TRANSFORM_MODEL="SyN"
TEMPLATE_SIMILARITY_METRIC="CC"
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
TEMPLATE_WEIGHTS="100x50x50x10"

# Registration & motion correction
REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
REG_METRIC_CROSS_MODALITY="MI"
REG_METRIC_SAME_MODALITY="CC"
ANTS_THREADS=12
REG_PRECISION=1

# Hyperintensity detection
THRESHOLD_WM_SD_MULTIPLIER=2.3
MIN_HYPERINTENSITY_SIZE=4

# Tissue segmentation parameters
ATROPOS_T1_CLASSES=3
ATROPOS_FLAIR_CLASSES=4
ATROPOS_CONVERGENCE="5,0.0"
ATROPOS_MRF="[0.1,1x1x1]"
ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
PADDING_X=5
PADDING_Y=5
PADDING_Z=5
C3D_CROP_THRESHOLD=0.1
C3D_PADDING_MM=5

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "ERROR" "FSLDIR not set. Exiting..."
  return 1
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"

# ------------------------------------------------------------------------------
# Dependency Checks
# ------------------------------------------------------------------------------
check_command() {
  local cmd=$1
  local package=$2
  local hint=${3:-""}

  if command -v "$cmd" &> /dev/null; then
    log_formatted "SUCCESS" "✓ $package is installed ($(command -v "$cmd"))"
    return 0
  else
    # Use log_error instead of log_formatted for consistent error tracking
    log_error "✗ $package is not installed or not in PATH" 127
    
    [ -n "$hint" ] && log_formatted "INFO" "$hint"
    return 1
  fi
}

check_ants() {
  log_formatted "INFO" "Checking ANTs tools..."
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" \
                    "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_fsl() {
  log_formatted "INFO" "Checking FSL..."
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_freesurfer() {
  log_formatted "INFO" "Checking FreeSurfer..."
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_c3d() {
  log_formatted "INFO" "Checking Convert3D..."
  if ! check_command "c3d" "Convert3D" "Download from: http://www.itksnap.org/pmwiki/pmwiki.php?n=Downloads.C3D"; then
    return 1
  fi
  return 0
}

check_dcm2niix() {
  log_formatted "INFO" "Checking dcm2niix..."
  if ! check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix"; then
    return 1
  fi
  return 0
}

check_os() {
  log_formatted "INFO" "Checking operating system..."
  local os_name=$(uname -s)
  case "$os_name" in
    "Darwin")
      log_formatted "SUCCESS" "✓ Running on macOS"
      ;;
    "Linux")
      log_formatted "SUCCESS" "✓ Running on Linux"
      ;;
    *)
      log_formatted "WARNING" "⚠ Running on unknown OS: $os_name"
      ;;
  esac
  return 0
}

check_dependencies() {
  log_formatted "INFO" "==== MRI Processing Dependency Checker ===="
  
  local error_count=0
  
  check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix" || error_count=$((error_count+1))
  check_ants || error_count=$((error_count+1))
  check_fsl || error_count=$((error_count+1))
  check_freesurfer || error_count=$((error_count+1))
  check_c3d || error_count=$((error_count+1))
  check_os
  
  log_formatted "INFO" "==== Checking optional but recommended tools ===="
  
  # Check for ImageMagick (useful for image manipulation)
  check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || log_formatted "WARNING" "ImageMagick is recommended for image conversions"
  
  # Check for parallel (useful for parallel processing)
  check_command "parallel" "GNU Parallel" "Install with: brew install parallel" || log_formatted "ERROR" "GNU Parallel is required for faster processing"
  
  # Summary
  log_formatted "INFO" "==== Dependency Check Summary ===="
  
  if [ $error_count -eq 0 ]; then
    log_formatted "SUCCESS" "All required dependencies are installed!"
    return 0
  else
    log_error "$error_count required dependencies are missing." 127
    log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
    
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Utility Functions
# ------------------------------------------------------------------------------

# Get the directory path for a specific module
get_module_dir() {
  local module="$1"
  
  # Standard module directories
  case "$module" in
    "metadata")
      echo "${RESULTS_DIR}/metadata"
      ;;
    "combined")
      echo "${RESULTS_DIR}/combined"
      ;;
    "bias_corrected")
      echo "${RESULTS_DIR}/bias_corrected"
      ;;
    "brain_extraction")
      echo "${RESULTS_DIR}/brain_extraction"
      ;;
    "standardized")
      echo "${RESULTS_DIR}/standardized"
      ;;
    "registered")
      echo "${RESULTS_DIR}/registered"
      ;;
    "segmentation")
      echo "${RESULTS_DIR}/segmentation"
      ;;
    "hyperintensities")
      echo "${RESULTS_DIR}/hyperintensities"
      ;;
    "validation")
      echo "${RESULTS_DIR}/validation"
      ;;
    "qc")
      echo "${RESULTS_DIR}/qc_visualizations"
      ;;
    *)
      echo "${RESULTS_DIR}/${module}"
      ;;
  esac
}

# Create directory for a module if it doesn't exist
create_module_dir() {
  local module="$1"
  local dir=$(get_module_dir "$module")
  
  if [ ! -d "$dir" ]; then
    log_formatted "INFO" "Creating directory for module '$module': $dir"
    mkdir -p "$dir"
  fi
  
  echo "$dir"
}

# Generate standardized output file path
get_output_path() {
  local module="$1"       # Module name (e.g., "bias_corrected")
  local basename="$2"     # Base filename
  local suffix="$3"       # Suffix to add (e.g., "_n4")
  
  echo "$(get_module_dir "$module")/${basename}${suffix}.nii.gz"
}

# ------------------------------------------------------------------------------
# Error Codes
# ------------------------------------------------------------------------------
# 1-9: General errors
export ERR_GENERAL=1          # General error
export ERR_INVALID_ARGS=2     # Invalid arguments
export ERR_FILE_NOT_FOUND=3   # File not found
export ERR_PERMISSION=4       # Permission denied
export ERR_IO_ERROR=5         # I/O error
export ERR_TIMEOUT=6          # Operation timed out
export ERR_VALIDATION=7       # Validation failed

# 10-19: Module-specific errors
export ERR_IMPORT=10          # Import module error
export ERR_PREPROC=11         # Preprocessing module error
export ERR_REGISTRATION=12    # Registration module error
export ERR_SEGMENTATION=13    # Segmentation module error
export ERR_ANALYSIS=14        # Analysis module error
export ERR_VISUALIZATION=15   # Visualization module error
export ERR_QA=16              # QA module error

# 20-29: External tool errors
export ERR_ANTS=20            # ANTs tool error
export ERR_FSL=21             # FSL tool error
export ERR_FREESURFER=22      # FreeSurfer tool error
export ERR_C3D=23             # Convert3D error
export ERR_DCM2NIIX=24        # dcm2niix error

# 30-39: Data errors
export ERR_DATA_CORRUPT=30    # Data corruption
export ERR_DATA_MISSING=31    # Missing data
export ERR_DATA_INCOMPATIBLE=32 # Incompatible data

# 127: Environment/dependency errors
export ERR_DEPENDENCY=127     # Missing dependency

# ------------------------------------------------------------------------------
# Validation Functions
# ------------------------------------------------------------------------------

# Validate that a file exists and is readable
validate_file() {
  local file="$1"
  local description="${2:-file}"
  
  if [ ! -f "$file" ]; then
    log_error "$description not found: $file" $ERR_FILE_NOT_FOUND
    return $ERR_FILE_NOT_FOUND
  fi
  
  if [ ! -r "$file" ]; then
    log_error "$description is not readable: $file" $ERR_PERMISSION
    return $ERR_PERMISSION
  fi
  
  return 0
}

# Validate NIfTI file with additional checks
validate_nifti() {
  local file="$1"
  local description="${2:-NIfTI file}"
  local min_size="${3:-10240}"  # Minimum file size in bytes (10KB default)
  
  # First check if file exists and is readable
  validate_file "$file" "$description" || return $?
  
  # Check file size
  local file_size=$(stat -f "%z" "$file" 2>/dev/null || stat --format="%s" "$file" 2>/dev/null)
  if [ -z "$file_size" ] || [ "$file_size" -lt "$min_size" ]; then
    log_error "$description has suspicious size ($file_size bytes): $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  # Check if file can be read by FSL
  if ! fslinfo "$file" &>/dev/null; then
    log_error "$description appears to be corrupt or invalid: $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  return 0
}

# Validate that a directory exists and is writable
validate_directory() {
  local dir="$1"
  local description="${2:-directory}"
  local create="${3:-false}"
  
  if [ ! -d "$dir" ]; then
    if [ "$create" = "true" ]; then
      log_formatted "INFO" "Creating $description: $dir"
      mkdir -p "$dir" || {
        log_error "Failed to create $description: $dir" $ERR_PERMISSION
        return $ERR_PERMISSION
      }
    else
      log_error "$description not found: $dir" $ERR_FILE_NOT_FOUND
      return $ERR_FILE_NOT_FOUND
    fi
  fi
  
  return 0
}

standardize_datatype() {
  local input_file="$1"
  local output_file="$2"
  local datatype="${3:-$PROCESSING_DATATYPE}"  # Default to PROCESSING_DATATYPE
  
  log_message "Standardizing datatype of $input_file to $datatype"
  
  # Use fslmaths to convert datatype
  fslmaths "$input_file" -dt "$datatype" "$output_file"
  
  # Verify the conversion
  local new_dt=$(fslinfo "$output_file" | grep datatype | awk '{print $2}')
  log_message "Datatype conversion complete: $new_dt"
}

set_sequence_params() {
  local sequence_type="$1"
  
  case "$sequence_type" in
    "T1")
      # T1 parameters
      export CURRENT_N4_PARAMS="$N4_PARAMS"
      ;;
    "FLAIR")
      # FLAIR-specific parameters
      export CURRENT_N4_PARAMS="$N4_PRESET_FLAIR"
      ;;
    *)
      # Default parameters
      export CURRENT_N4_PARAMS="$N4_PARAMS"
      log_formatted "WARNING" "Unknown sequence type: $sequence_type. Using default parameters."
      ;;
  esac
  
  log_message "Set sequence parameters for $sequence_type: $CURRENT_N4_PARAMS"
}

# Create necessary directories
create_directories() {
  mkdir -p "$EXTRACT_DIR"
  mkdir -p "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR/metadata"
  mkdir -p "$RESULTS_DIR/combined"
  mkdir -p "$RESULTS_DIR/bias_corrected"
  mkdir -p "$RESULTS_DIR/brain_extraction"
  mkdir -p "$RESULTS_DIR/standardized"
  mkdir -p "$RESULTS_DIR/registered"
  mkdir -p "$RESULTS_DIR/segmentation/tissue"
  mkdir -p "$RESULTS_DIR/segmentation/brainstem"
  mkdir -p "$RESULTS_DIR/segmentation/pons"
  mkdir -p "$RESULTS_DIR/hyperintensities/thresholds"
  mkdir -p "$RESULTS_DIR/hyperintensities/clusters"
  mkdir -p "$RESULTS_DIR/validation/registration"
  mkdir -p "$RESULTS_DIR/validation/segmentation"
  mkdir -p "$RESULTS_DIR/validation/hyperintensities"
  mkdir -p "$RESULTS_DIR/qc_visualizations"
  mkdir -p "$RESULTS_DIR/reports"
  mkdir -p "$RESULTS_DIR/summary"
  
  log_message "Created directory structure"
}

# Validate an entire module execution
validate_module_execution() {
  local module="$1"
  local expected_outputs="$2"  # Comma-separated list of expected output files
  local module_dir="${3:-$(get_module_dir "$module")}"
  
  log_formatted "INFO" "Validating $module module execution..."
  
  # Check if directory exists
  validate_directory "$module_dir" "$module directory" || return $?
  
  # Track validation status
  local validation_status=0
  local missing_files=()
  local invalid_files=()
  
  # Check each expected output
  IFS=',' read -ra files <<< "$expected_outputs"
  for file in "${files[@]}"; do
    # Trim whitespace
    file="$(echo "$file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    
    # Skip empty entries
    [ -z "$file" ] && continue
    
    # Add module_dir if path is not absolute
    [[ "$file" != /* ]] && file="${module_dir}/${file}"
    
    if [ ! -f "$file" ]; then
      missing_files+=("$file")
      validation_status=$ERR_VALIDATION
      continue
    fi
    
    # Validate file contents if it's a NIfTI file
    if [[ "$file" == *.nii || "$file" == *.nii.gz ]]; then
      if ! validate_nifti "$file" >/dev/null; then
        invalid_files+=("$file")
        validation_status=$ERR_VALIDATION
      fi
    fi
  done
  
  # Report validation results
  if [ ${#missing_files[@]} -gt 0 ]; then
    log_error "Module $module is missing expected output files: ${missing_files[*]}" $ERR_VALIDATION
  fi
  
  if [ ${#invalid_files[@]} -gt 0 ]; then
    log_error "Module $module produced invalid output files: ${invalid_files[*]}" $ERR_VALIDATION
  fi
  
  [ $validation_status -eq 0 ] && log_formatted "SUCCESS" "Module $module validation successful"
  return $validation_status
}

# ------------------------------------------------------------------------------
# Parallel Processing Functions
# ------------------------------------------------------------------------------

# Check if GNU parallel is installed and available
check_parallel() {
  log_formatted "INFO" "Checking for GNU parallel..."
  
  if ! command -v parallel &> /dev/null; then
    log_formatted "WARNING" "GNU parallel not found. Parallel processing will be disabled."
    return 1
  fi
  
  # Check if this is GNU parallel and not moreutils parallel
  if ! parallel --version 2>&1 | grep -q "GNU parallel"; then
    log_formatted "WARNING" "Found 'parallel' command, but it doesn't appear to be GNU parallel. Parallel processing may not work correctly."
    return 2
  fi
  
  log_formatted "SUCCESS" "GNU parallel is available: $(command -v parallel)"
  return 0
}

# Function to load parallel configuration from config file
load_parallel_config() {
  local config_file="${1:-config/parallel_config.sh}"
  
  if [ -f "$config_file" ]; then
    log_formatted "INFO" "Loading parallel configuration from $config_file"
    source "$config_file"
    
    # Auto-detect cores if enabled in config
    if [ "${AUTO_DETECT_CORES:-false}" = true ]; then
      auto_detect_cores
    fi
    
    log_formatted "INFO" "Parallel configuration loaded. PARALLEL_JOBS=$PARALLEL_JOBS, MAX_CPU_INTENSIVE_JOBS=$MAX_CPU_INTENSIVE_JOBS"
    return 0
  else
    log_formatted "WARNING" "Parallel configuration file not found: $config_file. Using defaults."
    return 1
  fi
}

# Run a function in parallel across multiple files
run_parallel() {
  local func_name="$1"        # Function to run in parallel
  local find_pattern="$2"     # Find pattern for input files
  local find_path="$3"        # Path to search for files
  local jobs="${4:-$PARALLEL_JOBS}"  # Number of jobs (default: PARALLEL_JOBS)
  local max_depth="${5:-}"    # Optional: max depth for find
  
  # Check if parallel processing is enabled
  if [ "$jobs" -le 0 ]; then
    log_formatted "INFO" "Parallel processing disabled. Running in sequential mode."
    # Run sequentially
    local find_cmd="find \"$find_path\" -name \"$find_pattern\""
    [ -n "$max_depth" ] && find_cmd="$find_cmd -maxdepth $max_depth"
    
    while IFS= read -r file; do
      "$func_name" "$file"
    done < <(eval "$find_cmd")
    return $?
  fi
  
  # Check if GNU parallel is installed
  if ! check_parallel; then
    log_formatted "WARNING" "GNU parallel not available. Falling back to sequential processing."
    # Run sequentially (same as above)
    local find_cmd="find \"$find_path\" -name \"$find_pattern\""
    [ -n "$max_depth" ] && find_cmd="$find_cmd -maxdepth $max_depth"
    
    while IFS= read -r file; do
      "$func_name" "$file"
    done < <(eval "$find_cmd")
    return $?
  fi
  
  # Build parallel command with proper error handling
  log_formatted "INFO" "Running $func_name in parallel with $jobs jobs"
  local parallel_cmd="find \"$find_path\" -name \"$find_pattern\""
  [ -n "$max_depth" ] && parallel_cmd="$parallel_cmd -maxdepth $max_depth"
  parallel_cmd="$parallel_cmd -print0 | parallel -0 -j $jobs --halt $PARALLEL_HALT_MODE,fail=1 $func_name {}"
  
  # Execute and capture exit code
  eval "$parallel_cmd"
  return $?
}

# Initialize environment
initialize_environment() {
  # Set error handling
  set -e
  set -u
  set -o pipefail
  
  # Initialize error count
  error_count=0
  
  log_message "Initializing environment"
  
  # Export functions
  export -f log_message
  export -f log_formatted
  export -f check_command
  export -f log_error
  export -f check_dependencies
  export -f standardize_datatype
  export -f get_output_path
  export -f get_module_dir
  export -f set_sequence_params
  export -f create_module_dir
  export -f check_parallel
  export -f load_parallel_config
  export -f run_parallel
  export -f validate_file validate_nifti validate_directory
  export -f validate_module_execution
  
  log_message "Environment initialized"
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

log_message "Environment module loaded"
