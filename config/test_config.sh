#!/usr/bin/env bash
#
# test_config.sh - Lightweight configuration for unit tests
#
# This config overrides the heavy production settings with fast,
# minimal settings optimized for testing functionality, not accuracy.
#

# Source the base config first
source "$(dirname "${BASH_SOURCE[0]}")/default_config.sh"

# Override with lightweight test settings
echo "[TEST CONFIG] Loading test configuration - optimized for speed, not accuracy"

# ------------------------------------------------------------------------------
# Test-Optimized Processing Parameters
# ------------------------------------------------------------------------------

# Lightweight N4 bias correction - just verify it works
export N4_PRESET_TEST="20x20,0.001,100,4"  # Fast 2-level, loose convergence
export N4_PRESET_LOW="$N4_PRESET_TEST"
export N4_PRESET_MEDIUM="$N4_PRESET_TEST"  
export N4_PRESET_HIGH="$N4_PRESET_TEST"
export N4_PRESET_FLAIR="$N4_PRESET_TEST"

# Override quality preset to use test settings
export QUALITY_PRESET="TEST"
export N4_PARAMS="$N4_PRESET_TEST"

# Parse test N4 parameters
export N4_ITERATIONS=$(echo "$N4_PARAMS" | cut -d',' -f1)
export N4_CONVERGENCE=$(echo "$N4_PARAMS" | cut -d',' -f2)
export N4_BSPLINE=$(echo "$N4_PARAMS" | cut -d',' -f3)
export N4_SHRINK=$(echo "$N4_PARAMS" | cut -d',' -f4)

# Lightweight registration settings
export REG_PRECISION=1  # Fast registration, not accurate
export ANTS_THREADS=4   # Don't overwhelm during tests

# Minimal template settings for speed
export TEMPLATE_ITERATIONS=1
export TEMPLATE_GRADIENT_STEP=0.1  # Larger steps = faster
export TEMPLATE_SHRINK_FACTORS="4x2x1"  # Fewer levels
export TEMPLATE_SMOOTHING_SIGMAS="2x1x0"
export TEMPLATE_WEIGHTS="50x25x10"  # Reduced weights

# Test-specific Atropos settings (tissue segmentation)
export ATROPOS_CONVERGENCE="3,0.01"  # Very loose convergence
export ATROPOS_MRF="[0.2,1x1x1]"     # Weaker MRF regularization

# Minimal hyperintensity detection
export THRESHOLD_WM_SD_MULTIPLIER=2.0  # Standard threshold
export MIN_HYPERINTENSITY_SIZE=10      # Larger minimum size

# Disable parallel processing for tests (as requested)
export PARALLEL_JOBS=0
export MAX_CPU_INTENSIVE_JOBS=1
export DICOM_IMPORT_PARALLEL=1

# Test output settings
export RESULTS_DIR="/tmp/test_results_$$"  # Temporary directory for tests
export LOG_DIR="$RESULTS_DIR/logs"

# Disable expensive validation steps for tests
export ORIENTATION_CORRECTION_ENABLED=false
export ORIENTATION_VALIDATION_ENABLED=false

# Use 2mm templates for faster processing in tests
export DEFAULT_TEMPLATE_RES="2mm"
export EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
export PROBABILITY_MASK="MNI152_T1_2mm_brain_mask.nii.gz"
export REGISTRATION_MASK="MNI152_T1_2mm_brain_mask_dil.nii.gz"

# Also set the 2mm variants directly
export EXTRACTION_TEMPLATE_2MM="MNI152_T1_2mm.nii.gz"
export PROBABILITY_MASK_2MM="MNI152_T1_2mm_brain_mask.nii.gz"
export REGISTRATION_MASK_2MM="MNI152_T1_2mm_brain_mask_dil.nii.gz"

# Disable resolution auto-detection for consistent test behavior
export AUTO_DETECT_RESOLUTION=false

# ------------------------------------------------------------------------------
# Test-Specific Functions
# ------------------------------------------------------------------------------

# Cleanup function for tests
cleanup_test_environment() {
    if [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ]; then
        echo "[TEST CONFIG] Cleaning up test environment: $RESULTS_DIR"
        rm -rf "$RESULTS_DIR"
    fi
}

# Export cleanup function
export -f cleanup_test_environment

# Set trap to cleanup on exit
trap cleanup_test_environment EXIT

echo "[TEST CONFIG] Test configuration loaded - using fast/minimal settings"
echo "[TEST CONFIG] N4 iterations: $N4_ITERATIONS (vs production: 200x200x200x50)"
echo "[TEST CONFIG] ANTS threads: $ANTS_THREADS (vs production: 48)"
echo "[TEST CONFIG] Template resolution: $DEFAULT_TEMPLATE_RES (vs production: 1mm)"
echo "[TEST CONFIG] Results directory: $RESULTS_DIR"