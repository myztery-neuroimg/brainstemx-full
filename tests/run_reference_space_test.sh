#!/usr/bin/env bash
#
# run_reference_space_test.sh - Integration test for adaptive reference space selection
#
# This script demonstrates the reference space selection functionality using real DICOM data
# and validates that the decision logic works correctly with both high-resolution and clinical datasets.
#

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source environment first
if [ -f "${PROJECT_ROOT}/src/modules/environment.sh" ]; then
    source "${PROJECT_ROOT}/src/modules/environment.sh"
else
    echo "ERROR: Cannot find environment.sh at ${PROJECT_ROOT}/src/modules/environment.sh"
    exit 1
fi

# Source reference space selection module
if [ -f "${PROJECT_ROOT}/src/modules/reference_space_selection.sh" ]; then
    source "${PROJECT_ROOT}/src/modules/reference_space_selection.sh"
else
    echo "ERROR: Cannot find reference_space_selection.sh at ${PROJECT_ROOT}/src/modules/reference_space_selection.sh"
    exit 1
fi

# Verify the function is available
if ! command -v select_optimal_reference_space &> /dev/null; then
    echo "ERROR: select_optimal_reference_space function not available"
    echo "Available functions: $(declare -F | grep -E 'select|reference' | awk '{print $3}' | tr '\n' ' ')"
    exit 1
fi

log_message "Successfully loaded reference space selection module"

# Test configuration using RESULTS_DIR
TEST_BASE_DIR="${RESULTS_DIR}/tests/reference_space_selection"
TEST_SESSION_DIR="${TEST_BASE_DIR}/session_$(date +%Y%m%d_%H%M%S)"

# Dataset paths with descriptive names (relative to user's current working directory)
DATASET_3DFLAIR_DIR="${DATASET_3DFLAIR_DIR:-../DICOM}"           # High-resolution 3D FLAIR dataset
DATASET_CLINICAL_MPR_DIR="${DATASET_CLINICAL_MPR_DIR:-../DICOM2}"     # Clinical grade T1-MPR dataset

# Convert to absolute paths to avoid issues with relative path resolution
if [ -d "$DATASET_3DFLAIR_DIR" ]; then
    DATASET_3DFLAIR_DIR="$(cd "$DATASET_3DFLAIR_DIR" && pwd)"
fi

if [ -d "$DATASET_CLINICAL_MPR_DIR" ]; then
    DATASET_CLINICAL_MPR_DIR="$(cd "$DATASET_CLINICAL_MPR_DIR" && pwd)"
fi

# Create test directories
mkdir -p "${TEST_SESSION_DIR}/3dflair_dataset"
mkdir -p "${TEST_SESSION_DIR}/clinical_mpr_dataset"

log_formatted "INFO" "===== ADAPTIVE REFERENCE SPACE SELECTION TEST ====="
log_message "Test session directory: $TEST_SESSION_DIR"
log_message "3D FLAIR dataset: $DATASET_3DFLAIR_DIR (expected: FLAIR selection)"
log_message "Clinical MPR dataset: $DATASET_CLINICAL_MPR_DIR (expected: T1 selection)"

# Function to test reference space selection for a dataset
test_dataset() {
    local dataset_name="$1"
    local dicom_dir="$2"
    local expected_choice="$3"
    local test_dir="${TEST_SESSION_DIR}/${dataset_name}"
    
    log_formatted "INFO" "Testing dataset: $dataset_name"
    log_message "DICOM directory: $dicom_dir"
    log_message "Expected selection: $expected_choice"
    
    # Check if DICOM directory exists
    if [ ! -d "$dicom_dir" ]; then
        log_formatted "WARNING" "DICOM directory not found: $dicom_dir"
        return 1
    fi
    
    # Create extraction directory
    local extract_dir="${test_dir}/extracted"
    mkdir -p "$extract_dir"
    
    # Check DICOM files before conversion
    log_message "Analyzing DICOM directory contents..."
    local dcm_count=$(find "$dicom_dir" -name "*.dcm" 2>/dev/null | wc -l)
    local img_count=$(find "$dicom_dir" -name "Image*" 2>/dev/null | wc -l)
    local total_files=$(find "$dicom_dir" -type f 2>/dev/null | wc -l)
    
    log_message "  Files with .dcm extension: $dcm_count"
    log_message "  Files with Image* pattern: $img_count"
    log_message "  Total files in directory: $total_files"
    
    if [ $total_files -eq 0 ]; then
        log_formatted "ERROR" "No files found in DICOM directory: $dicom_dir"
        return 1
    fi
    
    # Show sample filenames for debugging
    log_message "Sample files (first 5):"
    find "$dicom_dir" -type f | head -5 | while read -r file; do
        log_message "    $(basename "$file")"
    done
    
    # Convert DICOM to NIfTI
    log_message "Converting DICOM files to NIfTI format..."
    if command -v dcm2niix &> /dev/null; then
        # Use verbose output and capture it
        dcm2niix -o "$extract_dir" -f "%d_%s_%p" -v y "$dicom_dir" > "${test_dir}/conversion.log" 2>&1
        local conversion_status=$?
        
        # Show conversion log sample for debugging
        log_message "Conversion log sample (last 10 lines):"
        tail -10 "${test_dir}/conversion.log" | while read -r line; do
            log_message "    $line"
        done
        
        # Check results
        local nifti_count=$(find "$extract_dir" -name "*.nii.gz" 2>/dev/null | wc -l)
        local json_count=$(find "$extract_dir" -name "*.json" 2>/dev/null | wc -l)
        
        log_message "Conversion results:"
        log_message "  NIfTI files created: $nifti_count"
        log_message "  JSON files created: $json_count"
        log_message "  Exit status: $conversion_status"
        
        if [ $conversion_status -eq 0 ] || [ $nifti_count -gt 0 ]; then
            log_formatted "SUCCESS" "Converted $nifti_count DICOM files to NIfTI"
            
            # List created files for debugging
            if [ $nifti_count -gt 0 ]; then
                log_message "Created NIfTI files:"
                find "$extract_dir" -name "*.nii.gz" | while read -r file; do
                    log_message "    $(basename "$file")"
                done
            fi
        else
            log_formatted "ERROR" "DICOM conversion failed (status: $conversion_status, files: $nifti_count)"
            log_message "Full conversion log at: ${test_dir}/conversion.log"
            return 1
        fi
    else
        log_formatted "ERROR" "dcm2niix not available"
        return 1
    fi
    
    # Run reference space selection
    log_message "Running reference space selection analysis..."
    local selection_result
    selection_result=$(select_optimal_reference_space "$dicom_dir" "$extract_dir" "adaptive")
    
    # Parse result
    local selected_modality=$(echo "$selection_result" | cut -d'|' -f1)
    local selected_file=$(echo "$selection_result" | cut -d'|' -f2)
    local rationale=$(echo "$selection_result" | cut -d'|' -f3)
    
    # Log results
    log_formatted "INFO" "Reference space selection completed"
    log_message "Selected modality: $selected_modality"
    log_message "Selected file: $(basename "$selected_file")"
    log_message "Rationale: $rationale"
    
    # Save results
    {
        echo "Reference Space Selection Results"
        echo "================================"
        echo "Dataset: $dataset_name"
        echo "DICOM Directory: $dicom_dir"
        echo "Test Date: $(date)"
        echo ""
        echo "SELECTION RESULTS:"
        echo "Selected Modality: $selected_modality"
        echo "Selected File: $(basename "$selected_file")"
        echo "Full Path: $selected_file"
        echo "Rationale: $rationale"
        echo ""
        echo "VALIDATION:"
        echo "Expected: $expected_choice"
        echo "Actual: $selected_modality"
        if [ "$selected_modality" = "$expected_choice" ]; then
            echo "Result: CORRECT"
            log_formatted "SUCCESS" "Selection matches expectation: $expected_choice"
        else
            echo "Result: INCORRECT"
            log_formatted "WARNING" "Selection does not match expectation (expected: $expected_choice, got: $selected_modality)"
        fi
    } > "${test_dir}/selection_results.txt"
    
    log_message "Results saved to: ${test_dir}/selection_results.txt"
    
    # Return success if selection matches expectation
    [ "$selected_modality" = "$expected_choice" ]
}

# Function to generate summary report
generate_summary_report() {
    local report_file="${TEST_SESSION_DIR}/test_summary.txt"
    
    {
        echo "ADAPTIVE REFERENCE SPACE SELECTION TEST SUMMARY"
        echo "=============================================="
        echo "Test Session: $(date)"
        echo "Session Directory: $TEST_SESSION_DIR"
        echo ""
        
        echo "DATASET TEST RESULTS:"
        echo "===================="
        
        # 3D FLAIR dataset results
        if [ -f "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt" ]; then
            echo "3D FLAIR Dataset (../DICOM):"
            grep "Result:" "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt" | sed 's/^/  /'
            grep "Selected Modality:" "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt" | sed 's/^/  /'
            grep "Rationale:" "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt" | sed 's/^/  /'
        else
            echo "3D FLAIR Dataset (../DICOM): NOT TESTED"
        fi
        
        echo ""
        
        # Clinical MPR dataset results
        if [ -f "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt" ]; then
            echo "Clinical MPR Dataset (../DICOM2):"
            grep "Result:" "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt" | sed 's/^/  /'
            grep "Selected Modality:" "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt" | sed 's/^/  /'
            grep "Rationale:" "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt" | sed 's/^/  /'
        else
            echo "Clinical MPR Dataset (../DICOM2): NOT TESTED"
        fi
        
        echo ""
        echo "VALIDATION SUMMARY:"
        echo "=================="
        
        local flair_dataset_correct=false
        local clinical_dataset_correct=false
        
        if [ -f "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt" ]; then
            if grep -q "Result: CORRECT" "${TEST_SESSION_DIR}/3dflair_dataset/selection_results.txt"; then
                flair_dataset_correct=true
                echo "✓ 3D FLAIR Dataset: Selection logic validated"
            else
                echo "✗ 3D FLAIR Dataset: Selection logic needs review"
            fi
        fi
        
        if [ -f "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt" ]; then
            if grep -q "Result: CORRECT" "${TEST_SESSION_DIR}/clinical_mpr_dataset/selection_results.txt"; then
                clinical_dataset_correct=true
                echo "✓ Clinical MPR Dataset: Selection logic validated"
            else
                echo "✗ Clinical MPR Dataset: Selection logic needs review"
            fi
        fi
        
        echo ""
        echo "OVERALL ASSESSMENT:"
        echo "=================="
        
        if [ "$flair_dataset_correct" = true ] && [ "$clinical_dataset_correct" = true ]; then
            echo "✅ PASSED: Adaptive reference space selection working correctly"
            echo "   Ready for integration into main pipeline"
        elif [ "$flair_dataset_correct" = true ] || [ "$clinical_dataset_correct" = true ]; then
            echo "⚠️  PARTIAL: Some validation tests passed, review needed"
            echo "   Check individual dataset results for details"
        else
            echo "❌ FAILED: Reference space selection logic needs adjustment"
            echo "   Review decision criteria and scoring algorithms"
        fi
        
        echo ""
        echo "NEXT STEPS:"
        echo "==========="
        echo "1. Review individual test results in subdirectories"
        echo "2. Validate decision rationales match clinical expectations"
        echo "3. If tests pass, integrate into main pipeline workflow"
        echo "4. Configure pipeline to use adaptive reference space selection"
        
    } > "$report_file"
    
    log_formatted "INFO" "Summary report generated: $report_file"
    
    # Display summary to console
    echo ""
    echo "=========================================="
    cat "$report_file"
    echo "=========================================="
}

# Main test execution
main() {
    local test_results=0
    
    # Debug: Show resolved paths
    log_message "Resolved dataset paths:"
    log_message "  3D FLAIR: '$DATASET_3DFLAIR_DIR'"
    log_message "  Clinical MPR: '$DATASET_CLINICAL_MPR_DIR'"
    
    # Test 3D FLAIR Dataset (high-resolution research data)
    if [ -n "$DATASET_3DFLAIR_DIR" ] && [ -d "$DATASET_3DFLAIR_DIR" ]; then
        if test_dataset "3dflair_dataset" "$DATASET_3DFLAIR_DIR" "FLAIR"; then
            log_formatted "SUCCESS" "3D FLAIR dataset test passed"
        else
            log_formatted "WARNING" "3D FLAIR dataset test did not meet expectations"
            test_results=1
        fi
    else
        log_formatted "WARNING" "3D FLAIR dataset not found or path empty: '$DATASET_3DFLAIR_DIR'"
        test_results=1
    fi
    
    echo ""
    
    # Test Clinical MPR Dataset (clinical grade data)
    if [ -n "$DATASET_CLINICAL_MPR_DIR" ] && [ -d "$DATASET_CLINICAL_MPR_DIR" ]; then
        if test_dataset "clinical_mpr_dataset" "$DATASET_CLINICAL_MPR_DIR" "T1"; then
            log_formatted "SUCCESS" "Clinical MPR dataset test passed"
        else
            log_formatted "WARNING" "Clinical MPR dataset test did not meet expectations"
            test_results=1
        fi
    else
        log_formatted "WARNING" "Clinical MPR dataset not found or path empty: '$DATASET_CLINICAL_MPR_DIR'"
        test_results=1
    fi
    
    echo ""
    
    # Generate summary report
    generate_summary_report
    
    # Exit with appropriate status
    exit $test_results
}

# Show help if requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0"
    echo ""
    echo "This script tests the adaptive reference space selection logic using real DICOM data."
    echo "It validates that:"
    echo "  - High-resolution datasets (../DICOM) select FLAIR when appropriate"
    echo "  - Clinical datasets (../DICOM2) fallback to T1 when FLAIR is insufficient"
    echo ""
    echo "Test results are saved to: ${TEST_BASE_DIR}"
    echo ""
    echo "Prerequisites:"
    echo "  - dcm2niix must be installed and available"
    echo "  - FSL tools must be available for image analysis"
    echo "  - ../DICOM and ../DICOM2 directories must contain test data"
    exit 0
fi

# Run main test
main "$@"