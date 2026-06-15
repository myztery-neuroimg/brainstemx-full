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

# Include guard - prevent redundant re-sourcing by modules
if [ -n "${_ENVIRONMENT_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_ENVIRONMENT_LOADED=true

# ------------------------------------------------------------------------------
# Logging & Color Setup (needs to be defined first)
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function for logging with timestamps
log_message() {
  local text="$1"
  # Write to both stderr and the LOG_FILE if it exists
  if [ -n "${LOG_FILE:-}" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" | tee -a "$LOG_FILE" >&2
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" >&2
  fi
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
  
  # Update pipeline status if defined
  if [ -n "${PIPELINE_SUCCESS:-}" ]; then
    PIPELINE_SUCCESS=false
    PIPELINE_ERROR_COUNT=$((PIPELINE_ERROR_COUNT + 1))
  fi
  
  return $error_code
}

# Function for diagnostic output (only to log file, not to stdout)
log_diagnostic() {
  local message="$1"
  # Only write to log file, not to stdout/stderr
  if [ -n "${LOG_FILE:-}" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] DIAGNOSTIC: $message" >> "$LOG_FILE"
  fi
}

# Function to execute commands with diagnostic output redirection
execute_with_logging() {
  local cmd="$1"
  local log_prefix="${2:-cmd}"
  local diagnostic_log="${LOG_DIR}/${log_prefix}_diagnostic.log"
  
  # Create diagnostic log directory if needed
  mkdir -p "$LOG_DIR"
  
  # Log the command that will be executed
  log_message "Executing: $cmd (diagnostic output redirected to $diagnostic_log)"
  
  # Execute command:
  # - Stdout is filtered to remove diagnostic lines, then sent to stdout AND the main log
  # - Stderr is sent to both the diagnostic log AND stderr
  # Remove quotes to avoid passing them directly to the command
  cmd=$(echo "$cmd" | sed -e 's/\\"/"/g')
  eval "$cmd" #> >(grep -ev "^ .DIAGNOSTIC.   ..[1-9]" | tee -a "$LOG_FILE") 2> >(grep -ev "^ .DIAGNOSTIC.   ..[1-9]" | tee -a "$diagnostic_log" >&2)
  
  # Return the exit code of the command (not of the tee/grep pipeline)
  return ${PIPESTATUS[0]}
}

# macOS-compatible safe fslmaths wrapper
safe_fslmaths() {
    local description="$1"
    shift
    
    # Pre-validate all input files (but NOT the output file)
    local has_input_files=false
    local input_files=()
    local output_file=""
    
    # First pass: identify the output file (typically the last .nii.gz argument)
    local args=("$@")
    for ((i=${#args[@]}-1; i>=0; i--)); do
        local arg="${args[i]}"
        if [[ "$arg" == *.nii.gz ]] && [[ ! "$arg" == -* ]]; then
            output_file="$arg"
            log_message "Identified output file: $output_file"
            break
        fi
    done
    
    # Second pass: validate input files (excluding the output file)
    for arg in "$@"; do
        # Skip flags, operators, and the output file
        if [[ "$arg" == -* ]] || [[ "$arg" == "$output_file" ]]; then
            continue
        fi
        
        # Check if this looks like an input NIfTI file
        if [[ "$arg" == *.nii.gz ]] && [[ ! "$arg" == *" "* ]]; then
            has_input_files=true
            input_files+=("$arg")
            
            log_message "Checking input file: $arg"
            
            if [ ! -f "$arg" ]; then
                log_formatted "ERROR" "$description: Missing input file: $arg"
                log_message "Working directory: $(pwd)"
                log_message "Files in $(dirname "$arg"):"
                ls -la "$(dirname "$arg")" 2>/dev/null | head -10 || echo "Directory not accessible"
                
                # Try to find similar files
                local dir=$(dirname "$arg")
                local basename=$(basename "$arg" .nii.gz)
                log_message "Searching for similar files..."
                find "$dir" -name "*.nii.gz" 2>/dev/null | head -5 | while read found_file; do
                    log_message "  Found: $found_file"
                done
                
                return 1
            fi
            
            # Quick NIfTI validation (macOS-compatible)
            if ! fslinfo "$arg" >/dev/null 2>&1; then
                log_formatted "ERROR" "$description: Invalid NIfTI file: $arg"
                return 1
            fi
            log_message "✓ Valid input file: $arg"
        fi
    done
    
    if [ "$has_input_files" = "false" ]; then
        log_formatted "WARNING" "$description: No input files detected in command"
    fi
    
    # Execute fslmaths with error handling (no timeout on macOS)
    log_message "Executing: fslmaths $*"
    
    # Create a background process for monitoring (macOS alternative to timeout).
    # Redirect the subshell's stdout/stderr to /dev/null so the orphaned 'sleep'
    # can never keep the caller's FDs open: otherwise a command-substitution or
    # pipe capture (e.g. x=$(safe_fslmaths ...)) would block on the held FD for
    # up to the full 5-minute sleep even after fslmaths itself returned.
    (
        sleep 300  # 5 minute limit
        if ps aux | grep -v grep | grep "fslmaths.*$$" >/dev/null 2>&1; then
            log_formatted "WARNING" "$description: fslmaths running longer than 5 minutes"
        fi
    ) >/dev/null 2>&1 &
    local monitor_pid=$!
    
    # Execute fslmaths
    fslmaths "$@"
    local status=$?
    
    # Kill the monitor process
    kill $monitor_pid 2>/dev/null || true
    
    if [ $status -ne 0 ]; then
        log_formatted "ERROR" "$description: fslmaths failed with exit code $status"
        log_message "Command was: fslmaths $*"
        log_message "Working directory: $(pwd)"
        log_message "Input files were:"
        for file in "${input_files[@]}"; do
            if [ -f "$file" ]; then
                local file_size=$(get_file_size "$file" 2>/dev/null || echo "?")
                log_message "  ✓ $file (exists, $file_size bytes)"
                
                # Check if file is readable and get basic info
                if fslinfo "$file" >/dev/null 2>&1; then
                    local dims=$(fslinfo "$file" | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                    local datatype=$(fslinfo "$file" | grep "^data_type" | awk '{print $2}')
                    log_message "    Dimensions: $dims, Datatype: $datatype"
                else
                    log_message "    WARNING: File exists but fslinfo failed - may be corrupted"
                fi
            else
                log_message "  ✗ $file (missing)"
            fi
        done
        
        # Check output file expectations (already identified during input validation)
        
        if [ -n "$output_file" ]; then
            log_message "Expected output file: $output_file"
            local output_dir=$(dirname "$output_file")
            if [ -d "$output_dir" ]; then
                log_message "Output directory exists: $output_dir"
                if [ -w "$output_dir" ]; then
                    log_message "Output directory is writable"
                else
                    log_message "ERROR: Output directory is not writable"
                fi
            else
                log_message "ERROR: Output directory does not exist: $output_dir"
            fi
        fi
        
        return $status
    fi
    
    log_formatted "SUCCESS" "$description: fslmaths completed successfully"
    return 0
}

# Function specifically for ANTs commands with enhanced explanations
execute_ants_command() {
  local log_prefix="${1:-ants_cmd}"
  local step_description="${2:-ANTs processing step}"
  local diagnostic_log="${LOG_DIR}/${log_prefix}_diagnostic.log"
  local cmd=("${@:3}") # Get all arguments except the first two as the command
  
  # Create diagnostic log directory if needed
  mkdir -p "$LOG_DIR"
  
  # Verbosity level (can be set via PIPELINE_VERBOSITY environment variable)
  local verbosity="${PIPELINE_VERBOSITY:-normal}"
  
  # Stage tracking variables
  local current_stage=""
  local stage_count=0
  local total_stages=0
  local stage_start_time=""
  local in_stage_header=false
  
  # Define comprehensive filter patterns for different verbosity levels
  local filter_patterns_quiet="RTTI typeinfo|Reference Count|Modified Time|Debug:|Object Name|Observers:|Source:|PipelineMTime|UpdateMTime|RealTimeStamp|PixelContainer|ImportImageContainer|Container manages|Capacity:|Pointer:|IndexToPointMatrix|PointToIndexMatrix|Inverse Direction|Direction:|BufferedRegion|RequestedRegion|LargestPossibleRegion|Sampling strategy|Sampling percentage|Update field|Total field|Number of time|Release Data|Data Released|Global Release Data|Spacing:|Origin:|Dimension:|Index:|Size:|PixelContainer:|convergenceValue|metricValue|ITERATION_TIME|CurrentIteration|CurrentMetricValue|CurrentConvergenceValue"
  
  local filter_patterns_normal="RTTI typeinfo|Reference Count|Modified Time|Debug:|Object Name|Observers:|Source:|PipelineMTime|UpdateMTime|RealTimeStamp|PixelContainer|ImportImageContainer|Container manages|Capacity:|Pointer:|IndexToPointMatrix|PointToIndexMatrix|Inverse Direction|BufferedRegion|RequestedRegion|LargestPossibleRegion|Release Data|Data Released|Global Release Data|PixelContainer:|convergenceValue|metricValue|CurrentMetricValue|CurrentConvergenceValue"
  
  local filter_patterns_verbose="RTTI typeinfo|Reference Count|Modified Time|Debug:|Object Name|Observers:|Source:|PipelineMTime|UpdateMTime|RealTimeStamp|PixelContainer|ImportImageContainer|Container manages|Capacity:|Pointer:"
  
  # Select filter pattern based on verbosity
  local filter_pattern="$filter_patterns_normal"
  case "$verbosity" in
    quiet) filter_pattern="$filter_patterns_quiet" ;;
    verbose) filter_pattern="$filter_patterns_verbose" ;;
    debug) filter_pattern="" ;; # No filtering in debug mode
  esac
  
  # Show initial description based on verbosity
  if [[ "$verbosity" != "quiet" ]]; then
    log_formatted "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_formatted "INFO" "🧠 $step_description"
    log_formatted "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  
  # Show primary parameters in a simplified form
  local cmd_str="${cmd[*]}"
  if [[ "$verbosity" != "quiet" ]]; then
    # Extract and display key information
    if [[ "$cmd_str" == *"-f "* ]]; then
      local fixed_img=$(echo "$cmd_str" | grep -o -- "-f [^ ]*" | cut -d ' ' -f 2)
      log_message "  📁 Reference: $(basename "$fixed_img")"
    fi
    if [[ "$cmd_str" == *"-m "* ]]; then
      local moving_img=$(echo "$cmd_str" | grep -o -- "-m [^ ]*" | cut -d ' ' -f 2)
      log_message "  📁 Moving: $(basename "$moving_img")"
    fi
    if [[ "$cmd_str" == *"-o "* ]]; then
      local output_prefix=$(echo "$cmd_str" | grep -o -- "-o [^ ]*" | cut -d ' ' -f 2)
      log_message "  📁 Output: $(basename "$output_prefix")*"
    fi
  fi
  
  # Only show diagnostic log location in verbose/debug mode
  if [[ "$verbosity" == "verbose" ]] || [[ "$verbosity" == "debug" ]]; then
    log_message "Diagnostic output saved to: $diagnostic_log"
  fi
  
  # Create named pipes for better output handling
  local stdout_pipe=$(mktemp -u)
  local stderr_pipe=$(mktemp -u)
  mkfifo "$stdout_pipe"
  mkfifo "$stderr_pipe"
  
  # Enhanced progress tracking
  local start_time=$(date +%s)
  
  # Start background processes to handle output
  (
    local line_count=0
    local dots_printed=0
    local current_transform=""
    local current_iterations=""
    local last_progress_time=$start_time
    
    while IFS= read -r line; do
      # Detect stage transitions
      if [[ "$line" =~ Stage[[:space:]]([0-9]+)[[:space:]]State ]]; then
        stage_count="${BASH_REMATCH[1]}"
        stage_start_time=$(date +%s)
        in_stage_header=true
        if [[ "$verbosity" != "quiet" ]]; then
          echo "" >&2
          echo -e "${BLUE}━━━ Stage $stage_count ━━━${NC}" >&2
        fi
        continue
      fi
      
      # Extract transform type
      if [[ "$line" =~ Transform[[:space:]]*=[[:space:]]*(Rigid|Affine|SyN|BSplineSyN|TimeVaryingSyN) ]]; then
        current_transform="${BASH_REMATCH[1]}"
        if [[ "$verbosity" != "quiet" ]] && [[ -n "$current_transform" ]]; then
          echo -e "  ${GREEN}►${NC} Transform type: $current_transform" >&2
        fi
        continue
      fi
      
      # Extract metric type
      if [[ "$line" =~ Image[[:space:]]metric[[:space:]]*=[[:space:]]*([A-Za-z]+) ]]; then
        local metric="${BASH_REMATCH[1]}"
        if [[ "$verbosity" == "verbose" ]]; then
          echo -e "  ${GREEN}►${NC} Similarity metric: $metric" >&2
        fi
        continue
      fi
      
      # Extract iterations
      if [[ "$line" =~ iterations[[:space:]]*=[[:space:]]*([0-9x]+) ]]; then
        current_iterations="${BASH_REMATCH[1]}"
        if [[ "$verbosity" != "quiet" ]]; then
          echo -e "  ${GREEN}►${NC} Max iterations: $current_iterations" >&2
        fi
        continue
      fi
      
      # Detect registration phase starts
      if [[ "$line" =~ \[PROGRESS\][[:space:]]Starting[[:space:]](.*)registration[[:space:]]phase ]]; then
        local phase="${BASH_REMATCH[1]}"
        if [[ "$verbosity" != "quiet" ]]; then
          echo -e "\n  ${YELLOW}▶${NC} Starting ${phase}registration..." >&2
          echo -n "  Progress: " >&2
          dots_printed=0
        fi
        continue
      fi
      
      # Detect elapsed time messages
      if [[ "$line" =~ Elapsed[[:space:]]time[[:space:]]\(stage[[:space:]]([0-9]+)\):[[:space:]]([0-9.e+]+) ]]; then
        local stage="${BASH_REMATCH[1]}"
        local elapsed="${BASH_REMATCH[2]}"
        if [[ "$verbosity" != "quiet" ]]; then
          # Clear the progress line
          echo -e "\r\033[K  ${GREEN}✓${NC} Stage $((stage + 1)) completed ($(printf "%.1f" $elapsed)s)" >&2
        fi
        continue
      fi
      
      # Apply filtering based on verbosity
      if [[ -n "$filter_pattern" ]] && echo "$line" | grep -qE "$filter_pattern"; then
        # Save to diagnostic log but don't display
        echo "$line" >> "$diagnostic_log"
      else
        # Check if this line should trigger a progress dot
        if [[ "$line" =~ CurrentIteration ]] || [[ "$line" =~ convergenceValue ]]; then
          if [[ "$verbosity" == "normal" ]]; then
            # Show progress dots at reasonable intervals
            local current_time=$(date +%s)
            if [[ $((current_time - last_progress_time)) -ge 2 ]]; then
              echo -n "." >&2
              dots_printed=$((dots_printed + 1))
              last_progress_time=$current_time
              # Wrap progress dots
              if [[ $dots_printed -ge 40 ]]; then
                echo "" >&2
                echo -n "  Progress: " >&2
                dots_printed=0
              fi
            fi
          fi
          echo "$line" >> "$diagnostic_log"
        else
          # Show the line if it passes filters
          if [[ "$verbosity" != "quiet" ]] || [[ "$line" =~ ERROR|WARNING|error|warning ]]; then
            echo "$line" | tee -a "$LOG_FILE"
          else
            echo "$line" >> "$LOG_FILE"
          fi
        fi
      fi
    done
    
    # Clear any remaining progress line
    if [[ $dots_printed -gt 0 ]]; then
      echo -e "\r\033[K" >&2
    fi
  ) < "$stdout_pipe" &
  local stdout_pid=$!
  
  # Handle stderr (mostly keep as-is but filter some patterns)
  (
    while IFS= read -r line; do
      if [[ -n "$filter_pattern" ]] && echo "$line" | grep -qE "$filter_pattern"; then
        echo "$line" >> "$diagnostic_log"
      else
        echo "$line" | tee -a "$diagnostic_log" >&2
      fi
    done
  ) < "$stderr_pipe" &
  local stderr_pid=$!
  
  # Execute command
  "${cmd[@]}" > "$stdout_pipe" 2> "$stderr_pipe"
  local status=$?
  
  # Wait for output handling processes to complete
  wait $stdout_pid
  wait $stderr_pid
  
  # Calculate elapsed time
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  
  # Show completion status based on verbosity
  if [[ "$verbosity" != "quiet" ]]; then
    echo "" >&2
    if [ $status -eq 0 ]; then
      log_formatted "SUCCESS" "✅ $step_description completed (${minutes}m ${seconds}s)"
      
      # Show visualization suggestions for normal and verbose modes
      if [[ "$verbosity" != "quiet" ]] && [[ "$cmd_str" == *"-o "* ]]; then
        local output_prefix=$(echo "$cmd_str" | grep -o -- "-o [^ ]*" | cut -d ' ' -f 2)
        
        # For brain extraction
        if [[ "$step_description" == *"brain extraction"* ]] || [[ "$step_description" == *"Brain extraction"* ]]; then
          if [[ -f "${output_prefix}BrainExtractionBrain.nii.gz" ]]; then
            echo -e "${BLUE}💡 Tip:${NC} View the extracted brain with:" >&2
            echo "     freeview ${output_prefix}BrainExtractionBrain.nii.gz" >&2
          fi
        
        # For registration
        elif [[ "$step_description" == *"registration"* ]] || [[ "$step_description" == *"Registration"* ]]; then
          if [[ -f "${output_prefix}Warped.nii.gz" ]]; then
            local fixed_img=$(echo "$cmd_str" | grep -o -- "-f [^ ]*" | cut -d ' ' -f 2 || echo "")
            echo -e "${BLUE}💡 Tip:${NC} Check registration quality with:" >&2
            echo "     freeview ${output_prefix}Warped.nii.gz${fixed_img:+ $fixed_img}" >&2
          fi
        fi
      fi
    else
      log_formatted "ERROR" "❌ $step_description failed (status: $status, duration: ${minutes}m ${seconds}s)"
      
      # Show last few error lines from diagnostic log
      if [[ -f "$diagnostic_log" ]] && [[ "$verbosity" != "quiet" ]]; then
        local error_lines=$(tail -n 20 "$diagnostic_log" | grep -i "error\|exception\|failed" | tail -n 3)
        if [[ -n "$error_lines" ]]; then
          echo -e "${RED}Last errors:${NC}" >&2
          echo "$error_lines" >&2
        fi
      fi
    fi
    
    echo "" >&2  # Add spacing after command completion
  elif [ $status -eq 0 ]; then
    # Quiet mode - just show completion
    log_formatted "SUCCESS" "✓ $step_description"
  else
    # Quiet mode - show errors
    log_formatted "ERROR" "✗ $step_description failed (status: $status)"
  fi
  
  # Remove named pipes
  rm -f "$stdout_pipe" "$stderr_pipe"
  
  # Return the exit code of the command
  return $status
}

# Export logging functions so they're available to subshells
export -f log_message log_formatted log_error log_diagnostic execute_with_logging execute_ants_command

# ------------------------------------------------------------------------------
# Shell Options
# ------------------------------------------------------------------------------
set -e
set -u
set -o pipefail


# Defer log directory creation until RESULTS_DIR is set
# This function should be called after parse_arguments sets RESULTS_DIR
initialize_log_directory() {
  export LOG_DIR="${RESULTS_DIR}/logs"
  mkdir -p "$LOG_DIR"
  mkdir -p "$RESULTS_DIR"
  export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"
}

# Set defaults to avoid unbound variable errors (e.g., when running --help)
export RESULTS_DIR="${RESULTS_DIR:-../mri_results}"
export LOG_DIR="${LOG_DIR:-${RESULTS_DIR}/logs}"
export LOG_FILE="${LOG_FILE:-/dev/null}"

# ------------------------------------------------------------------------------
# Export environment variables just defined above
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
PROCESSING_DATATYPE="float"  # internal float
OUTPUT_DATATYPE="int"        # final int16

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Using default paths for templates."
  export TEMPLATE_DIR="/usr/local/fsl/data/standard"
  # Don't exit - allow pipeline to continue with default paths
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
# Set default templates only if not already defined (allow config override)
EXTRACTION_TEMPLATE="${EXTRACTION_TEMPLATE:-MNI152_T1_1mm.nii.gz}"
PROBABILITY_MASK="${PROBABILITY_MASK:-MNI152_T1_1mm_brain_mask.nii.gz}"
REGISTRATION_MASK="${REGISTRATION_MASK:-MNI152_T1_1mm_brain_mask_dil.nii.gz}"

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
                     "antsApplyTransforms" "antsBrainExtraction.sh" "MeasureImageSimilarity" \
                     "ThresholdImage" "ImageMath")
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
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast" "fslcc")
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

# Detect platform-appropriate stat command for file size
# Called once at startup; exports get_file_size for all modules
_detect_stat_variant() {
    if stat --format="%s" /dev/null &>/dev/null; then
        # GNU coreutils stat (Linux)
        get_file_size() { stat --format="%s" "$1"; }
    elif stat -f "%z" /dev/null &>/dev/null; then
        # BSD stat (macOS)
        get_file_size() { stat -f "%z" "$1"; }
    else
        # Fallback: use wc -c (POSIX, slightly slower)
        get_file_size() { wc -c < "$1" | tr -d ' '; }
    fi
    export -f get_file_size
}
_detect_stat_variant

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

# Comprehensive check of all dependencies needed by the pipeline
check_all_dependencies() {
  log_formatted "INFO" "==== Comprehensive Pipeline Dependency Check ===="
  
  local error_count=0
  local warning_count=0
  
  # Required core tools
  log_formatted "INFO" "==== Checking core processing tools ===="
  
  # DICOM Conversion
  check_command "dcm2niix" "dcm2niix (DICOM converter)" "Install with: brew install dcm2niix" || error_count=$((error_count+1))
  if command -v dcmdump &>/dev/null; then
    log_formatted "SUCCESS" "✓ DCMTK (dcmdump) is installed ($(command -v dcmdump))"
  else
    log_formatted "WARNING" "⚠ DCMTK (dcmdump) is not installed - DICOM header analysis will be limited"
    warning_count=$((warning_count+1))
  fi
  
  # Check ANTs tools - critical for most operations
  check_ants || error_count=$((error_count+1))
  
  # Check FSL tools - critical for basic operations
  check_fsl || error_count=$((error_count+1))
  
  # FreeSurfer tools - used for visualization and some analyses
  check_freesurfer || error_count=$((error_count+1))
  
  # Convert3D - used for some preprocessing
  check_c3d || error_count=$((error_count+1))
  
  # Check operating system
  check_os
  
  # Check for Python (needed for analyze_dicom_headers.py)
  log_formatted "INFO" "==== Checking Python environment ===="
  local python_cmd=""
  if command -v python3 &>/dev/null; then
    python_cmd="python3"
    log_formatted "SUCCESS" "✓ Python 3 is installed ($(command -v python3))"
  elif command -v python &>/dev/null; then
    python_cmd="python"
    log_formatted "SUCCESS" "✓ Python is installed ($(command -v python))"
  else
    log_formatted "ERROR" "✗ Python is not installed or not in PATH"
    error_count=$((error_count+1))
  fi
  
  # Check for required scripts
  log_formatted "INFO" "==== Checking for required scripts ===="
  
  # Check for fix_dcm2niix_duplicates.sh
  local script_paths=(
    "src/modules/fix_dcm2niix_duplicates.sh"
    "../src/modules/fix_dcm2niix_duplicates.sh"
    "$(dirname "${BASH_SOURCE[0]}")/../fix_dcm2niix_duplicates.sh"
  )
  
  local script_found=false
  for path in "${script_paths[@]}"; do
    if [ -f "$path" ]; then
      script_found=true
      log_formatted "SUCCESS" "✓ fix_dcm2niix_duplicates.sh found at $path"
      break
    fi
  done
  
  if [ "$script_found" = false ]; then
    log_formatted "WARNING" "⚠ fix_dcm2niix_duplicates.sh not found in any expected location"
    warning_count=$((warning_count+1))
  fi
  
  # Check for analyze_dicom_headers.py
  script_paths=(
    "src/modules/analyze_dicom_headers.py"
    "../src/modules/analyze_dicom_headers.py"
    "$(dirname "${BASH_SOURCE[0]}")/../analyze_dicom_headers.py"
  )
  
  script_found=false
  for path in "${script_paths[@]}"; do
    if [ -f "$path" ]; then
      script_found=true
      log_formatted "SUCCESS" "✓ analyze_dicom_headers.py found at $path"
      break
    fi
  done
  
  if [ "$script_found" = false ]; then
    log_formatted "WARNING" "⚠ analyze_dicom_headers.py not found in any expected location"
    warning_count=$((warning_count+1))
  fi
  
  # Check for optional but recommended tools
  log_formatted "INFO" "==== Checking optional but recommended tools ===="
  
  # Check for ImageMagick (useful for image manipulation)
  check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || {
    log_formatted "WARNING" "⚠ ImageMagick is recommended for image conversions"
    warning_count=$((warning_count+1))
  }
  
  # Check for GNU Parallel - REQUIRED for DICOM parallel processing
  if ! check_command "parallel" "GNU Parallel" "Install with: brew install parallel"; then
    log_formatted "ERROR" "✗ GNU Parallel is required for DICOM parallel processing"
    error_count=$((error_count+1))
  else
    # Verify this is GNU parallel and not the one from moreutils
    if ! parallel --version 2>&1 | grep -q "GNU parallel"; then
      log_formatted "ERROR" "✗ Found 'parallel' command, but it doesn't appear to be GNU parallel"
      log_formatted "INFO" "On some systems, 'moreutils' provides a different 'parallel' command"
      log_formatted "INFO" "Install GNU Parallel: https://www.gnu.org/software/parallel/"
      error_count=$((error_count+1))
    fi
  fi
  
  # Optional / feature-gated dependency inventory (report-only, NON-fatal).
  # Enumerates EVERY optional tool, container image, Python package and atlas the
  # pipeline can use, grouped by feature, and cross-references the config toggles
  # so the user sees upfront what will run vs skip. Never increments error_count
  # (optional deps must never abort the run); it only emits informational lines.
  check_optional_dependencies || true

  # Summary
  log_formatted "INFO" "==== Dependency Check Summary ===="

  if [ $error_count -eq 0 ] && [ $warning_count -eq 0 ]; then
    log_formatted "SUCCESS" "All required dependencies are installed and configured correctly!"
    return 0
  elif [ $error_count -eq 0 ]; then
    log_formatted "SUCCESS" "✓ All required dependencies are installed!"
    log_formatted "WARNING" "⚠ $warning_count non-critical dependencies are missing or misconfigured."
    log_formatted "INFO" "The pipeline will work, but some features might be limited."
    return 0
  else
    log_error "$error_count critical dependencies are missing!" 127
    [ $warning_count -gt 0 ] && log_formatted "WARNING" "Additionally, $warning_count non-critical dependencies are missing."
    log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Optional / feature-gated dependency inventory (report-only, NON-fatal)
# ------------------------------------------------------------------------------
# Enumerates EVERY optional external tool, Python package, container image and
# atlas that any pipeline module can use, grouped by feature, and cross-checks
# the config toggles that gate each feature. Output is a one-line-per-dependency
# matrix:
#
#   <name> | REQ|OPT | present|absent (+path/version) | gates: <feature>
#
# This NEVER aborts the pipeline (every dependency here is optional); genuine
# core requirements are still enforced by check_all_dependencies above. When a
# feature is ENABLED via config but its dependency is missing, a clear WARNING
# is logged ("X enabled but <tool> not found — will skip"). At the end it prints
# counts and the concise list of optional features that WILL be skipped.

# Probe a single command. Echoes "present|<path>" or "absent". Always returns 0.
_dep_probe_cmd() {
  local cmd="$1"
  local path
  if path="$(command -v "$cmd" 2>/dev/null)"; then
    printf 'present|%s' "$path"
  else
    printf 'absent'
  fi
}

# Probe an importable Python module via uv (Python 3.12.8; never bare python).
# --no-sync so a mere availability probe never triggers a slow/network sync.
# Short timeout so a broken environment can never hang startup. Echoes
# "present" or "absent". Always returns 0.
_dep_probe_pymodule() {
  local module="$1"
  if ! command -v uv >/dev/null 2>&1; then
    printf 'absent'
    return 0
  fi
  if _dep_timeout 25 uv run --no-sync python -c "import ${module}" >/dev/null 2>&1; then
    printf 'present'
  else
    printf 'absent'
  fi
}

# Portable bounded-time runner. Uses `timeout`/`gtimeout` when present; otherwise
# falls back to a background-process watchdog so container/python probes can
# never hang the startup check. Args: <seconds> <cmd...>. Returns the command's
# exit status, or 124 on timeout (matching coreutils `timeout`).
_dep_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  # Fallback watchdog (no coreutils timeout, e.g. stock macOS /bin/bash). A
  # sentinel file lets us tell a real timeout (→124) from a command that simply
  # exited non-zero on its own. Every kill is `|| true` so a race where the
  # target already exited can never abort under the caller's set -e.
  local timedout="${TMPDIR:-/tmp}/.dep_timeout.$$.$RANDOM"
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; : > "$timedout"; kill -TERM "$cmd_pid" 2>/dev/null || true ) &
  local wd_pid=$!
  local status=0
  wait "$cmd_pid" 2>/dev/null || status=$?
  kill -TERM "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true
  if [ -f "$timedout" ]; then
    rm -f "$timedout" 2>/dev/null || true
    return 124
  fi
  return "$status"
}

# Probe a container image. Detects whether the image is materialised for an
# available runtime (Docker image, or an Apptainer/Singularity .sif on disk).
# Args: <docker_image_or_empty> <sif_path_or_empty>
# Echoes "present|<detail>" or "absent". Always returns 0; short timeouts so a
# wedged Docker daemon never hangs the startup check.
_dep_probe_image() {
  local docker_image="${1:-}"
  local sif_path="${2:-}"

  # Apptainer/Singularity .sif on disk (fast, no daemon).
  if [ -n "$sif_path" ] && [ -f "$sif_path" ] && \
     { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
    printf 'present|sif:%s' "$sif_path"
    return 0
  fi
  # A bare .sif may also be passed as the "docker_image" arg (SHIVA/segcsvd).
  if [ -n "$docker_image" ] && [ -f "$docker_image" ] && \
     { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
    printf 'present|sif:%s' "$docker_image"
    return 0
  fi
  # Docker image inspect (bounded; a hung daemon returns absent, never hangs).
  if [ -n "$docker_image" ] && command -v docker >/dev/null 2>&1; then
    if _dep_timeout 8 docker image inspect "$docker_image" >/dev/null 2>&1; then
      printf 'present|docker:%s' "$docker_image"
      return 0
    fi
  fi
  printf 'absent'
  return 0
}

# Emit one matrix line and (for OPT deps that gate an ENABLED feature but are
# absent) a WARNING. Increments the module-scope counters by name reference.
# Args: <name> <REQ|OPT> <probe-result> <gates-feature> [<enabled:true|false>]
_dep_report() {
  local name="$1" kind="$2" probe="$3" gates="$4" enabled="${5:-}"
  local state detail
  if [ "${probe%%|*}" = "present" ]; then
    state="present"
    detail="${probe#present}"; detail="${detail#|}"
  else
    state="absent"
    detail=""
  fi

  local line
  if [ -n "$detail" ]; then
    line="  ${name} | ${kind} | ${state} (${detail}) | gates: ${gates}"
  else
    line="  ${name} | ${kind} | ${state} | gates: ${gates}"
  fi

  if [ "$state" = "present" ]; then
    log_formatted "SUCCESS" "✓ ${line}"
    _DEP_PRESENT=$((_DEP_PRESENT + 1))
  else
    log_formatted "INFO" "· ${line}"
    _DEP_ABSENT=$((_DEP_ABSENT + 1))
    # Enabled-but-missing → actionable WARNING + add to the skip list.
    if [ "$kind" = "OPT" ] && [ "$enabled" = "true" ]; then
      log_formatted "WARNING" "⚠ ${gates} is ENABLED but ${name} not found — that feature will be SKIPPED"
      _DEP_SKIPPED_FEATURES+=("${gates} (missing ${name})")
    fi
  fi
}

check_optional_dependencies() {
  log_formatted "INFO" "==== Optional / Feature-Gated Dependency Inventory ===="
  log_message  "Legend: name | REQ/OPT | present/absent (+path/version) | gates-which-feature"

  # Module-scope counters / lists (consumed by _dep_report and the summary).
  _DEP_PRESENT=0
  _DEP_ABSENT=0
  _DEP_SKIPPED_FEATURES=()

  # Resolve the effective config toggles (mirror config/default_config.sh
  # defaults so the report is correct even if config has not been sourced yet).
  local seg_method="${BRAINSTEM_SEGMENTATION_METHOD:-all}"
  local seg_run_fs="${SEG_RUN_FREESURFER:-true}"
  local seg_run_synthseg="${SEG_RUN_SYNTHSEG:-true}"
  local use_synthsr="${USE_SYNTHSR:-false}"
  local process_dwi="${PROCESS_DWI:-false}"
  local wmh_bianca="${WMH_BIANCA_ENABLED:-false}"
  local wmh_lstai="${WMH_LSTAI_ENABLED:-false}"
  local wmh_samseg="${WMH_SAMSEG_ENABLED:-false}"
  local wmh_synthseg="${WMH_SYNTHSEG_ENABLED:-true}"
  local wmh_segcsvd="${WMH_SEGCSVD_ENABLED:-false}"
  local wmh_shiva="${WMH_SHIVA_ENABLED:-true}"
  local wmh_mars="${WMH_MARS_ENABLED:-true}"
  local mars_brainstem="${MARS_BRAINSTEM_ENABLED:-false}"
  local aanseg="${BRAINSTEM_AANSEG_ENABLED:-false}"

  # FreeSurfer is needed when its seg path or any FS-backed WMH/seg feature runs.
  local fs_enabled=false
  if { [ "$seg_method" = "all" ] && [ "$seg_run_fs" = true ]; } || \
     [ "$seg_method" = "freesurfer" ] || \
     [ "$wmh_samseg" = true ] || [ "$wmh_synthseg" = true ] || \
     [ "$use_synthsr" = true ] || [ "$aanseg" = true ]; then
    fs_enabled=true
  fi

  # ── Core required tools (mirror check_ants/check_fsl extents, report-only) ──
  # These are ALSO enforced (fatally) by check_all_dependencies; listing them
  # here gives the user one authoritative inventory. Marked REQ.
  log_formatted "INFO" "---- Core (REQUIRED) ----"
  local t
  for t in fslmaths flirt fast bet robustfov cluster fslstats fslinfo; do
    _dep_report "$t" "REQ" "$(_dep_probe_cmd "$t")" "FSL core"
  done
  for t in antsRegistration antsApplyTransforms N4BiasFieldCorrection \
           DenoiseImage Atropos ThresholdImage ImageMath ResampleImage \
           antsRegistrationSyN.sh; do
    _dep_report "$t" "REQ" "$(_dep_probe_cmd "$t")" "ANTs core"
  done
  _dep_report "dcm2niix" "REQ" "$(_dep_probe_cmd dcm2niix)" "DICOM import"
  _dep_report "c3d"      "REQ" "$(_dep_probe_cmd c3d)"      "Convert3D ops"
  _dep_report "uv"       "REQ" "$(_dep_probe_cmd uv)"       "Python (uv) runtime"
  for t in nibabel numpy sklearn; do
    _dep_report "python:${t}" "REQ" "$(_dep_probe_pymodule "$t")" "GMM / image I/O"
  done

  # ── FreeSurfer (OPTIONAL) ──
  log_formatted "INFO" "---- FreeSurfer (OPTIONAL) ----"
  local fs_home_probe="absent"
  [ -n "${FREESURFER_HOME:-}" ] && [ -d "${FREESURFER_HOME:-}" ] && fs_home_probe="present|${FREESURFER_HOME}"
  _dep_report "FREESURFER_HOME" "OPT" "$fs_home_probe" "FreeSurfer seg/recon" "$fs_enabled"
  local fs_lic="absent"
  if [ -n "${FS_LICENSE:-}" ] && [ -f "${FS_LICENSE:-}" ]; then
    fs_lic="present|${FS_LICENSE}"
  elif [ -f "${FREESURFER_HOME:-}/license.txt" ]; then
    fs_lic="present|${FREESURFER_HOME}/license.txt"
  elif [ -f "${FREESURFER_HOME:-}/.license" ]; then
    fs_lic="present|${FREESURFER_HOME}/.license"
  fi
  # Only treat a missing license as a skip-cause when FREESURFER_HOME itself is
  # present — otherwise the missing-FREESURFER_HOME warning above already covers
  # the root cause and we would double-count the same "FreeSurfer not installed".
  local lic_gate=""
  [ "${fs_home_probe%%|*}" = present ] && lic_gate="$fs_enabled"
  _dep_report "FreeSurfer license" "OPT" "$fs_lic" "FreeSurfer seg/recon" "$lic_gate"
  _dep_report "recon-all"             "OPT" "$(_dep_probe_cmd recon-all)"             "FS brainstem (recon)" "$fs_enabled"
  # segmentBS.sh OR segment_subregions satisfies the brainstem substructure path.
  local segbs; segbs="$(_dep_probe_cmd segmentBS.sh)"
  [ "${segbs%%|*}" != present ] && segbs="$(_dep_probe_cmd segment_subregions)"
  _dep_report "segmentBS.sh/segment_subregions" "OPT" "$segbs" "FS brainstem substructures" "$fs_enabled"
  _dep_report "SegmentAAN.sh"        "OPT" "$(_dep_probe_cmd SegmentAAN.sh)"          "AANSegment nuclei"        "$aanseg"
  _dep_report "mri_synthseg"         "OPT" "$(_dep_probe_cmd mri_synthseg)"           "SynthSeg ML seg"          "$seg_run_synthseg"
  _dep_report "mri_synthsr"          "OPT" "$(_dep_probe_cmd mri_synthsr)"            "SynthSR super-res"        "$use_synthsr"
  _dep_report "mri_synthstrip"       "OPT" "$(_dep_probe_cmd mri_synthstrip)"         "SynthStrip brain extract"
  _dep_report "mri_WMHsynthseg"      "OPT" "$(_dep_probe_cmd mri_WMHsynthseg)"        "WMH-SynthSeg"             "$wmh_synthseg"
  _dep_report "mri_sclimbic_seg"     "OPT" "$(_dep_probe_cmd mri_sclimbic_seg)"       "ScLimbic harvest"
  _dep_report "mri_segment_hypothalamic_subunits" "OPT" "$(_dep_probe_cmd mri_segment_hypothalamic_subunits)" "Hypothalamus harvest"
  _dep_report "run_samseg"           "OPT" "$(_dep_probe_cmd run_samseg)"             "SAMSEG WMH"               "$wmh_samseg"

  # ── MRtrix (OPTIONAL — DWI preprocessing) ──
  log_formatted "INFO" "---- MRtrix (OPTIONAL) ----"
  for t in dwidenoise mrdegibbs dwifslpreproc dwibiascorrect dwi2mask mrconvert; do
    _dep_report "$t" "OPT" "$(_dep_probe_cmd "$t")" "DWI preprocessing (PROCESS_DWI)" "$process_dwi"
  done

  # Probe the container images up front: SHIVA and LST-AI each accept multiple
  # ALTERNATIVE back-ends (any-of), so the enabled-but-missing WARNING must fire
  # only when EVERY back-end is absent — never once per alternative (that would
  # falsely claim a feature will skip when one of its back-ends is present).
  local img_shiva img_lstai
  img_shiva="$(_dep_probe_image "${SHIVA_WMH_CONTAINER_IMAGE:-}" "${SHIVA_WMH_CONTAINER_IMAGE:-}")"
  img_lstai="$(_dep_probe_image "${LSTAI_DOCKER_IMAGE:-jqmcginnis/lst-ai:latest}" "")"

  # ── WMH / ML tools (OPTIONAL) ──
  log_formatted "INFO" "---- WMH / ML tools (OPTIONAL) ----"
  _dep_report "bianca"          "OPT" "$(_dep_probe_cmd bianca)"          "FSL BIANCA WMH"  "$wmh_bianca"
  _dep_report "make_bianca_mask" "OPT" "$(_dep_probe_cmd make_bianca_mask)" "FSL BIANCA mask" "$wmh_bianca"

  # SHIVA-WMH: antspynet OR a SHiVAi container (any-of). Report each back-end as
  # informational; warn ONCE only when both are absent and the feature is on.
  local shiva_antspynet; shiva_antspynet="$(_dep_probe_pymodule antspynet)"
  _dep_report "python:antspynet" "OPT" "$shiva_antspynet" "SHIVA-WMH (antspynet back-end)"
  _dep_report "image:SHiVAi"     "OPT" "$img_shiva"        "SHIVA-WMH (container back-end)"
  local shiva_any="absent"
  { [ "${shiva_antspynet%%|*}" = present ] || [ "${img_shiva%%|*}" = present ]; } && shiva_any="present"
  _dep_report "SHIVA-WMH back-end" "OPT" "$shiva_any" "SHIVA-WMH" "$wmh_shiva"

  # LST-AI: 'lst' CLI OR importable lst_ai module OR Docker image (any-of).
  local lstai_cli; lstai_cli="$(_dep_probe_cmd lst)"
  [ "${lstai_cli%%|*}" != present ] && lstai_cli="$(_dep_probe_pymodule lst_ai)"
  _dep_report "LST-AI (lst / lst_ai)" "OPT" "$lstai_cli" "LST-AI (CLI/module back-end)"
  _dep_report "image:LST-AI"          "OPT" "$img_lstai"  "LST-AI (container back-end)"
  local lstai_any="absent"
  { [ "${lstai_cli%%|*}" = present ] || [ "${img_lstai%%|*}" = present ]; } && lstai_any="present"
  _dep_report "LST-AI back-end" "OPT" "$lstai_any" "LST-AI WMH" "$wmh_lstai"

  # ── Container runtimes + images (OPTIONAL) ──
  log_formatted "INFO" "---- Container runtimes & images (OPTIONAL) ----"
  _dep_report "docker"               "OPT" "$(_dep_probe_cmd docker)"      "containerised WMH tools"
  local appt; appt="$(_dep_probe_cmd apptainer)"
  [ "${appt%%|*}" != present ] && appt="$(_dep_probe_cmd singularity)"
  _dep_report "apptainer/singularity" "OPT" "$appt" "containerised WMH tools (.sif)"
  # Single-back-end containers: each is gated directly on its feature toggle.
  _dep_report "image:segcsvd"        "OPT" "$(_dep_probe_image "${SEGCSVD_DOCKER_IMAGE:-segcsvd_rc03}" "${SEGCSVD_CONTAINER_IMAGE:-}")" "segcsvdWMH" "$wmh_segcsvd"
  _dep_report "image:MARS-WMH"       "OPT" "$(_dep_probe_image "${MARS_WMH_DOCKER_IMAGE:-ghcr.io/miac-research/wmh-nnunet:latest}" "${MARS_WMH_SIF:-}")" "MARS-WMH" "$wmh_mars"
  _dep_report "image:MARS-brainstem" "OPT" "$(_dep_probe_image "${MARS_BRAINSTEM_DOCKER_IMAGE:-ghcr.io/miac-research/dl-brainstem:latest}" "${MARS_BRAINSTEM_SIF:-}")" "MARS brainstem ROI" "$mars_brainstem"

  # ── Atlases (OPTIONAL) — delegate the heavy on-disk probing to the dedicated
  # check_atlas_availability (called separately from main() after config load).
  log_formatted "INFO" "---- Atlases (OPTIONAL) ----"
  log_message "Atlas presence/absence is reported in detail by the Atlas Availability Check (see below): Bianciardi / CIT168 / AAL3 / HarvardOxford under \${FSLDIR}/data/atlases"
  local atlas_root="${FSLDIR:-}/data/atlases"
  local ho_probe="absent"
  if [ -d "${atlas_root}/${ATLAS_HARVARDOXFORD_REL:-HarvardOxford}" ]; then
    ho_probe="present|${atlas_root}/${ATLAS_HARVARDOXFORD_REL:-HarvardOxford}"
  fi
  _dep_report "atlas:HarvardOxford" "OPT" "$ho_probe" "Harvard-Oxford gross extent"
  local std_probe="absent"
  if [ -d "${FSLDIR:-}/data/standard" ]; then
    std_probe="present|${FSLDIR}/data/standard"
  fi
  _dep_report "FSL standard templates" "OPT" "$std_probe" "MNI registration targets"

  # ── Inventory summary ──
  log_formatted "INFO" "==== Optional Dependency Inventory Summary ===="
  log_formatted "INFO" "Dependencies present: ${_DEP_PRESENT} | absent: ${_DEP_ABSENT}"
  if [ "${#_DEP_SKIPPED_FEATURES[@]}" -eq 0 ]; then
    log_formatted "SUCCESS" "✓ No ENABLED optional feature is missing its dependency."
  else
    log_formatted "WARNING" "⚠ Optional features that WILL be SKIPPED (enabled but missing deps):"
    local f
    for f in "${_DEP_SKIPPED_FEATURES[@]}"; do
      log_formatted "WARNING" "    - ${f}"
    done
  fi

  return 0
}

# ------------------------------------------------------------------------------
# Atlas availability check (report-only / NON-fatal)
# ------------------------------------------------------------------------------
# Reports which optional brain atlases are installed under
# "${FSLDIR}/data/atlases" so the absence/presence is visible in the startup
# log alongside the dependency check. Never aborts: missing atlases simply mean
# the corresponding segmentation method degrades or is unavailable. If a
# brainstem/multi-atlas method is selected but its atlas is missing, a clear
# WARNING is logged (still non-fatal).
check_atlas_availability() {
  log_formatted "INFO" "==== Atlas Availability Check ===="

  local atlas_root="${FSLDIR:-}/data/atlases"
  if [ -z "${FSLDIR:-}" ] || [ ! -d "$atlas_root" ]; then
    log_formatted "WARNING" "⚠ FSL atlas directory not found (${atlas_root}); skipping atlas availability check"
    log_message "Atlas availability: UNKNOWN (no ${atlas_root})"
    return 0
  fi

  # Resolve atlas-relative paths (config-overridable, with sane fallbacks).
  local bianciardi_rel="${ATLAS_BIANCIARDI_REL:-Bianciardi/BrainstemNavigatorv1.0/1.0/2a.BrainstemNucleiAtlas_MNI}"
  local cit168_rel="${ATLAS_CIT168_REL:-CIT168/MNI152}"
  local aal3_rel="${ATLAS_AAL3_REL:-AAL3/AAL3}"
  local ho_rel="${ATLAS_HARVARDOXFORD_REL:-HarvardOxford}"

  # Detection helpers. A glob is "present" if it expands to >=1 existing file.
  local bianciardi_ok=false cit168_ok=false aal3_ok=false ho_ok=false

  # Bianciardi: a directory (the brainstem-nuclei atlas tree).
  if [ -d "${atlas_root}/${bianciardi_rel}" ] || \
     compgen -G "${atlas_root}/${bianciardi_rel}"* > /dev/null 2>&1; then
    bianciardi_ok=true
  fi
  # CIT168: a *dseg*.nii.gz under the MNI152 subdir.
  if compgen -G "${atlas_root}/${cit168_rel}/"*dseg*.nii.gz > /dev/null 2>&1; then
    cit168_ok=true
  fi
  # AAL3: AAL3v1*.nii(.gz) label volume.
  if compgen -G "${atlas_root}/${aal3_rel}/AAL3v1"*.nii* > /dev/null 2>&1; then
    aal3_ok=true
  fi
  # Harvard-Oxford (core sub atlas): the directory plus a maxprob label volume.
  if [ -d "${atlas_root}/${ho_rel}" ] && \
     compgen -G "${atlas_root}/${ho_rel}/HarvardOxford-sub-maxprob"*.nii* > /dev/null 2>&1; then
    ho_ok=true
  fi

  _report_atlas() {
    local label="$1" ok="$2"
    if [ "$ok" = true ]; then
      log_formatted "SUCCESS" "✓ Atlas present: ${label}"
    else
      log_formatted "WARNING" "⚠ Atlas absent: ${label}"
    fi
  }

  _report_atlas "Bianciardi (BrainstemNavigator)" "$bianciardi_ok"
  _report_atlas "CIT168 (MNI152 dseg)"            "$cit168_ok"
  _report_atlas "AAL3"                            "$aal3_ok"
  _report_atlas "HarvardOxford (subcortical)"     "$ho_ok"

  # Warn if the selected segmentation method needs an atlas that is missing.
  # Default mirrors config (BRAINSTEM_SEGMENTATION_METHOD default = 'all').
  local seg_method="${BRAINSTEM_SEGMENTATION_METHOD:-all}"
  case "$seg_method" in
    all)
      # Parallel 'all' mode: warn per ENABLED path about its required atlases.
      if [ "${SEG_RUN_HARVARD_OXFORD:-true}" = true ] && [ "$ho_ok" != true ]; then
        log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='all' (SEG_RUN_HARVARD_OXFORD=true) needs the Harvard-Oxford subcortical atlas, which is ABSENT"
      fi
      if [ "${SEG_RUN_MULTI_ATLAS:-true}" = true ]; then
        { [ "$bianciardi_ok" = true ] || [ "$cit168_ok" = true ] || [ "$aal3_ok" = true ]; } || \
          log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='all' (SEG_RUN_MULTI_ATLAS=true) needs at least one of Bianciardi/CIT168/AAL3; ALL are ABSENT"
      fi
      # The FreeSurfer path needs no atlas (recon-all/segmentBS); HO is its
      # gross-extent fallback, already reported above.
      ;;
    atlas|harvard_oxford)
      [ "$ho_ok" = true ] || \
        log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='$seg_method' requires the Harvard-Oxford subcortical atlas, which is ABSENT"
      ;;
    bianciardi)
      [ "$bianciardi_ok" = true ] || \
        log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='$seg_method' requires the Bianciardi atlas, which is ABSENT"
      ;;
    cit168)
      [ "$cit168_ok" = true ] || \
        log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='$seg_method' requires the CIT168 atlas, which is ABSENT"
      ;;
    multi_atlas|multi-atlas)
      { [ "$ho_ok" = true ] && [ "$bianciardi_ok" = true ] && [ "$cit168_ok" = true ] && [ "$aal3_ok" = true ]; } || \
        log_formatted "WARNING" "BRAINSTEM_SEGMENTATION_METHOD='$seg_method' benefits from all atlases; one or more are ABSENT"
      ;;
    *)
      : ;;  # freesurfer and others: Harvard-Oxford is the gross-extent fallback (reported above)
  esac

  # One-line summary for at-a-glance visibility in the startup log.
  local _b _c _a _h
  [ "$bianciardi_ok" = true ] && _b="Bianciardi=yes" || _b="Bianciardi=no"
  [ "$cit168_ok" = true ]     && _c="CIT168=yes"     || _c="CIT168=no"
  [ "$aal3_ok" = true ]       && _a="AAL3=yes"       || _a="AAL3=no"
  [ "$ho_ok" = true ]         && _h="HarvardOxford=yes" || _h="HarvardOxford=no"
  log_message "Atlas availability: ${_b}, ${_c}, ${_a}, ${_h}"

  return 0
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
  local file_size
  if ! file_size=$(get_file_size "$file"); then
    log_error "Cannot determine file size for $description: $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  if [ "$file_size" -lt "$min_size" ]; then
    log_error "$description has suspicious size ($file_size bytes, minimum $min_size): $file" $ERR_DATA_CORRUPT
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

  # Canonical aggregation/reporting output tree (see docs/output_structure.md).
  # The reporting layer DISCOVERS outputs wherever modules wrote them; these
  # dirs are created up front so the tree is consistent and the reporting stage
  # always has somewhere to write even on a minimal run.
  mkdir -p "$RESULTS_DIR/segmentation/detailed_brainstem"
  mkdir -p "$RESULTS_DIR/analysis/wmh"
  mkdir -p "$RESULTS_DIR/analysis/cross_modal"
  mkdir -p "$RESULTS_DIR/visualizations"
  mkdir -p "$RESULTS_DIR/reports/tables"

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

  # Probe for c3d (Convert3D) in common install locations if not already in PATH.
  # Must happen before check_all_dependencies runs.
  if ! command -v c3d &>/dev/null; then
    for _c3d_dir in /opt/homebrew/bin /usr/local/bin "/Applications/ITK-SNAP.app/Contents/bin"; do
      if [ -x "${_c3d_dir}/c3d" ]; then
        export PATH="$PATH:${_c3d_dir}"
        break
      fi
    done
  fi

  # Initialize log directory now that RESULTS_DIR is set
  initialize_log_directory

  log_message "Initializing environment"
  
  # Export functions
  export -f check_command
  export -f check_dependencies
  export -f check_all_dependencies
  export -f check_optional_dependencies
  export -f _dep_probe_cmd _dep_probe_pymodule _dep_probe_image _dep_report _dep_timeout
  export -f check_atlas_availability
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
  export -f log_diagnostic execute_with_logging
  
  log_message "Environment initialized"
}

compute_initial_affine() {
  local moving="$1"
  local fixed="$2"  # typically MNI
  local output_prefix="$3"

  if [[ ! -f "${output_prefix}0GenericAffine.mat" ]]; then
    echo "Generating initial affine for ${moving}"
    antsRegistrationSyNQuick.sh \
      -d 3 \
      -f "$fixed" \
      -m "$moving" \
      -t a \
      -o "$output_prefix"
  else
    echo "Affine already exists for ${moving}"
  fi
}

export compute_initial_affine

log_message "Environment module loaded"


# Export the safe_fslmaths function for emergency fix
export -f safe_fslmaths
