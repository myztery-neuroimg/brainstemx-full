#!/usr/bin/env bash
#
# test_parallel.sh - Test script for parallel processing
#
# This script tests the parallel processing functionality added to the
# brain MRI processing pipeline.
#

# Source modules
source src/modules/environment.sh
source src/modules/preprocess.sh

# Print header
echo "=== Parallel Processing Test ==="
echo "Testing parallel processing framework"
echo

# Initialize the environment
initialize_environment

# Load parallel configuration
load_parallel_config "config/parallel_config.sh"

# Test directories
TEST_DIR="${RESULTS_DIR}/parallel_test"
mkdir -p "$TEST_DIR"
echo "Created test directory: $TEST_DIR"

# Create some synthetic test data for processing
create_test_data() {
  local dir="$1"
  local count="${2:-5}"
  
  log_message "Creating $count test files in $dir"
  mkdir -p "$dir"
  
  for i in $(seq 1 $count); do
    # Create a 3D volume of size 64x64x64 filled with random values
    local file="${dir}/test_volume_${i}.nii.gz"
    
    # Check if the file already exists
    if [ -f "$file" ]; then
      log_message "Test file already exists: $file"
      continue
    fi
    
    # Create a temporary raw file
    local temp_raw="${dir}/temp_${i}.raw"
    dd if=/dev/urandom of="$temp_raw" bs=1048576 count=1 2>/dev/null
    
    # Use fslcreatehd to create a proper NIfTI header
    fslcreatehd 64 64 64 1 1 1 1 1 0 0 0 16 "$file"
    
    # Replace the data part with our random data
    fslmerge -t "$file" "$temp_raw"
    
    # Clean up temp file
    rm -f "$temp_raw"
    
    log_message "Created test file: $file"
  done
}

# Check if GNU parallel is available
echo "Checking GNU parallel availability..."
if check_parallel; then
  # Test with parallel processing
  echo
  echo "=== Testing Parallel Processing ==="
  
  # Create test data
  TEST_DATA_DIR="${TEST_DIR}/test_data"
  create_test_data "$TEST_DATA_DIR" 8
  
  # Function to measure execution time
  time_execution() {
    local start_time=$(date +%s.%N)
    "$@"
    local end_time=$(date +%s.%N)
    echo $(echo "$end_time - $start_time" | bc)
  }
  
  # Test sequential execution
  echo
  echo "Testing sequential execution..."
  seq_time=$(time_execution bash -c "
    for file in \"$TEST_DATA_DIR\"/*.nii.gz; do
      process_n4_correction \"\$file\"
    done
  ")
  
  echo "Sequential execution time: $seq_time seconds"
  
  # Clean up the results directory to start fresh
  rm -rf "${RESULTS_DIR}/bias_corrected"
  
  # Test parallel execution
  echo
  echo "Testing parallel execution with $PARALLEL_JOBS jobs..."
  par_time=$(time_execution run_parallel_n4_correction "$TEST_DATA_DIR" "*.nii.gz" "$PARALLEL_JOBS")
  
  echo "Parallel execution time: $par_time seconds"
  
  # Compare results
  echo
  echo "Comparing execution times:"
  speedup=$(echo "scale=2; $seq_time / $par_time" | bc)
  echo "Speedup factor: $speedup x"
  
  # Calculate theoretical maximum speedup
  theoretical_max=$PARALLEL_JOBS
  efficiency=$(echo "scale=2; ($speedup / $theoretical_max) * 100" | bc)
  echo "Parallel efficiency: $efficiency%"
  
  # Check if any errors occurred
  if [ "$PIPELINE_ERROR_COUNT" -gt 0 ]; then
    log_error "Parallel processing test encountered $PIPELINE_ERROR_COUNT errors" $ERR_GENERAL
    exit 1
  else
    log_formatted "SUCCESS" "Parallel processing test completed successfully"
  fi
else
  log_formatted "WARNING" "GNU parallel not available, skipping parallel tests"
fi

# Print summary
echo
echo "=== Test Summary ==="
if [ "$PIPELINE_SUCCESS" = "true" ]; then
  log_formatted "SUCCESS" "All parallel processing tests passed!"
  exit 0
else
  log_error "Parallel processing tests failed with $PIPELINE_ERROR_COUNT errors" $ERR_VALIDATION
  exit 1
fi