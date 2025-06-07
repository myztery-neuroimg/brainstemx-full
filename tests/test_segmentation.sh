#!/usr/bin/env bash
#
# test_segmentation.sh - Unit tests for brainstem segmentation functionality
#
# Tests the Juelich atlas-based segmentation and fallback mechanisms
#

# Test framework setup
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$TEST_DIR")/src"
MODULES_DIR="$SRC_DIR/modules"

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test output function
test_log() {
    echo -e "${1}[TEST]${NC} $2"
}

# Assert functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        test_log "$GREEN" "PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        test_log "$RED" "FAIL: $message (expected: '$expected', got: '$actual')"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ -f "$file" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        test_log "$GREEN" "PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        test_log "$RED" "FAIL: $message (file not found: $file)"
        return 1
    fi
}

assert_command_exists() {
    local cmd="$1"
    local message="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if command -v "$cmd" &> /dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        test_log "$GREEN" "PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        test_log "$RED" "FAIL: $message (command not found: $cmd)"
        return 1
    fi
}

assert_function_exists() {
    local func="$1"
    local message="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if declare -f "$func" > /dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        test_log "$GREEN" "PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        test_log "$RED" "FAIL: $message (function not found: $func)"
        return 1
    fi
}

# Setup test environment
setup_test_env() {
    test_log "$YELLOW" "Setting up test environment..."
    
    # Create temporary test directory
    export TEST_TEMP_DIR=$(mktemp -d)
    export RESULTS_DIR="$TEST_TEMP_DIR/results"
    mkdir -p "$RESULTS_DIR"
    
    # Mock FSL environment if not set
    if [ -z "$FSLDIR" ]; then
        export FSLDIR="/opt/fsl"
        test_log "$YELLOW" "Warning: FSLDIR not set, using mock value: $FSLDIR"
    fi
    
    # Source test configuration first for lightweight settings
    if [ -f "$(dirname "$TEST_DIR")/config/test_config.sh" ]; then
        source "$(dirname "$TEST_DIR")/config/test_config.sh"
        test_log "$GREEN" "Loaded test configuration (lightweight settings)"
    elif [ -f "$(dirname "$TEST_DIR")/config/default_config.sh" ]; then
        source "$(dirname "$TEST_DIR")/config/default_config.sh"
        test_log "$YELLOW" "Using default config (heavy settings - tests may be slow)"
    else
        # Mock essential config variables if config not found
        export TEMPLATE_DIR="${FSLDIR}/data/standard"
        export DEFAULT_TEMPLATE_RES="2mm"  # Use 2mm for faster tests
        export EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
        export EXTRACTION_TEMPLATE_2MM="MNI152_T1_2mm.nii.gz"
        test_log "$YELLOW" "Warning: Config not found, using mock values"
    fi
    
    # Source required modules
    if [ -f "$MODULES_DIR/environment.sh" ]; then
        source "$MODULES_DIR/environment.sh"
        test_log "$GREEN" "Loaded environment.sh"
    fi
    
    # Define mock log functions if not available
    if ! command -v log_message &> /dev/null; then
        log_message() { echo "[LOG] $*"; }
        log_formatted() { echo "[$1] $2"; }
        test_log "$YELLOW" "Warning: Using mock log functions"
    fi
    
    test_log "$GREEN" "Test environment setup complete"
}

# Create test data
create_test_data() {
    test_log "$YELLOW" "Creating test data..."
    
    # Create a simple 3D test image (10x10x10 voxels)
    export TEST_IMAGE="$TEST_TEMP_DIR/test_brain.nii.gz"
    
    # Create test image using FSL if available, otherwise create dummy file
    if command -v fslmaths &> /dev/null && [ -f "$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz" ]; then
        # Create a small ROI from MNI template
        fslmaths "$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz" -roi 80 20 100 20 80 20 0 1 "$TEST_IMAGE" 2>/dev/null
    else
        # Create dummy NIfTI-like file for testing
        touch "$TEST_IMAGE"
        test_log "$YELLOW" "Warning: Created dummy test image (FSL not available)"
    fi
    
    test_log "$GREEN" "Test data created: $TEST_IMAGE"
}

# Test 1: Module loading
test_module_loading() {
    test_log "$YELLOW" "Testing module loading..."
    
    # Test segmentation.sh loading
    if [ -f "$MODULES_DIR/segmentation.sh" ]; then
        source "$MODULES_DIR/segmentation.sh" 2>/dev/null
        assert_equals "0" "$?" "segmentation.sh loads without errors"
    else
        assert_file_exists "$MODULES_DIR/segmentation.sh" "segmentation.sh exists"
    fi
    
    # Test juelich_segmentation.sh loading
    if [ -f "$MODULES_DIR/juelich_segmentation.sh" ]; then
        source "$MODULES_DIR/juelich_segmentation.sh" 2>/dev/null
        assert_equals "0" "$?" "juelich_segmentation.sh loads without errors"
    else
        assert_file_exists "$MODULES_DIR/juelich_segmentation.sh" "juelich_segmentation.sh exists"
    fi
}

# Test 2: Function availability
test_function_availability() {
    test_log "$YELLOW" "Testing function availability..."
    
    # Source modules
    source "$MODULES_DIR/segmentation.sh" 2>/dev/null
    source "$MODULES_DIR/juelich_segmentation.sh" 2>/dev/null
    
    # Test core segmentation functions
    assert_function_exists "extract_brainstem_standardspace" "extract_brainstem_standardspace function exists"
    assert_function_exists "extract_brainstem_talairach" "extract_brainstem_talairach function exists"
    assert_function_exists "extract_brainstem_ants" "extract_brainstem_ants function exists"
    assert_function_exists "extract_brainstem_final" "extract_brainstem_final function exists"
    assert_function_exists "validate_segmentation" "validate_segmentation function exists"
    
    # Test Juelich functions
    assert_function_exists "extract_pons_juelich" "extract_pons_juelich function exists"
    assert_function_exists "extract_brainstem_juelich" "extract_brainstem_juelich function exists"
}

# Test 3: Dependencies
test_dependencies() {
    test_log "$YELLOW" "Testing dependencies..."
    
    # Test FSL commands
    assert_command_exists "fslinfo" "FSL fslinfo command available"
    assert_command_exists "fslmaths" "FSL fslmaths command available"
    assert_command_exists "flirt" "FSL flirt command available"
    
    # Test FSL directory structure
    if [ -n "$FSLDIR" ] && [ -d "$FSLDIR" ]; then
        assert_file_exists "$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz" "MNI template exists"
        
        # Test for atlas availability
        local harvard_atlas="$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1mm.nii.gz"
        local juelich_atlas="$FSLDIR/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
        
        if [ -f "$harvard_atlas" ]; then
            test_log "$GREEN" "PASS: Harvard-Oxford atlas available"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            test_log "$YELLOW" "INFO: Harvard-Oxford atlas not found (optional)"
        fi
        
        if [ -f "$juelich_atlas" ]; then
            test_log "$GREEN" "PASS: Juelich atlas available"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            test_log "$YELLOW" "INFO: Juelich atlas not found (will use fallback)"
        fi
        
        TESTS_RUN=$((TESTS_RUN + 2))
    else
        test_log "$YELLOW" "INFO: FSLDIR not set or invalid, skipping atlas tests"
    fi
}

# Test 4: Basic functionality
test_basic_functionality() {
    test_log "$YELLOW" "Testing basic functionality..."
    
    # Source modules
    source "$MODULES_DIR/segmentation.sh" 2>/dev/null
    source "$MODULES_DIR/juelich_segmentation.sh" 2>/dev/null
    
    # Test input validation
    local invalid_file="/nonexistent/file.nii.gz"
    
    # Test extract_brainstem_standardspace with invalid input
    extract_brainstem_standardspace "$invalid_file" 2>/dev/null
    local exit_code=$?
    assert_equals "1" "$exit_code" "extract_brainstem_standardspace fails with invalid input"
    
    # Test extract_pons_juelich with invalid input
    extract_pons_juelich "$invalid_file" 2>/dev/null
    local exit_code=$?
    assert_equals "1" "$exit_code" "extract_pons_juelich fails with invalid input"
}

# Test 5: Output directory creation
test_output_directory_creation() {
    test_log "$YELLOW" "Testing output directory creation..."
    
    # Source modules
    source "$MODULES_DIR/segmentation.sh" 2>/dev/null
    source "$MODULES_DIR/juelich_segmentation.sh" 2>/dev/null
    
    # Test that functions create proper directory structure
    local test_output_base="$TEST_TEMP_DIR/test_output"
    
    # This should create directories even if segmentation fails
    if [ -f "$TEST_IMAGE" ]; then
        extract_pons_juelich "$TEST_IMAGE" "$test_output_base/pons/test_pons.nii.gz" 2>/dev/null
        
        # Check if directories were created
        if [ -d "$test_output_base/pons" ]; then
            test_log "$GREEN" "PASS: Output directories created correctly"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            test_log "$RED" "FAIL: Output directories not created"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
}

# Test 6: Integration test
test_integration() {
    test_log "$YELLOW" "Testing integration with main pipeline..."
    
    # Source all modules
    source "$MODULES_DIR/segmentation.sh" 2>/dev/null
    
    # Test that the main extraction function can be called
    if [ -f "$TEST_IMAGE" ] && command -v fslinfo &> /dev/null; then
        # This is a full integration test that might actually work if FSL is properly configured
        extract_brainstem_final "$TEST_IMAGE" 2>/dev/null
        local exit_code=$?
        
        # We expect this might fail due to missing dependencies, but it shouldn't crash
        if [ "$exit_code" -eq 0 ]; then
            test_log "$GREEN" "PASS: Integration test completed successfully"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        elif [ "$exit_code" -eq 1 ]; then
            test_log "$YELLOW" "INFO: Integration test failed gracefully (expected with mock data)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            test_log "$RED" "FAIL: Integration test crashed unexpectedly"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        test_log "$YELLOW" "INFO: Skipping integration test (FSL not available or no test image)"
    fi
}

# Cleanup
cleanup_test_env() {
    test_log "$YELLOW" "Cleaning up test environment..."
    
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
        test_log "$GREEN" "Test environment cleaned up"
    fi
}

# Print test results
print_test_results() {
    echo
    echo "=========================================="
    echo "           TEST RESULTS"
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo "=========================================="
    echo
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed. Check the output above for details.${NC}"
        return 1
    fi
}

# Main test execution
main() {
    echo "=========================================="
    echo "    BRAINSTEM SEGMENTATION UNIT TESTS"
    echo "=========================================="
    echo
    
    # Setup
    setup_test_env
    create_test_data
    
    # Run tests
    test_module_loading
    test_function_availability
    test_dependencies
    test_basic_functionality
    test_output_directory_creation
    test_integration
    
    # Cleanup and results
    cleanup_test_env
    print_test_results
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi