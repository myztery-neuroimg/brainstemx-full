#!/usr/bin/env bash
#
# test_integration.sh - Test script for module integration improvements
#
# This script tests the centralized path handling and error handling
# functionality added to the brain MRI processing pipeline.
#

# Source modules
source modules/environment.sh

# Print header
echo "=== Module Integration Test ==="
echo "Testing centralized path handling and error handling"
echo

# Initialize the environment
initialize_environment
check_dependencies
# Create test directories
TEST_DIR="${RESULTS_DIR}/integration_test"
mkdir -p "$TEST_DIR"
echo "Created test directory: $TEST_DIR"

# Test directory creation
# Reset the error tracking for each test
reset_error_status() {
  PIPELINE_SUCCESS=true
  PIPELINE_ERROR_COUNT=0
}

echo -n "Testing create_module_dir: "
test_dir=$(create_module_dir "test_module")
if [ -d "$test_dir" ]; then
  log_formatted "SUCCESS" "Directory created successfully: $test_dir"
else
  log_error "Failed to create directory: $test_dir" $ERR_GENERAL
fi

# Test path generation
echo -n "Testing get_output_path: "
test_path=$(get_output_path "test_module" "test_file" "_suffix")
expected_path="${RESULTS_DIR}/test_module/test_file_suffix.nii.gz"
if [ "$test_path" = "$expected_path" ]; then
  log_formatted "SUCCESS" "Path generated correctly: $test_path"
else
  log_error "Path generation failed. Expected: $expected_path, Got: $test_path" $ERR_GENERAL
fi

# Create a test file
echo -n "Creating test file: "
mkdir -p "$(dirname "$test_path")"
dd if=/dev/zero of="$test_path" bs=1024 count=10 2>/dev/null
if [ -f "$test_path" ]; then
  log_formatted "SUCCESS" "Test file created: $test_path"
else
  log_error "Failed to create test file: $test_path" $ERR_IO_ERROR
fi

# Test file validation
echo -n "Testing validate_file: "
if validate_file "$test_path" "Test file"; then
  log_formatted "SUCCESS" "File validation passed: $test_path"
else
  log_error "File validation failed: $test_path" $ERR_VALIDATION
fi

# Test non-existent file validation
# This test is supposed to fail validation, so we'll handle it separately
echo -n "Testing validate_file with non-existent file: "
non_existent_test_passed=false
if ! validate_file "${TEST_DIR}/nonexistent.nii.gz" "Nonexistent file"; then
  log_formatted "SUCCESS" "Correctly detected missing file"
  non_existent_test_passed=true
else
  log_error "Failed to detect missing file" $ERR_VALIDATION
fi

# Reset error status after this test since the error was expected
reset_error_status

# Test directory validation
echo -n "Testing validate_directory: " 
if validate_directory "$TEST_DIR" "Test directory"; then
  log_formatted "SUCCESS" "Directory validation passed: $TEST_DIR"
else
  log_error "Directory validation failed: $TEST_DIR" $ERR_VALIDATION
fi

# Test directory creation with validate_directory
echo -n "Testing validate_directory with creation: "
if validate_directory "${TEST_DIR}/subdir" "Test subdirectory" "true"; then
  log_formatted "SUCCESS" "Directory created and validated: ${TEST_DIR}/subdir"
else
  log_error "Directory creation/validation failed: ${TEST_DIR}/subdir" $ERR_VALIDATION
fi

# Determine overall test success
tests_passed=true
if [ "$PIPELINE_SUCCESS" != "true" ]; then
  tests_passed=false
fi

# Check if our special test for non-existent file passed
if [ "$non_existent_test_passed" != "true" ]; then
  tests_passed=false
fi

echo
echo "=== Test Summary ==="
if [ "$tests_passed" = "true" ]; then
  log_formatted "SUCCESS" "All integration tests passed!"
  exit 0
else
  log_error "Integration tests failed with $PIPELINE_ERROR_COUNT errors" $ERR_VALIDATION
  exit 1
fi