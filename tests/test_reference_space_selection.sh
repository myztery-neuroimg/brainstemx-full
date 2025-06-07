#!/usr/bin/env bash
#
# test_reference_space_selection.sh - Comprehensive test for adaptive reference space selection
#
# This is THE CRITICAL TEST for the foundational decision that affects the entire pipeline.
# Tests with real DICOM data from both ../DICOM (high-res research) and ../DICOM2 (clinical grade)
#

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../src/modules/environment.sh"
source "${SCRIPT_DIR}/../src/scan_selection.sh"

# Test configuration - use RESULTS_DIR from environment
TEST_OUTPUT_DIR="${RESULTS_DIR}/tests/reference_space_selection/test_$(date +%Y%m%d_%H%M%S)"

# Dataset paths with descriptive names (relative to user's current working directory)
DATASET_3DFLAIR_DIR="${DATASET_3DFLAIR_DIR:-../DICOM}"           # High-resolution 3D FLAIR dataset
DATASET_CLINICAL_MPR_DIR="${DATASET_CLINICAL_MPR_DIR:-../DICOM2}"     # Clinical grade T1-MPR dataset
EXPECTED_3DFLAIR="FLAIR"                 # High-resolution 3D FLAIR dataset should choose FLAIR
EXPECTED_CLINICAL_MPR="T1"               # Clinical grade dataset should fallback to T1

# Convert to absolute paths to avoid issues with relative path resolution
if [ -d "$DATASET_3DFLAIR_DIR" ]; then
    DATASET_3DFLAIR_DIR="$(cd "$DATASET_3DFLAIR_DIR" && pwd)"
fi

if [ -d "$DATASET_CLINICAL_MPR_DIR" ]; then
    DATASET_CLINICAL_MPR_DIR="$(cd "$DATASET_CLINICAL_MPR_DIR" && pwd)"
fi

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TEST_RESULTS=()

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions for tests
test_log() {
    echo -e "${BLUE}[TEST]${NC} $1" >&2
}

test_success() {
    echo -e "${GREEN}[PASS]${NC} $1" >&2
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_RESULTS+=("PASS: $1")
}

test_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_RESULTS+=("FAIL: $1")
}

test_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Assert functions
assert_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    
    if [ "$actual" = "$expected" ]; then
        test_success "$message (got: $actual)"
        return 0
    else
        test_fail "$message (expected: $expected, got: $actual)"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="$2"
    
    if [ -f "$file" ]; then
        test_success "$message"
        return 0
    else
        test_fail "$message (file not found: $file)"
        return 1
    fi
}

# Core test function for reference space selection
test_reference_space_selection() {
    local dataset_name="$1"
    local dicom_dir="$2"
    local expected_choice="$3"
    local test_dir="${TEST_OUTPUT_DIR}/${dataset_name}"
    
    test_log "========== Testing Reference Space Selection: $dataset_name =========="
    test_log "DICOM Directory: $dicom_dir"
    test_log "Expected Choice: $expected_choice"
    
    # Create test directory
    mkdir -p "$test_dir"
    
    # Check if DICOM directory exists
    if [ ! -d "$dicom_dir" ]; then
        test_fail "DICOM directory not found: $dicom_dir"
        return 1
    fi
    
    # Test 1: DICOM Discovery and Conversion
    test_log "Step 1: DICOM Discovery and Conversion"
    test_dicom_conversion "$dicom_dir" "$test_dir"
    
    # Test 2: Sequence Analysis and Quality Assessment
    test_log "Step 2: Sequence Analysis and Quality Assessment"
    test_sequence_analysis "$test_dir"
    
    # Test 3: Reference Space Decision
    test_log "Step 3: Reference Space Decision Logic"
    test_reference_space_decision "$test_dir" "$expected_choice"
    
    # Test 4: Decision Validation and Rationale
    test_log "Step 4: Decision Validation and Rationale"
    test_decision_validation "$test_dir" "$expected_choice"
    
    test_log "Completed testing for $dataset_name"
    echo ""
}

