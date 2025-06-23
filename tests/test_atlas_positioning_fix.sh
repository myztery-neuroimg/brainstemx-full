#!/usr/bin/env bash
#
# test_atlas_positioning_fix.sh - Test script to validate the atlas mispositioning fix
#
# This script tests that the Harvard-Oxford atlas positioning fix works correctly
# by verifying that orientation correction logic has been properly removed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source the modules to test
source "$PROJECT_ROOT/src/modules/environment.sh"
source "$PROJECT_ROOT/src/modules/segmentation.sh"

# Test functions
test_orientation_correction_removed() {
    echo "=== Testing Orientation Correction Removal ==="
    
    # Grep for problematic fslswapdim patterns in segmentation.sh
    local problematic_patterns=0
    
    # Check for manual orientation correction patterns that should be removed
    if grep -q "fslswapdim.*-x.*orientation" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "ERROR: Manual orientation correction still found in segmentation.sh"
        problematic_patterns=$((problematic_patterns + 1))
    fi
    
    if grep -q "fslorient.*force.*orientation" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "ERROR: Manual fslorient correction still found in segmentation.sh"
        problematic_patterns=$((problematic_patterns + 1))
    fi
    
    # Check for the buggy "TRUEtrue" condition
    if grep -q "TRUEtrue" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "ERROR: Buggy TRUEtrue condition still present in segmentation.sh"
        problematic_patterns=$((problematic_patterns + 1))
    fi
    
    # Check segment_talairach.sh as well
    if grep -q "fslswapdim.*-x.*orientation" "$PROJECT_ROOT/src/modules/segment_talairach.sh"; then
        echo "ERROR: Manual orientation correction still found in segment_talairach.sh"
        problematic_patterns=$((problematic_patterns + 1))
    fi
    
    if [ $problematic_patterns -eq 0 ]; then
        echo "✓ PASS: Manual orientation correction patterns successfully removed"
        return 0
    else
        echo "✗ FAIL: $problematic_patterns problematic patterns still found"
        return 1
    fi
}

test_simplified_logic_present() {
    echo "=== Testing Simplified Logic Present ==="
    
    # Check that simplified logic messages are present
    if grep -q "SIMPLIFIED.*PROCESSING" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "✓ PASS: Simplified processing logic found in segmentation.sh"
    else
        echo "✗ FAIL: Simplified processing logic missing in segmentation.sh"
        return 1
    fi
    
    if grep -q "ANTs registration will handle.*orientation.*automatically" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "✓ PASS: ANTs-centric message found in segmentation.sh"
    else
        echo "✗ FAIL: ANTs-centric message missing in segmentation.sh"
        return 1
    fi
    
    return 0
}

test_ants_registration_calls_intact() {
    echo "=== Testing ANTs Registration Calls Intact ==="
    
    # Verify that the core registration calls are still present and haven't been accidentally removed
    if grep -q "perform_multistage_registration\|register_modality_to_t1\|antsRegistrationSyNQuick" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "✓ PASS: ANTs registration calls still present"
    else
        echo "✗ FAIL: ANTs registration calls missing - may have been accidentally removed"
        return 1
    fi
    
    if grep -q "apply_transformation" "$PROJECT_ROOT/src/modules/segmentation.sh"; then
        echo "✓ PASS: Transform application calls still present"
    else
        echo "✗ FAIL: Transform application calls missing"
        return 1
    fi
    
    return 0
}

# Run tests
main() {
    echo "Testing Harvard-Oxford Atlas Positioning Fix"
    echo "============================================="
    echo
    
    local tests_passed=0
    local tests_total=0
    
    # Test 1: Orientation correction removal
    tests_total=$((tests_total + 1))
    if test_orientation_correction_removed; then
        tests_passed=$((tests_passed + 1))
    fi
    echo
    
    # Test 2: Simplified logic present
    tests_total=$((tests_total + 1))
    if test_simplified_logic_present; then
        tests_passed=$((tests_passed + 1))
    fi
    echo
    
    # Test 3: ANTs calls intact
    tests_total=$((tests_total + 1))
    if test_ants_registration_calls_intact; then
        tests_passed=$((tests_passed + 1))
    fi
    echo
    
    # Summary
    echo "============================================="
    echo "Test Results: $tests_passed/$tests_total tests passed"
    
    if [ $tests_passed -eq $tests_total ]; then
        echo "✓ SUCCESS: All tests passed - Atlas positioning fix is correctly implemented"
        return 0
    else
        echo "✗ FAILURE: Some tests failed - Fix may be incomplete"
        return 1
    fi
}

# Run the tests
main "$@"