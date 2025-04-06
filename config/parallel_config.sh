#!/usr/bin/env bash
#
# parallel_config.sh - Parallelization configuration for the brain MRI pipeline
#
# This configuration file controls parallel processing options for the pipeline
#

# ------------------------------------------------------------------------------
# Parallelization Configuration
# ------------------------------------------------------------------------------

# Number of parallel jobs to use
# Set to 0 to disable parallel processing
# Set to a positive number to specify the number of parallel jobs
# Recommended: Number of CPU cores - 1
PARALLEL_JOBS=1

# Maximum number of parallel jobs for CPU-intensive operations
# This is used for operations like ANTs registration that use a lot of CPU
# Recommended: Half the number of CPU cores or less
MAX_CPU_INTENSIVE_JOBS=1

# Timeout (in seconds) for parallel operations
# If a parallel operation takes longer than this, it will be terminated
# Set to 0 to disable timeout
PARALLEL_TIMEOUT=0

# Halt behavior when parallel jobs fail
# Options:
#   "never" - Continue even if some jobs fail
#   "soon" - Complete currently running jobs but don't start new ones
#   "now" - Terminate all running jobs immediately
PARALLEL_HALT_MODE="soon"

# Additional options to pass to GNU parallel
# See 'man parallel' for options
PARALLEL_EXTRA_OPTIONS="--will-cite"

# ------------------------------------------------------------------------------
# Automatic CPU Core Detection (Optional)
# ------------------------------------------------------------------------------
# If set to true, the script will try to automatically set PARALLEL_JOBS
# based on the number of available CPU cores
AUTO_DETECT_CORES=false

# Function to auto-detect the number of CPU cores and set PARALLEL_JOBS
auto_detect_cores() {
  local available_cores=0
  
  # Try different methods to detect CPU cores based on OS
  if command -v nproc &> /dev/null; then
    # Linux
    available_cores=$(nproc)
  elif command -v sysctl &> /dev/null && sysctl -n hw.ncpu &> /dev/null; then
    # macOS
    available_cores=$(sysctl -n hw.ncpu)
  else
    # Default fallback
    available_cores=4
    echo "Could not detect CPU cores, using default value: $available_cores"
  fi
  
  # Set PARALLEL_JOBS to available_cores - 1 (leave one core for system)
  if [ "$available_cores" -gt 1 ]; then
    PARALLEL_JOBS=$((available_cores - 1))
  else
    PARALLEL_JOBS=1
  fi
  
  # Set MAX_CPU_INTENSIVE_JOBS to half of PARALLEL_JOBS
  MAX_CPU_INTENSIVE_JOBS=$((PARALLEL_JOBS / 2))
  if [ "$MAX_CPU_INTENSIVE_JOBS" -lt 1 ]; then
    MAX_CPU_INTENSIVE_JOBS=1
  fi
  
  echo "Auto-detected $available_cores CPU cores. Setting PARALLEL_JOBS=$PARALLEL_JOBS, MAX_CPU_INTENSIVE_JOBS=$MAX_CPU_INTENSIVE_JOBS"
}

# Auto-detect cores if enabled
if [ "$AUTO_DETECT_CORES" = true ]; then
  auto_detect_cores
fi
# Prioritize sagittal 3D sequences explicitly
export T1_PRIORITY_PATTERN="MPRAGE.*SAG"
export FLAIR_PRIORITY_PATTERN="SPACE.*FLAIR.*SAG"
export RESAMPLE_TO_ISOTROPIC=1
export ISOTROPIC_SPACING=1.0