# Test DICOM conversion and file discovery
test_dicom_conversion() {
    local dicom_dir="$1"
    local test_dir="$2"
    local extract_dir="${test_dir}/extracted"
    
    mkdir -p "$extract_dir"
    
    # Count DICOM files
    local dicom_count=$(find "$dicom_dir" -name "*.dcm" -o -name "Image*" | wc -l)
    test_log "Found $dicom_count DICOM files in $dicom_dir"
    
    if [ "$dicom_count" -eq 0 ]; then
        test_warning "No DICOM files found - checking for alternative file patterns"
        dicom_count=$(find "$dicom_dir" -type f | head -10 | wc -l)
        test_log "Found $dicom_count files of any type"
    fi
    
    # Test dcm2niix availability
    if ! command -v dcm2niix &> /dev/null; then
        test_fail "dcm2niix not available for conversion testing"
        return 1
    fi
    
    # Perform conversion (limit to prevent long test times)
    test_log "Converting DICOM files to NIfTI..."
    dcm2niix -o "$extract_dir" -f "%d_%s_%p" "$dicom_dir" > "${test_dir}/conversion.log" 2>&1
    local conversion_status=$?
    
    # Check conversion results
    local nifti_count=$(find "$extract_dir" -name "*.nii.gz" | wc -l)
    test_log "Conversion produced $nifti_count NIfTI files"
    
    if [ "$nifti_count" -gt 0 ]; then
        test_success "DICOM conversion successful ($nifti_count files)"
        
        # List converted files for analysis
        find "$extract_dir" -name "*.nii.gz" > "${test_dir}/converted_files.txt"
        test_log "Converted files catalog saved to: ${test_dir}/converted_files.txt"
    else
        test_fail "DICOM conversion failed (no NIfTI files produced)"
        return 1
    fi
    
    return 0
}

# Test sequence analysis and quality assessment
test_sequence_analysis() {
    local test_dir="$1"
    local extract_dir="${test_dir}/extracted"
    
    # Find T1 and FLAIR sequences
    local t1_files=($(find "$extract_dir" -name "*T1*MPRAGE*.nii.gz" -o -name "*T1*MPR*.nii.gz" -o -name "*T1*.nii.gz"))
    local flair_files=($(find "$extract_dir" -name "*FLAIR*.nii.gz" -o -name "*T2*SPACE*.nii.gz"))
    
    test_log "Found ${#t1_files[@]} T1-type files"
    test_log "Found ${#flair_files[@]} FLAIR-type files"
    
    # Create sequence analysis report
    {
        echo "Sequence Analysis Report"
        echo "======================="
        echo "Generated: $(date)"
        echo ""
        echo "T1 Sequences Found: ${#t1_files[@]}"
        for file in "${t1_files[@]}"; do
            if [ -f "$file" ]; then
                echo "  - $(basename "$file")"
                # Get basic image info
                if command -v fslinfo &> /dev/null; then
                    local dims=$(fslinfo "$file" 2>/dev/null | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                    local pixdims=$(fslinfo "$file" 2>/dev/null | grep -E "^pixdim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                    echo "    Dimensions: $dims, Voxel size: $pixdims mm"
                fi
            fi
        done
        echo ""
        echo "FLAIR Sequences Found: ${#flair_files[@]}"
        for file in "${flair_files[@]}"; do
            if [ -f "$file" ]; then
                echo "  - $(basename "$file")"
                # Get basic image info
                if command -v fslinfo &> /dev/null; then
                    local dims=$(fslinfo "$file" 2>/dev/null | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                    local pixdims=$(fslinfo "$file" 2>/dev/null | grep -E "^pixdim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                    echo "    Dimensions: $dims, Voxel size: $pixdims mm"
                fi
            fi
        done
    } > "${test_dir}/sequence_analysis.txt"
    
    # Validate we have sequences to analyze
    if [ ${#t1_files[@]} -eq 0 ] && [ ${#flair_files[@]} -eq 0 ]; then
        test_fail "No T1 or FLAIR sequences found for analysis"
        return 1
    fi
    
    if [ ${#t1_files[@]} -gt 0 ]; then
        test_success "T1 sequences discovered and analyzed"
    fi
    
    if [ ${#flair_files[@]} -gt 0 ]; then
        test_success "FLAIR sequences discovered and analyzed"
    fi
    
    test_log "Sequence analysis report: ${test_dir}/sequence_analysis.txt"
    return 0
}

# Test the core reference space decision logic
test_reference_space_decision() {
    local test_dir="$1"
    local expected_choice="$2"
    local extract_dir="${test_dir}/extracted"
    
    # Find sequences for decision
    local t1_files=($(find "$extract_dir" -name "*T1*.nii.gz" | head -5))  # Limit for testing
    local flair_files=($(find "$extract_dir" -name "*FLAIR*.nii.gz" -o -name "*T2*SPACE*.nii.gz" | head -5))
    
    # Test the decision logic (placeholder for now - will implement the actual logic)
    local decision_result
    
    if [ ${#flair_files[@]} -gt 0 ] && [ ${#t1_files[@]} -gt 0 ]; then
        # We have both - need to decide based on quality
        decision_result=$(make_reference_space_decision "${t1_files[@]}" "${flair_files[@]}")
    elif [ ${#t1_files[@]} -gt 0 ]; then
        # Only T1 available
        decision_result="T1|${t1_files[0]}|Only T1 available"
    elif [ ${#flair_files[@]} -gt 0 ]; then
        # Only FLAIR available (unusual but possible)
        decision_result="FLAIR|${flair_files[0]}|Only FLAIR available"
    else
        test_fail "No suitable sequences found for reference space decision"
        return 1
    fi
    
    # Parse decision result
    local chosen_modality=$(echo "$decision_result" | cut -d'|' -f1)
    local chosen_file=$(echo "$decision_result" | cut -d'|' -f2)
    local rationale=$(echo "$decision_result" | cut -d'|' -f3)
    
    # Save decision information
    {
        echo "Reference Space Decision Result"
        echo "=============================="
        echo "Generated: $(date)"
        echo ""
        echo "Available T1 files: ${#t1_files[@]}"
        echo "Available FLAIR files: ${#flair_files[@]}"
        echo ""
        echo "DECISION: $chosen_modality"
        echo "SELECTED FILE: $(basename "$chosen_file")"
        echo "RATIONALE: $rationale"
        echo ""
        echo "EXPECTED: $expected_choice"
        echo "RESULT: $([ "$chosen_modality" = "$expected_choice" ] && echo "CORRECT" || echo "INCORRECT")"
    } > "${test_dir}/decision_result.txt"
    
    # Validate decision matches expectation
    assert_equals "$chosen_modality" "$expected_choice" "Reference space decision for $(basename "$test_dir")"
    
    test_log "Decision result saved to: ${test_dir}/decision_result.txt"
    return $?
}

# Placeholder decision function (will be replaced with actual implementation)
make_reference_space_decision() {
    local all_files=("$@")
    local t1_files=()
    local flair_files=()
    
    # Separate T1 and FLAIR files
    for file in "${all_files[@]}"; do
        if [[ "$(basename "$file")" == *"T1"* ]]; then
            t1_files+=("$file")
        else
            flair_files+=("$file")
        fi
    done
    
    # Simple decision logic for testing (will be enhanced)
    if [ ${#flair_files[@]} -gt 0 ]; then
        # Check if FLAIR seems high resolution
        local flair_file="${flair_files[0]}"
        if command -v fslinfo &> /dev/null && [ -f "$flair_file" ]; then
            local pixdim1=$(fslinfo "$flair_file" 2>/dev/null | grep "pixdim1" | awk '{print $2}')
            local pixdim2=$(fslinfo "$flair_file" 2>/dev/null | grep "pixdim2" | awk '{print $2}')
            local pixdim3=$(fslinfo "$flair_file" 2>/dev/null | grep "pixdim3" | awk '{print $2}')
            
            # Calculate average resolution
            if [ -n "$pixdim1" ] && [ -n "$pixdim2" ] && [ -n "$pixdim3" ]; then
                local avg_res=$(echo "scale=2; ($pixdim1 + $pixdim2 + $pixdim3) / 3" | bc -l 2>/dev/null || echo "1.0")
                
                # If FLAIR resolution is < 0.9mm average, prefer it
                if (( $(echo "$avg_res < 0.9" | bc -l 2>/dev/null || echo "0") )); then
                    echo "FLAIR|$flair_file|High resolution FLAIR (${avg_res}mm average)"
                    return 0
                fi
            fi
        fi
    fi
    
    # Default to T1 if available
    if [ ${#t1_files[@]} -gt 0 ]; then
        echo "T1|${t1_files[0]}|T1 structural gold standard"
    else
        echo "FLAIR|${flair_files[0]}|FLAIR fallback"
    fi
}

# Test decision validation and rationale
test_decision_validation() {
    local test_dir="$1"
    local expected_choice="$2"
    
    # Check if decision file exists
    local decision_file="${test_dir}/decision_result.txt"
    assert_file_exists "$decision_file" "Decision result file created"
    
    if [ -f "$decision_file" ]; then
        # Extract decision from file
        local actual_decision=$(grep "^DECISION:" "$decision_file" | cut -d' ' -f2)
        local result_status=$(grep "^RESULT:" "$decision_file" | cut -d' ' -f2)
        
        if [ "$result_status" = "CORRECT" ]; then
            test_success "Decision validation passed for $expected_choice"
        else
            test_fail "Decision validation failed for $expected_choice (got: $actual_decision)"
        fi
        
        # Log rationale
        local rationale=$(grep "^RATIONALE:" "$decision_file" | cut -d' ' -f2-)
        test_log "Decision rationale: $rationale"
    fi
}

# Generate comprehensive test report
generate_test_report() {
    local report_file="${TEST_OUTPUT_DIR}/comprehensive_test_report.txt"
    
    {
        echo "COMPREHENSIVE REFERENCE SPACE SELECTION TEST REPORT"
        echo "=================================================="
        echo "Generated: $(date)"
        echo "Test Output Directory: $TEST_OUTPUT_DIR"
        echo ""
        echo "TEST SUMMARY"
        echo "============"
        echo "Tests Passed: $TESTS_PASSED"
        echo "Tests Failed: $TESTS_FAILED"
        echo "Total Tests: $((TESTS_PASSED + TESTS_FAILED))"
        echo "Success Rate: $(echo "scale=1; 100 * $TESTS_PASSED / ($TESTS_PASSED + $TESTS_FAILED)" | bc -l)%"
        echo ""
        echo "DATASET TESTING RESULTS"
        echo "======================"
        echo "Dataset 1 ($DATASET1_DIR): Expected $EXPECTED_DATASET1"
        echo "Dataset 2 ($DATASET2_DIR): Expected $EXPECTED_DATASET2"
        echo ""
        echo "DETAILED TEST RESULTS"
        echo "===================="
        for result in "${TEST_RESULTS[@]}"; do
            echo "  $result"
        done
        echo ""
        echo "NEXT STEPS"
        echo "=========="
        if [ $TESTS_FAILED -eq 0 ]; then
            echo "✅ All tests passed! The reference space selection logic is working correctly."
            echo "✅ Ready to implement the full adaptive reference space selection system."
        else
            echo "❌ Some tests failed. Review the decision logic and fix issues before deployment."
            echo "❌ Check individual test outputs in subdirectories for detailed failure analysis."
        fi
        echo ""
        echo "TEST ARTIFACTS"
        echo "=============="
        echo "Individual test results available in:"
        find "$TEST_OUTPUT_DIR" -name "*.txt" | sed 's/^/  /'
    } > "$report_file"
    
    test_log "Comprehensive test report generated: $report_file"
    
    # Display summary
    echo ""
    echo "=========================================="
    echo "REFERENCE SPACE SELECTION TEST SUMMARY"
    echo "=========================================="
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    echo "Success Rate: $(echo "scale=1; 100 * $TESTS_PASSED / ($TESTS_PASSED + $TESTS_FAILED)" | bc -l)%"
    echo ""
    echo "Full report: $report_file"
    echo "=========================================="
}

# Main test execution function
main() {
    local interactive=false
    local dataset1="$DATASET_3DFLAIR_DIR"
    local dataset2="$DATASET_CLINICAL_MPR_DIR"
    local expected1="$EXPECTED_3DFLAIR"
    local expected2="$EXPECTED_CLINICAL_MPR"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --interactive)
                interactive=true
                shift
                ;;
            --dataset-3dflair)
                dataset1="$2"
                shift 2
                ;;
            --dataset-clinical-mpr)
                dataset2="$2"
                shift 2
                ;;
            --expected-3dflair)
                expected1="$2"
                shift 2
                ;;
            --expected-clinical-mpr)
                expected2="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --interactive     Run in interactive mode"
                echo "  --dataset-3dflair DIR        3D FLAIR dataset directory (default: ../DICOM)"
                echo "  --dataset-clinical-mpr DIR   Clinical MPR dataset directory (default: ../DICOM2)"
                echo "  --expected-3dflair MOD       Expected choice for 3D FLAIR dataset (default: FLAIR)"
                echo "  --expected-clinical-mpr MOD  Expected choice for clinical dataset (default: T1)"
                echo "  -h, --help        Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
    
    # Create test output directory
    mkdir -p "$TEST_OUTPUT_DIR"
    
    test_log "Starting comprehensive reference space selection testing"
    test_log "Output directory: $TEST_OUTPUT_DIR"
    
    # Test 3D FLAIR Dataset (should choose FLAIR)
    if [ -d "$dataset1" ]; then
        test_reference_space_selection "3dflair_highres" "$dataset1" "$expected1"
    else
        test_warning "3D FLAIR dataset not found: $dataset1 (skipping)"
    fi
    
    # Test Clinical MPR Dataset (should choose T1)
    if [ -d "$dataset2" ]; then
        test_reference_space_selection "clinical_mpr" "$dataset2" "$expected2"
    else
        test_warning "Clinical MPR dataset not found: $dataset2 (skipping)"
    fi
    
    # Generate comprehensive report
    generate_test_report
    
    # Exit with appropriate code
    if [ $TESTS_FAILED -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Export functions for external use
export -f test_reference_space_selection
export -f make_reference_space_decision
export -f test_dicom_conversion
export -f test_sequence_analysis

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi