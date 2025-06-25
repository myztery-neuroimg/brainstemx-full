#!/usr/bin/env bash
#
# test_brain_extraction_fix.sh - Test script for the template-free brain extraction fix.
#
# This script tests the updated perform_brain_extraction function to ensure it
# runs without MNI template dependencies and produces the correct output files.
#

# Create a secure, temporary directory for test results using mktemp.
# This is done BEFORE sourcing any scripts to ensure they have a writable directory.
export RESULTS_DIR
RESULTS_DIR=$(mktemp -d)

# Source environment functions first
source src/modules/environment.sh

# Source test config, which will use and then override some of the vars
source config/test_config.sh

# Source other modules
source src/modules/utils.sh

# Now that configs are loaded, create the log directory defined in the config
mkdir -p "$LOG_DIR"

# Initialize environment and check dependencies
initialize_environment
check_dependencies

# --- Test Setup ---
echo "=== Brain Extraction Fix Test ==="
TEST_DIR="${RESULTS_DIR}/brain_extraction_fix_test"
mkdir -p "$TEST_DIR"
export LOG_FILE="${TEST_DIR}/test_output.log"

# Cleanup function to show logs on exit
cleanup() {
  echo "--- Test Log Output ---"
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
  else
    echo "Log file not found: $LOG_FILE"
  fi
  echo "-----------------------"
  # The test_config sets a trap to clean up RESULTS_DIR, so we don't do it here.
}
trap cleanup EXIT

log_message "Starting brain extraction fix test"
log_message "Test directory: $TEST_DIR"
log_message "Log file: $LOG_FILE"

# Create a dummy input file (a simple NIfTI file)
INPUT_FILE="${TEST_DIR}/test_t1.nii.gz"
log_message "Creating dummy T1 image: $INPUT_FILE"
fslcreatehd 10 10 10 1 1 1 1 1 0 0 0 16 "$INPUT_FILE"
if [ ! -f "$INPUT_FILE" ]; then
    log_error "Failed to create dummy input file." $ERR_IO_ERROR
    exit 1
fi

# --- Test Execution ---
log_message "Running perform_brain_extraction on dummy T1 image..."
OUTPUT_PREFIX="${TEST_DIR}/test_t1_"
perform_brain_extraction "$INPUT_FILE" "$OUTPUT_PREFIX"
extraction_status=$?

# --- Verification ---
BRAIN_FILE="${OUTPUT_PREFIX}BrainExtractionBrain.nii.gz"
MASK_FILE="${OUTPUT_PREFIX}BrainExtractionMask.nii.gz"

log_message "Verifying outputs..."
all_tests_passed=true

# 1. Check exit status
if [ $extraction_status -eq 0 ]; then
  log_formatted "SUCCESS" "perform_brain_extraction exited with status 0."
else
  log_error "perform_brain_extraction failed with status $extraction_status." $ERR_GENERAL
  all_tests_passed=false
fi

# 2. Check for brain file
if validate_file "$BRAIN_FILE" "Brain file"; then
  log_formatted "SUCCESS" "Brain output file created: $BRAIN_FILE"
else
  log_error "Brain output file is missing." $ERR_VALIDATION
  all_tests_passed=false
fi

# 3. Check for mask file
if validate_file "$MASK_FILE" "Mask file"; then
  log_formatted "SUCCESS" "Mask output file created: $MASK_FILE"
else
  log_error "Mask output file is missing." $ERR_VALIDATION
  all_tests_passed=false
fi

# --- Final Verdict ---
echo
log_message "=== Test Summary ==="
if [ "$all_tests_passed" = "true" ]; then
  log_formatted "SUCCESS" "All brain extraction fix tests passed!"
  exit 0
else
  log_error "Brain extraction fix tests failed." $ERR_GENERAL
  log_message "Test directory with intermediate files retained for debugging: $TEST_DIR"
  exit 1
fi