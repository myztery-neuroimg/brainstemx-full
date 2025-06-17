#!/usr/bin/env bash
#
# test_smart_standardization.sh - Test smart standardization functionality
#
# Tests both scenarios:
# 1. T1 > FLAIR resolution (T1 has higher resolution)
# 2. FLAIR > T1 resolution (FLAIR has higher resolution)
#
# Also tests orientation detection and early validation

# Set up test environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source required modules
source "$PROJECT_ROOT/src/modules/environment.sh"
source "$PROJECT_ROOT/src/modules/utils.sh"
source "$PROJECT_ROOT/src/modules/preprocess.sh"

# Test configuration
TEST_DIR="/tmp/test_smart_standardization_$$"
RESULTS_DIR="$TEST_DIR/results"
mkdir -p "$TEST_DIR" "$RESULTS_DIR"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

test_passed() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

test_failed() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    return 1
}

test_info() {
    echo -e "${BLUE}ℹ INFO${NC}: $1"
}

test_warning() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

# Function to create mock NIfTI files for testing
create_mock_nifti() {
    local output_file="$1"
    local dim1="$2"
    local dim2="$3"
    local dim3="$4"
    local pixdim1="$5"
    local pixdim2="$6"
    local pixdim3="$7"
    local description="$8"
    
    test_info "Creating mock NIfTI: $(basename "$output_file")"
    test_info "  Dimensions: ${dim1}×${dim2}×${dim3}"
    test_info "  Voxel size: ${pixdim1}×${pixdim2}×${pixdim3}mm"
    test_info "  Description: $description"
    
    # Create a mock volume using FSL
    fslmaths "$FSLDIR/data/standard/MNI152_T1_2mm_brain.nii.gz" \
        -roi 0 "$dim1" 0 "$dim2" 0 "$dim3" 0 1 \
        "$output_file"
    
    # Set the voxel dimensions
    fslchpixdim "$output_file" "$pixdim1" "$pixdim2" "$pixdim3"
    
    if [ ! -f "$output_file" ]; then
        test_failed "Failed to create mock file: $output_file"
        return 1
    fi
    
    # Verify the created file
    local actual_dim1=$(fslval "$output_file" dim1)
    local actual_dim2=$(fslval "$output_file" dim2)
    local actual_dim3=$(fslval "$output_file" dim3)
    local actual_pixdim1=$(fslval "$output_file" pixdim1)
    local actual_pixdim2=$(fslval "$output_file" pixdim2)
    local actual_pixdim3=$(fslval "$output_file" pixdim3)
    
    test_info "  Verified: ${actual_dim1}×${actual_dim2}×${actual_dim3} at ${actual_pixdim1}×${actual_pixdim2}×${actual_pixdim3}mm"
    return 0
}

# Function to check if orientation matrices are actually different
check_orientation_matrices() {
    local file1="$1"
    local file2="$2"
    
    test_info "Checking orientation matrices between $(basename "$file1") and $(basename "$file2")"
    
    # Get orientation codes
    local orient1=$(fslorient -getorient "$file1" 2>/dev/null || echo "UNKNOWN")
    local orient2=$(fslorient -getorient "$file2" 2>/dev/null || echo "UNKNOWN")
    
    test_info "  $(basename "$file1"): $orient1"
    test_info "  $(basename "$file2"): $orient2"
    
    if [ "$orient1" = "$orient2" ]; then
        test_passed "Orientation matrices are identical: $orient1"
        return 0
    else
        test_warning "Orientation matrices differ: $orient1 vs $orient2"
        return 1
    fi
}

# Function to extract sform/qform matrices for detailed comparison
check_detailed_orientation() {
    local file1="$1"
    local file2="$2"
    
    test_info "Detailed orientation comparison between $(basename "$file1") and $(basename "$file2")"
    
    # Get sform matrices
    local sform1=$(fslinfo "$file1" | grep -E "^sto_xyz:|^qto_xyz:" | head -4)
    local sform2=$(fslinfo "$file2" | grep -E "^sto_xyz:|^qto_xyz:" | head -4)
    
    if [ "$sform1" = "$sform2" ]; then
        test_passed "Detailed orientation matrices are identical"
        return 0
    else
        test_warning "Detailed orientation matrices differ"
        echo "File 1 matrices:"
        echo "$sform1" | sed 's/^/    /'
        echo "File 2 matrices:"
        echo "$sform2" | sed 's/^/    /'
        return 1
    fi
}

# Test 1: Scenario where T1 has higher resolution than FLAIR
test_t1_higher_resolution() {
    echo -e "\n${BLUE}=== Test 1: T1 Higher Resolution Scenario ===${NC}"
    
    local t1_highres="$TEST_DIR/T1_highres.nii.gz"
    local flair_lowres="$TEST_DIR/FLAIR_lowres.nii.gz"
    
    # Create T1 with high resolution (0.5mm in-plane)
    create_mock_nifti "$t1_highres" 400 400 160 0.5 0.5 1.0 "High-res T1 (0.5mm in-plane)"
    
    # Create FLAIR with standard resolution (1.0mm in-plane)
    create_mock_nifti "$flair_lowres" 200 200 149 1.0 1.0 1.0 "Standard-res FLAIR (1.0mm in-plane)"
    
    # Test orientation checking
    check_orientation_matrices "$t1_highres" "$flair_lowres"
    check_detailed_orientation "$t1_highres" "$flair_lowres"
    
    # Test optimal resolution detection
    local optimal_res=$(detect_optimal_resolution "$t1_highres" "$flair_lowres")
    local expected_res="0.5x0.5x1"
    
    if [[ "$optimal_res" == "$expected_res" ]]; then
        test_passed "Optimal resolution detection: $optimal_res (T1's resolution preserved)"
    else
        test_failed "Optimal resolution detection: expected $expected_res, got $optimal_res"
        return 1
    fi
    
    return 0
}

# Test 2: Scenario where FLAIR has higher resolution than T1
test_flair_higher_resolution() {
    echo -e "\n${BLUE}=== Test 2: FLAIR Higher Resolution Scenario ===${NC}"
    
    local t1_lowres="$TEST_DIR/T1_lowres.nii.gz"
    local flair_highres="$TEST_DIR/FLAIR_highres.nii.gz"
    
    # Create T1 with standard resolution (similar to your case)
    create_mock_nifti "$t1_lowres" 226 226 160 0.976562 0.976562 1.0 "Standard-res T1 (0.976mm in-plane)"
    
    # Create FLAIR with high resolution (similar to your case)
    create_mock_nifti "$flair_highres" 512 512 149 0.488281 0.488281 0.976562 "High-res FLAIR (0.488mm in-plane)"
    
    # Test orientation checking
    check_orientation_matrices "$t1_lowres" "$flair_highres"
    check_detailed_orientation "$t1_lowres" "$flair_highres"
    
    # Test optimal resolution detection
    local optimal_res=$(detect_optimal_resolution "$t1_lowres" "$flair_highres")
    local expected_res="0.488281x0.488281x0.976562"
    
    if [[ "$optimal_res" == "$expected_res" ]]; then
        test_passed "Optimal resolution detection: $optimal_res (FLAIR's resolution preserved)"
    else
        test_failed "Optimal resolution detection: expected $expected_res, got $optimal_res"
        return 1
    fi
    
    return 0
}

# Test 3: Smart standardization with T1 higher resolution
test_smart_standardization_t1_higher() {
    echo -e "\n${BLUE}=== Test 3: Smart Standardization (T1 Higher) ===${NC}"
    
    local t1_input="$TEST_DIR/T1_highres.nii.gz"
    local optimal_res="0.5x0.5x1"
    
    # Test standardization
    export RESULTS_DIR="$RESULTS_DIR"
    standardize_dimensions "$t1_input" "$optimal_res"
    
    local output_file="$RESULTS_DIR/standardized/T1_highres_std.nii.gz"
    
    if [ -f "$output_file" ]; then
        local out_pixdim1=$(fslval "$output_file" pixdim1)
        local out_pixdim2=$(fslval "$output_file" pixdim2)
        local out_pixdim3=$(fslval "$output_file" pixdim3)
        
        test_info "Output resolution: ${out_pixdim1}×${out_pixdim2}×${out_pixdim3}mm"
        
        # Check if resolution matches expected (within tolerance)
        if (( $(echo "$out_pixdim1 <= 0.51 && $out_pixdim1 >= 0.49" | bc -l) )); then
            test_passed "Smart standardization preserved high resolution: ${out_pixdim1}mm"
        else
            test_failed "Smart standardization failed: expected ~0.5mm, got ${out_pixdim1}mm"
            return 1
        fi
    else
        test_failed "Smart standardization output file not created: $output_file"
        return 1
    fi
    
    return 0
}

# Test 4: Smart standardization with FLAIR higher resolution
test_smart_standardization_flair_higher() {
    echo -e "\n${BLUE}=== Test 4: Smart Standardization (FLAIR Higher) ===${NC}"
    
    local flair_input="$TEST_DIR/FLAIR_highres.nii.gz"
    local optimal_res="0.488281x0.488281x0.976562"
    
    # Test standardization
    standardize_dimensions "$flair_input" "$optimal_res"
    
    local output_file="$RESULTS_DIR/standardized/FLAIR_highres_std.nii.gz"
    
    if [ -f "$output_file" ]; then
        local out_pixdim1=$(fslval "$output_file" pixdim1)
        local out_pixdim2=$(fslval "$output_file" pixdim2)
        local out_pixdim3=$(fslval "$output_file" pixdim3)
        
        test_info "Output resolution: ${out_pixdim1}×${out_pixdim2}×${out_pixdim3}mm"
        
        # Check if resolution matches expected (within tolerance)
        if (( $(echo "$out_pixdim1 <= 0.49 && $out_pixdim1 >= 0.48" | bc -l) )); then
            test_passed "Smart standardization preserved high resolution: ${out_pixdim1}mm"
        else
            test_failed "Smart standardization failed: expected ~0.488mm, got ${out_pixdim1}mm"
            return 1
        fi
    else
        test_failed "Smart standardization output file not created: $output_file"
        return 1
    fi
    
    return 0
}

# Test 5: Legacy vs Smart comparison
test_legacy_vs_smart_comparison() {
    echo -e "\n${BLUE}=== Test 5: Legacy vs Smart Standardization Comparison ===${NC}"
    
    local flair_input="$TEST_DIR/FLAIR_highres.nii.gz"
    
    # Test legacy standardization (no target resolution)
    test_info "Testing legacy standardization..."
    standardize_dimensions "$flair_input"
    
    local legacy_output="$RESULTS_DIR/standardized/FLAIR_highres_std.nii.gz"
    
    if [ -f "$legacy_output" ]; then
        local legacy_pixdim1=$(fslval "$legacy_output" pixdim1)
        test_info "Legacy output resolution: ${legacy_pixdim1}mm"
        
        # Legacy should downsample to 1mm
        if (( $(echo "$legacy_pixdim1 >= 0.99 && $legacy_pixdim1 <= 1.01" | bc -l) )); then
            test_passed "Legacy standardization correctly downsampled to 1mm"
        else
            test_warning "Legacy standardization unexpected result: ${legacy_pixdim1}mm"
        fi
    else
        test_failed "Legacy standardization output not created"
        return 1
    fi
    
    # Compare data loss
    local original_voxels=$(echo "512 * 512 * 149" | bc)
    local legacy_dim1=$(fslval "$legacy_output" dim1)
    local legacy_dim2=$(fslval "$legacy_output" dim2)
    local legacy_dim3=$(fslval "$legacy_output" dim3)
    local legacy_voxels=$(echo "$legacy_dim1 * $legacy_dim2 * $legacy_dim3" | bc)
    
    local data_loss_pct=$(echo "scale=1; (1 - $legacy_voxels / $original_voxels) * 100" | bc -l)
    
    test_warning "Legacy standardization data loss: ${data_loss_pct}% (${original_voxels} → ${legacy_voxels} voxels)"
    
    return 0
}

# Main test runner
run_all_tests() {
    echo -e "${BLUE}Starting Smart Standardization Tests${NC}"
    echo "Test directory: $TEST_DIR"
    echo "Results directory: $RESULTS_DIR"
    
    local test_count=0
    local passed_count=0
    
    # Run all tests
    local tests=(
        "test_t1_higher_resolution"
        "test_flair_higher_resolution"
        "test_smart_standardization_t1_higher"
        "test_smart_standardization_flair_higher"
        "test_legacy_vs_smart_comparison"
    )
    
    for test_func in "${tests[@]}"; do
        test_count=$((test_count + 1))
        echo
        if $test_func; then
            passed_count=$((passed_count + 1))
        fi
    done
    
    # Summary
    echo -e "\n${BLUE}=== Test Summary ===${NC}"
    echo "Total tests: $test_count"
    echo -e "Passed: ${GREEN}$passed_count${NC}"
    echo -e "Failed: ${RED}$((test_count - passed_count))${NC}"
    
    if [ $passed_count -eq $test_count ]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        cleanup_test_files
        return 0
    else
        echo -e "\n${RED}Some tests failed.${NC}"
        echo "Test files preserved at: $TEST_DIR"
        return 1
    fi
}

# Cleanup function
cleanup_test_files() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        test_info "Cleaning up test files: $TEST_DIR"
        rm -rf "$TEST_DIR"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup_test_files EXIT

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in fsl fslmaths fslval fslchpixdim fslorient fslinfo bc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        test_failed "Missing dependencies: ${missing_deps[*]}"
        echo "Please ensure FSL is properly installed and configured."
        return 1
    fi
    
    return 0
}

# Main execution
main() {
    if ! check_dependencies; then
        exit 1
    fi
    
    run_all_tests
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi