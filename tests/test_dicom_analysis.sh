#!/usr/bin/env bash
#
# test_dicom_analysis.sh - Comprehensive test suite for dicom_analysis.sh module
#
# This test suite validates the DICOM analysis module functionality including:
# - Environment dependency tests
# - Input validation tests
# - DICOM processing tests
# - Error handling tests
# - Integration tests
# - Edge case tests
#

# Test framework setup
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMP_TEST_DIR=""
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test result tracking
FAILED_TESTS=()

# Setup test environment
setup_test_environment() {
    echo -e "${BLUE}=== Setting up test environment ===${NC}"
    
    # Create temporary test directory
    TEMP_TEST_DIR=$(mktemp -d -t dicom_analysis_test_XXXXXX)
    export TEMP_TEST_DIR
    
    # Set up test paths
    export TEST_LOG_DIR="$TEMP_TEST_DIR/logs"
    export TEST_RESULTS_DIR="$TEMP_TEST_DIR/results"
    export TEST_DICOM_DIR="$TEMP_TEST_DIR/dicom"
    
    # Create test directories
    mkdir -p "$TEST_LOG_DIR"
    mkdir -p "$TEST_RESULTS_DIR"
    mkdir -p "$TEST_DICOM_DIR"
    
    # Override environment variables for testing
    export LOG_DIR="$TEST_LOG_DIR"
    export RESULTS_DIR="$TEST_RESULTS_DIR"
    export LOG_FILE="$TEST_LOG_DIR/test_dicom_analysis.log"
    
    echo "Test environment created at: $TEMP_TEST_DIR"
}

# Cleanup test environment
cleanup_test_environment() {
    echo -e "${BLUE}=== Cleaning up test environment ===${NC}"
    if [ -n "$TEMP_TEST_DIR" ] && [ -d "$TEMP_TEST_DIR" ]; then
        rm -rf "$TEMP_TEST_DIR"
        echo "Test environment cleaned up"
    fi
}

# Test assertion functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_not_equals() {
    local not_expected="$1"
    local actual="$2"
    local message="$3"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ "$not_expected" != "$actual" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  Should not equal: '$not_expected'"
        echo "  Actual:          '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="$2"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  File does not exist: '$file'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local message="$2"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ ! -f "$file" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  File should not exist: '$file'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_function_exists() {
    local func="$1"
    local message="$2"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if declare -f "$func" > /dev/null; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  Function does not exist: '$func'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_exit_code() {
    local expected_code="$1"
    local actual_code="$2"
    local message="$3"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $message"
        echo "  Expected exit code: $expected_code"
        echo "  Actual exit code:   $actual_code"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

# Mock DICOM file creation
create_mock_dicom_file() {
    local filename="$1"
    local manufacturer="${2:-SIEMENS}"
    local model="${3:-TestModel}"
    local software="${4:-TestSoftware}"
    
    # Create a simple text file that mimics dcmdump output
    cat > "$filename" << EOF
# Mock DICOM file for testing
# This simulates dcmdump output for testing purposes
(0008,0070) LO [${manufacturer}]    #  8, 1 Manufacturer
(0008,1090) LO [${model}]         #  9, 1 ManufacturerModelName
(0018,1020) LO [${software}]      # 12, 1 SoftwareVersions
(0020,000D) UI [1.2.3.4.5.6.7.8.9.10.11.12.13]  # 26, 1 StudyInstanceUID
(0020,000E) UI [1.2.3.4.5.6.7.8.9.10.11.12.14]  # 26, 1 SeriesInstanceUID
(0020,0010) SH [TEST001]          #   7, 1 StudyID
(0020,0011) IS [1]                #   1, 1 SeriesNumber
(0008,0060) CS [MR]               #   2, 1 Modality
(0008,103E) LO [Test Series]      #  11, 1 SeriesDescription
(0020,0013) IS [1]                #   1, 1 InstanceNumber
(0020,0012) IS [1]                #   1, 1 AcquisitionNumber
(0020,9056) SH [STACK1]           #   6, 1 StackID
(0020,0032) DS [1.0\\2.0\\3.0]      #  11, 3 ImagePositionPatient
EOF
}

create_mock_dcmdump_script() {
    local script_path="$1"
    
    cat > "$script_path" << 'EOF'
#!/usr/bin/env bash
# Mock dcmdump script for testing
if [ $# -eq 0 ]; then
    echo "dcmdump: no input files"
    exit 1
fi

file="$1"
if [ ! -f "$file" ]; then
    echo "dcmdump: cannot open file '$file'"
    exit 1
fi

# Just cat the file content (assumes it's already in dcmdump format)
cat "$file"
EOF
    chmod +x "$script_path"
}

# Load modules for testing
load_test_modules() {
    echo -e "${BLUE}=== Loading modules for testing ===${NC}"
    
    # Source environment module first (provides dependencies)
    if [ -f "$PROJECT_ROOT/src/modules/environment.sh" ]; then
        source "$PROJECT_ROOT/src/modules/environment.sh" 2>/dev/null || {
            echo -e "${YELLOW}Warning: Could not source environment.sh cleanly${NC}"
        }
        echo "Loaded environment.sh"
    else
        echo -e "${RED}Error: environment.sh not found${NC}"
        return 1
    fi
    
    # Source dicom_analysis module
    if [ -f "$PROJECT_ROOT/src/modules/dicom_analysis.sh" ]; then
        source "$PROJECT_ROOT/src/modules/dicom_analysis.sh" 2>/dev/null || {
            echo -e "${YELLOW}Warning: Could not source dicom_analysis.sh cleanly${NC}"
        }
        echo "Loaded dicom_analysis.sh"
    else
        echo -e "${RED}Error: dicom_analysis.sh not found${NC}"
        return 1
    fi
    
    return 0
}

# Test 1: Environment Dependency Tests
test_environment_dependencies() {
    echo -e "\n${BLUE}=== Test 1: Environment Dependencies ===${NC}"
    
    # Test required functions are available
    assert_function_exists "log_formatted" "log_formatted function available"
    assert_function_exists "log_message" "log_message function available"
    assert_function_exists "log_error" "log_error function available"
    
    # Test required variables are set
    local log_dir_set=false
    local results_dir_set=false
    
    [ -n "${LOG_DIR:-}" ] && log_dir_set=true
    [ -n "${RESULTS_DIR:-}" ] && results_dir_set=true
    
    assert_equals "true" "$log_dir_set" "LOG_DIR variable is set"
    assert_equals "true" "$results_dir_set" "RESULTS_DIR variable is set"
    
    # Test that directories can be created
    mkdir -p "$LOG_DIR" 2>/dev/null
    mkdir -p "$RESULTS_DIR" 2>/dev/null
    
    assert_file_exists "$LOG_DIR" "LOG_DIR directory exists"
    assert_file_exists "$RESULTS_DIR" "RESULTS_DIR directory exists"
}

# Test 2: Function Availability Tests
test_function_availability() {
    echo -e "\n${BLUE}=== Test 2: Function Availability ===${NC}"
    
    # Test all exported functions from dicom_analysis.sh
    assert_function_exists "analyze_dicom_header" "analyze_dicom_header function available"
    assert_function_exists "check_empty_dicom_fields" "check_empty_dicom_fields function available"
    assert_function_exists "detect_scanner_manufacturer" "detect_scanner_manufacturer function available"
    assert_function_exists "get_conversion_recommendations" "get_conversion_recommendations function available"
    assert_function_exists "extract_siemens_metadata" "extract_siemens_metadata function available"
    assert_function_exists "extract_scanner_metadata" "extract_scanner_metadata function available"
}

# Test 3: Input Validation Tests
test_input_validation() {
    echo -e "\n${BLUE}=== Test 3: Input Validation ===${NC}"
    
    # Test with non-existent file
    local non_existent_file="$TEMP_TEST_DIR/non_existent.dcm"
    analyze_dicom_header "$non_existent_file" 2>/dev/null
    local exit_code=$?
    assert_exit_code 1 "$exit_code" "analyze_dicom_header fails with non-existent file"
    
    # Test with file paths containing spaces
    local spaced_file="$TEMP_TEST_DIR/file with spaces.dcm"
    create_mock_dicom_file "$spaced_file"
    
    # Create mock dcmdump script
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    analyze_dicom_header "$spaced_file" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header handles file paths with spaces"
    
    # Test with file paths containing special characters
    local special_file="$TEMP_TEST_DIR/file-with_special.chars[1].dcm"
    create_mock_dicom_file "$special_file"
    
    analyze_dicom_header "$special_file" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header handles file paths with special characters"
    
    # Test with empty file
    local empty_file="$TEMP_TEST_DIR/empty.dcm"
    touch "$empty_file"
    
    analyze_dicom_header "$empty_file" 2>/dev/null
    exit_code=$?
    # Should handle empty file gracefully (may succeed or fail, but shouldn't crash)
    local crash_test=true
    [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ] && crash_test=true || crash_test=false
    assert_equals "true" "$crash_test" "analyze_dicom_header handles empty file without crashing"
}

# Test 4: DICOM Tool Detection Tests
test_dicom_tool_detection() {
    echo -e "\n${BLUE}=== Test 4: DICOM Tool Detection ===${NC}"
    
    # Test with mock dcmdump available
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    local test_file="$TEMP_TEST_DIR/test.dcm"
    create_mock_dicom_file "$test_file"
    
    analyze_dicom_header "$test_file" "$TEMP_TEST_DIR/output.txt" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header works with dcmdump available"
    
    # Test output file creation
    assert_file_exists "$TEMP_TEST_DIR/output.txt" "Output file created"
    
    # Test without any DICOM tools
    export PATH="/usr/bin:/bin"  # Minimal PATH to avoid finding real tools
    
    analyze_dicom_header "$test_file" "$TEMP_TEST_DIR/output2.txt" 2>/dev/null
    exit_code=$?
    assert_exit_code 1 "$exit_code" "analyze_dicom_header fails when no DICOM tools available"
}

# Test 5: Manufacturer Detection Tests
test_manufacturer_detection() {
    echo -e "\n${BLUE}=== Test 5: Manufacturer Detection ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test Siemens detection
    local siemens_file="$TEMP_TEST_DIR/siemens.dcm"
    create_mock_dicom_file "$siemens_file" "SIEMENS" "Avanto" "VB17A"
    
    local manufacturer=$(detect_scanner_manufacturer "$siemens_file" 2>/dev/null)
    assert_equals "SIEMENS" "$manufacturer" "Siemens manufacturer detection"
    
    # Test Philips detection 
    local philips_file="$TEMP_TEST_DIR/philips.dcm"
    create_mock_dicom_file "$philips_file" "Philips Medical Systems" "Achieva" "5.1.7"
    
    manufacturer=$(detect_scanner_manufacturer "$philips_file" 2>/dev/null)
    assert_equals "PHILIPS" "$manufacturer" "Philips manufacturer detection"
    
    # Test GE detection
    local ge_file="$TEMP_TEST_DIR/ge.dcm"
    create_mock_dicom_file "$ge_file" "GE MEDICAL SYSTEMS" "DISCOVERY MR750" "25"
    
    manufacturer=$(detect_scanner_manufacturer "$ge_file" 2>/dev/null)
    assert_equals "GE" "$manufacturer" "GE manufacturer detection"
    
    # Test unknown manufacturer
    local unknown_file="$TEMP_TEST_DIR/unknown.dcm"
    create_mock_dicom_file "$unknown_file" "Unknown Vendor" "Unknown Model" "1.0"
    
    manufacturer=$(detect_scanner_manufacturer "$unknown_file" 2>/dev/null)
    assert_equals "UNKNOWN" "$manufacturer" "Unknown manufacturer detection"
    
    # Test with non-existent file
    detect_scanner_manufacturer "/non/existent/file.dcm" 2>/dev/null
    local exit_code=$?
    assert_exit_code 1 "$exit_code" "detect_scanner_manufacturer fails with non-existent file"
}

# Test 6: Conversion Recommendations Tests
test_conversion_recommendations() {
    echo -e "\n${BLUE}=== Test 6: Conversion Recommendations ===${NC}"
    
    # Test Siemens recommendations
    local siemens_rec=$(get_conversion_recommendations "SIEMENS" 2>/dev/null)
    assert_equals "--exact_values 1" "$siemens_rec" "Siemens conversion recommendations"
    
    # Test Philips recommendations
    local philips_rec=$(get_conversion_recommendations "PHILIPS" 2>/dev/null)
    assert_equals "--exact_values 1 --philips" "$philips_rec" "Philips conversion recommendations"
    
    # Test GE recommendations
    local ge_rec=$(get_conversion_recommendations "GE" 2>/dev/null)
    assert_equals "--exact_values 1 --no-dupcheck" "$ge_rec" "GE conversion recommendations"
    
    # Test unknown manufacturer
    local unknown_rec=$(get_conversion_recommendations "UNKNOWN" 2>/dev/null)
    assert_equals "" "$unknown_rec" "Unknown manufacturer returns empty recommendations"
    
    # Test case insensitive
    local lower_siemens_rec=$(get_conversion_recommendations "siemens" 2>/dev/null)
    assert_equals "--exact_values 1" "$lower_siemens_rec" "Case insensitive manufacturer detection"
}

# Test 7: Empty Fields Check Tests
test_empty_fields_check() {
    echo -e "\n${BLUE}=== Test 7: Empty Fields Check ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test with complete DICOM file
    local complete_file="$TEMP_TEST_DIR/complete.dcm"
    create_mock_dicom_file "$complete_file"
    
    check_empty_dicom_fields "$complete_file" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "check_empty_dicom_fields succeeds with complete file"
    
    # Test with non-existent file
    check_empty_dicom_fields "/non/existent/file.dcm" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "check_empty_dicom_fields returns success for non-existent file (pipeline continuation)"
    
    # Test without DICOM tools
    export PATH="/usr/bin:/bin"
    
    check_empty_dicom_fields "$complete_file" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "check_empty_dicom_fields returns success when no tools available (pipeline continuation)"
}

# Test 8: Metadata Extraction Tests
test_metadata_extraction() {
    echo -e "\n${BLUE}=== Test 8: Metadata Extraction ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test Siemens metadata extraction
    local siemens_file="$TEMP_TEST_DIR/siemens.dcm"
    create_mock_dicom_file "$siemens_file" "SIEMENS" "Skyra" "VE11C"
    
    local metadata_file="$TEMP_TEST_DIR/siemens_metadata.json"
    extract_siemens_metadata "$siemens_file" "$metadata_file" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "extract_siemens_metadata succeeds"
    assert_file_exists "$metadata_file" "Siemens metadata file created"
    
    # Check metadata content
    if [ -f "$metadata_file" ]; then
        local has_manufacturer=$(grep -q '"manufacturer"' "$metadata_file" && echo "true" || echo "false")
        local has_model=$(grep -q '"modelName"' "$metadata_file" && echo "true" || echo "false")
        assert_equals "true" "$has_manufacturer" "Metadata contains manufacturer"
        assert_equals "true" "$has_model" "Metadata contains model name"
    fi
    
    # Test with missing required fields (manufacturer)
    local incomplete_file="$TEMP_TEST_DIR/incomplete.dcm"
    cat > "$incomplete_file" << EOF
# Incomplete DICOM - missing manufacturer
(0008,1090) LO [TestModel]
(0018,1020) LO [TestSoftware]
EOF
    
    local incomplete_metadata_file="$TEMP_TEST_DIR/incomplete_metadata.json"
    extract_siemens_metadata "$incomplete_file" "$incomplete_metadata_file" 2>/dev/null
    exit_code=$?
    assert_exit_code 1 "$exit_code" "extract_siemens_metadata fails with missing required fields"
    
    # Test with non-existent file
    extract_siemens_metadata "/non/existent/file.dcm" "$TEMP_TEST_DIR/nonexistent_metadata.json" 2>/dev/null
    exit_code=$?
    assert_exit_code 1 "$exit_code" "extract_siemens_metadata fails with non-existent file"
}

# Test 9: Scanner Metadata Extraction Tests
test_scanner_metadata_extraction() {
    echo -e "\n${BLUE}=== Test 9: Scanner Metadata Extraction ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test Siemens scanner metadata
    local siemens_file="$TEMP_TEST_DIR/siemens.dcm"
    create_mock_dicom_file "$siemens_file" "SIEMENS" "Skyra" "VE11C"
    
    extract_scanner_metadata "$siemens_file" "$TEMP_TEST_DIR/metadata" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "extract_scanner_metadata succeeds for Siemens"
    assert_file_exists "$TEMP_TEST_DIR/metadata/scanner_params.json" "Scanner metadata file created"
    
    # Test Philips scanner metadata
    local philips_file="$TEMP_TEST_DIR/philips.dcm"
    create_mock_dicom_file "$philips_file" "Philips Medical Systems" "Achieva" "5.1.7"
    
    extract_scanner_metadata "$philips_file" "$TEMP_TEST_DIR/metadata_philips" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "extract_scanner_metadata succeeds for Philips"
    
    # Test GE scanner metadata
    local ge_file="$TEMP_TEST_DIR/ge.dcm"
    create_mock_dicom_file "$ge_file" "GE MEDICAL SYSTEMS" "DISCOVERY" "25"
    
    extract_scanner_metadata "$ge_file" "$TEMP_TEST_DIR/metadata_ge" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "extract_scanner_metadata succeeds for GE"
    
    # Test unsupported manufacturer
    local unsupported_file="$TEMP_TEST_DIR/unsupported.dcm"
    create_mock_dicom_file "$unsupported_file" "UNSUPPORTED_VENDOR" "Unknown" "1.0"
    
    extract_scanner_metadata "$unsupported_file" "$TEMP_TEST_DIR/metadata_unsupported" 2>/dev/null
    exit_code=$?
    assert_exit_code 1 "$exit_code" "extract_scanner_metadata fails for unsupported manufacturer"
    
    # Test with non-existent file
    extract_scanner_metadata "/non/existent/file.dcm" "$TEMP_TEST_DIR/metadata_nonexistent" 2>/dev/null
    exit_code=$?
    assert_exit_code 1 "$exit_code" "extract_scanner_metadata fails with non-existent file"
}

# Test 10: Error Handling Pattern Tests
test_error_handling_patterns() {
    echo -e "\n${BLUE}=== Test 10: Error Handling Patterns ===${NC}"
    
    # Test that functions return proper exit codes on failure
    # Instead of returning 0 (success) on errors
    
    # Test analyze_dicom_header with invalid input
    analyze_dicom_header "/definitely/does/not/exist.dcm" 2>/dev/null
    local exit_code=$?
    assert_not_equals 0 "$exit_code" "analyze_dicom_header returns non-zero for invalid input"
    
    # Test detect_scanner_manufacturer with invalid input
    detect_scanner_manufacturer "/definitely/does/not/exist.dcm" 2>/dev/null
    local manufacturer_exit=$?
    assert_not_equals 0 "$manufacturer_exit" "detect_scanner_manufacturer returns non-zero for invalid input"
    
    # Test extract_siemens_metadata with invalid input
    extract_siemens_metadata "/definitely/does/not/exist.dcm" "/tmp/output.json" 2>/dev/null
    exit_code=$?
    assert_not_equals 0 "$exit_code" "extract_siemens_metadata returns non-zero for invalid input"
    
    # Test extract_scanner_metadata with invalid input
    extract_scanner_metadata "/definitely/does/not/exist.dcm" "/tmp/output" 2>/dev/null
    exit_code=$?
    assert_not_equals 0 "$exit_code" "extract_scanner_metadata returns non-zero for invalid input"
    
    # Note: check_empty_dicom_fields is designed to return 0 for pipeline continuation
    # This is actually correct behavior according to the code comments
}

# Test 11: Integration Tests
test_integration() {
    echo -e "\n${BLUE}=== Test 11: Integration Tests ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test full workflow: analyze -> detect -> extract
    local test_file="$TEMP_TEST_DIR/integration_test.dcm"
    create_mock_dicom_file "$test_file" "SIEMENS" "Skyra" "VE11C"
    
    # Step 1: Analyze DICOM header
    local analysis_output="$TEMP_TEST_DIR/analysis_output.txt"
    analyze_dicom_header "$test_file" "$analysis_output" 2>/dev/null
    local step1_exit=$?
    assert_exit_code 0 "$step1_exit" "Integration test step 1: analyze_dicom_header"
    
    # Step 2: Detect manufacturer
    local manufacturer=$(detect_scanner_manufacturer "$test_file" 2>/dev/null)
    local step2_exit=$?
    assert_exit_code 0 "$step2_exit" "Integration test step 2: detect_scanner_manufacturer"
    assert_equals "SIEMENS" "$manufacturer" "Integration test step 2: correct manufacturer detected"
    
    # Step 3: Extract metadata
    local metadata_dir="$TEMP_TEST_DIR/integration_metadata"
    extract_scanner_metadata "$test_file" "$metadata_dir" 2>/dev/null
    local step3_exit=$?
    assert_exit_code 0 "$step3_exit" "Integration test step 3: extract_scanner_metadata"
    
    # Verify all outputs exist
    assert_file_exists "$analysis_output" "Integration test: analysis output exists"
    assert_file_exists "$metadata_dir/scanner_params.json" "Integration test: metadata output exists"
    
    # Test check empty fields is called during analysis
    check_empty_dicom_fields "$test_file" 2>/dev/null
    local step4_exit=$?
    assert_exit_code 0 "$step4_exit" "Integration test step 4: check_empty_dicom_fields"
}

# Test 12: Edge Cases and Performance Tests
test_edge_cases() {
    echo -e "\n${BLUE}=== Test 12: Edge Cases and Performance ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test with very long file paths
    local long_path="$TEMP_TEST_DIR/very/long/path/with/many/subdirectories/that/might/cause/issues"
    mkdir -p "$long_path"
    local long_file="$long_path/test_file_with_very_long_name_that_might_cause_buffer_overflow_issues.dcm"
    create_mock_dicom_file "$long_file"
    
    analyze_dicom_header "$long_file" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header handles very long file paths"
    
    # Test with Unicode characters in file names
    local unicode_file="$TEMP_TEST_DIR/tëst_ñámé_with_ünícödé.dcm"
    create_mock_dicom_file "$unicode_file"
    
    analyze_dicom_header "$unicode_file" 2>/dev/null
    exit_code=$?
    # This might fail on some systems, so we test that it doesn't crash
    local crash_test=true
    [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ] && crash_test=true || crash_test=false
    assert_equals "true" "$crash_test" "analyze_dicom_header handles Unicode file names without crashing"
    
    # Test with multiple simultaneous calls (concurrent safety)
    local concurrent_test=true
    for i in {1..5}; do
        local test_file="$TEMP_TEST_DIR/concurrent_test_$i.dcm"
        create_mock_dicom_file "$test_file" "SIEMENS" "Model$i" "V$i.0"
        
        # Run in background to test concurrency
        (analyze_dicom_header "$test_file" "$TEMP_TEST_DIR/concurrent_output_$i.txt" 2>/dev/null) &
    done
    
    # Wait for all background processes
    wait
    
    # Check that all outputs were created
    for i in {1..5}; do
        if [ ! -f "$TEMP_TEST_DIR/concurrent_output_$i.txt" ]; then
            concurrent_test=false
            break
        fi
    done
    
    assert_equals "true" "$concurrent_test" "analyze_dicom_header handles concurrent execution"
    
    # Test with large mock DICOM file
    local large_file="$TEMP_TEST_DIR/large_test.dcm"
    create_mock_dicom_file "$large_file"
    
    # Add lots of additional content to simulate a large file
    for i in {1..1000}; do
        echo "(FFFF,FFFF) LO [Dummy Field $i]" >> "$large_file"
    done
    
    local start_time=$(date +%s)
    analyze_dicom_header "$large_file" 2>/dev/null
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Should complete within reasonable time (30 seconds)
    local performance_test=true
    [ $duration -lt 30 ] && performance_test=true || performance_test=false
    assert_equals "true" "$performance_test" "analyze_dicom_header completes large file processing within 30 seconds (took ${duration}s)"
}

# Test 13: Grep and Sed Pattern Robustness Tests
test_pattern_robustness() {
    echo -e "\n${BLUE}=== Test 13: Grep and Sed Pattern Robustness ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    # Test with special characters in manufacturer name
    local special_manufacturer_file="$TEMP_TEST_DIR/special_manufacturer.dcm"
    cat > "$special_manufacturer_file" << EOF
(0008,0070) LO [GE/Philips-Hybrid (Test) [Model]]    # Manufacturer with special chars
(0008,1090) LO [Test/Model-Name [V2]]                # Model with special chars
(0018,1020) LO [Software v1.0 (build-123)]          # Software with special chars
EOF
    
    local manufacturer=$(detect_scanner_manufacturer "$special_manufacturer_file" 2>/dev/null)
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "detect_scanner_manufacturer handles manufacturer with special characters"
    
    # Test with malformed DICOM tags
    local malformed_file="$TEMP_TEST_DIR/malformed.dcm"
    cat > "$malformed_file" << EOF
# Malformed DICOM file
(0008,0070 LO [SIEMENS]               # Missing closing parenthesis
0008,0070) LO [SIEMENS]               # Missing opening parenthesis
(0008,0070) [SIEMENS]                 # Missing VR
(0008,0070) LO SIEMENS                # Missing brackets
(0008,0070) LO []                     # Empty value
(0008,0070) LO [   ]                  # Whitespace only value
EOF
    
    manufacturer=$(detect_scanner_manufacturer "$malformed_file" 2>/dev/null)
    exit_code=$?
    # Should handle malformed data gracefully without crashing
    local malformed_test=true
    [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ] && malformed_test=true || malformed_test=false
    assert_equals "true" "$malformed_test" "detect_scanner_manufacturer handles malformed DICOM data gracefully"
    
    # Test field extraction with whitespace variations
    local whitespace_file="$TEMP_TEST_DIR/whitespace.dcm"
    cat > "$whitespace_file" << EOF
(0008,0070)   LO   [  SIEMENS  ]     # Extra whitespace
(0008,1090)LO[TestModel]             # No whitespace
(0018,1020) LO	[TestSoft]           # Tab characters
EOF
    
    manufacturer=$(detect_scanner_manufacturer "$whitespace_file" 2>/dev/null)
    assert_equals "SIEMENS" "$manufacturer" "detect_scanner_manufacturer handles whitespace variations"
}

# Test 14: Directory Creation and Permissions Tests
test_directory_operations() {
    echo -e "\n${BLUE}=== Test 14: Directory Operations ===${NC}"
    
    # Setup mock dcmdump
    local mock_dcmdump="$TEMP_TEST_DIR/dcmdump"
    create_mock_dcmdump_script "$mock_dcmdump"
    export PATH="$TEMP_TEST_DIR:$PATH"
    
    local test_file="$TEMP_TEST_DIR/test.dcm"
    create_mock_dicom_file "$test_file"
    
    # Test output to deeply nested directory
    local deep_output="$TEMP_TEST_DIR/level1/level2/level3/level4/output.txt"
    analyze_dicom_header "$test_file" "$deep_output" 2>/dev/null
    local exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header creates deep directory structure"
    assert_file_exists "$deep_output" "Deep directory output file created"
    
    # Test with existing directory
    local existing_dir="$TEMP_TEST_DIR/existing"
    mkdir -p "$existing_dir"
    local existing_output="$existing_dir/output.txt"
    
    analyze_dicom_header "$test_file" "$existing_output" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "analyze_dicom_header works with existing directory"
    assert_file_exists "$existing_output" "Existing directory output file created"
    
    # Test metadata extraction directory creation
    local metadata_output_dir="$TEMP_TEST_DIR/metadata_test/deep/path"
    extract_scanner_metadata "$test_file" "$metadata_output_dir" 2>/dev/null
    exit_code=$?
    assert_exit_code 0 "$exit_code" "extract_scanner_metadata creates deep directory structure"
    assert_file_exists "$metadata_output_dir/scanner_params.json" "Metadata deep directory file created"
}

# Test 15: Tool Compatibility Tests
test_tool_compatibility() {
    echo -e "\n${BLUE}=== Test 15: Tool Compatibility ===${NC}"
    
    local test_file="$TEMP_TEST_DIR/test.dcm"
    create_mock_dicom_file "$test_file"
    
    # Test with different mock tools
    local tools=("dcmdump" "gdcmdump" "dcminfo" "dicom_hdr")
    
    for tool in "${tools[@]}"; do
        # Clean PATH and add only our mock tool
        export PATH="$TEMP_TEST_DIR:$PATH"
        
        # Create mock tool script
        local mock_tool="$TEMP_TEST_DIR/$tool"
        create_mock_dcmdump_script "$mock_tool"
        
        # Rename to match the tool we're testing
        mv "$mock_tool" "$TEMP_TEST_DIR/$tool"
        chmod +x "$TEMP_TEST_DIR/$tool"
        
        # Test analyze_dicom_header with this tool
        analyze_dicom_header "$test_file" "$TEMP_TEST_DIR/output_$tool.txt" 2>/dev/null
        local exit_code=$?
        assert_exit_code 0 "$exit_code" "analyze_dicom_header works with $tool"
        
        # Test manufacturer detection
        local manufacturer=$(detect_scanner_manufacturer "$test_file" 2>/dev/null)
        local manufacturer_exit=$?
        assert_exit_code 0 "$manufacturer_exit" "detect_scanner_manufacturer works with $tool"
        
        # Clean up for next iteration
        rm -f "$TEMP_TEST_DIR/$tool"
    done
}

# Main test runner
run_all_tests() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  DICOM Analysis Module Test Suite   ${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    # Setup test environment
    setup_test_environment
    
    # Load modules
    if ! load_test_modules; then
        echo -e "${RED}Failed to load required modules. Exiting.${NC}"
        cleanup_test_environment
        exit 1
    fi
    
    # Run all tests
    test_environment_dependencies
    test_function_availability
    test_input_validation
    test_dicom_tool_detection
    test_manufacturer_detection
    test_conversion_recommendations
    test_empty_fields_check
    test_metadata_extraction
    test_scanner_metadata_extraction
    test_error_handling_patterns
    test_integration
    test_edge_cases
    test_pattern_robustness
    test_directory_operations
    test_tool_compatibility
    
    # Display results
    echo -e "\n${BLUE}======================================${NC}"
    echo -e "${BLUE}           Test Results Summary        ${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    echo -e "Total tests run: ${BLUE}$TEST_COUNT${NC}"
    echo -e "Tests passed:    ${GREEN}$PASS_COUNT${NC}"
    echo -e "Tests failed:    ${RED}$FAIL_COUNT${NC}"
    
    if [ $FAIL_COUNT -gt 0 ]; then
        echo -e "\n${RED}Failed tests:${NC}"
        for failed_test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $failed_test"
        done
        echo ""
    fi
    
    # Calculate success rate
    local success_rate=0
    if [ $TEST_COUNT -gt 0 ]; then
        success_rate=$((PASS_COUNT * 100 / TEST_COUNT))
    fi
    
    echo -e "Success rate:    ${success_rate}%"
    
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "\n${GREEN}🎉 All tests passed!${NC}"
        echo -e "${GREEN}The DICOM analysis module test suite completed successfully.${NC}"
    else
        echo -e "\n${YELLOW}⚠️  Some tests failed.${NC}"
        echo -e "${YELLOW}Please review the failed tests and fix the underlying issues.${NC}"
    fi
    
    echo -e "\n${BLUE}Test environment details:${NC}"
    echo -e "  Temporary directory: $TEMP_TEST_DIR"
    echo -e "  Test log file: $LOG_FILE"
    
    # Cleanup
    cleanup_test_environment
    
    # Exit with appropriate code
    [ $FAIL_COUNT -eq 0 ] && exit 0 || exit 1
}

# Trap to ensure cleanup on exit
trap cleanup_test_environment EXIT

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests "$@"
fi