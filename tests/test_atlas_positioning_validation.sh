#!/usr/bin/env bash
#
# test_atlas_positioning_validation.sh - Test actual atlas positioning accuracy
#
# This script tests the Harvard-Oxford atlas positioning by running the segmentation
# and validating that the resulting brainstem mask is anatomically plausible.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source the modules
source "$PROJECT_ROOT/src/modules/environment.sh"

# Define test data
TEST_T1_IMAGE="$PROJECT_ROOT/../mri_results/standardized/T1_MPRAGE_SAG_12_n4_brain_std.nii.gz"
TEST_T1_BASENAME=$(basename "$TEST_T1_IMAGE" .nii.gz)

# The segmentation script will place output in an absolute path version of RESULTS_DIR
ABSOLUTE_RESULTS_DIR=$(cd "$PROJECT_ROOT/../mri_results" && pwd)
BRAINSTEM_MASK_PATH="$ABSOLUTE_RESULTS_DIR/segmentation/brainstem/${TEST_T1_BASENAME}_brainstem.nii.gz"

# Cleanup function to be called on exit
cleanup() {
    echo "Cleaning up test files..."
    rm -f "$BRAINSTEM_MASK_PATH"
    # Clean up other potential segmentation outputs if necessary
    rm -rf "$ABSOLUTE_RESULTS_DIR/segmentation/brainstem/${TEST_T1_BASENAME}"
    rm -rf "$ABSOLUTE_RESULTS_DIR/registered/transforms/ants_to_mni_"*
}
trap cleanup EXIT

# Function to run segmentation
run_segmentation() {
    echo "=== Running Segmentation ==="
    
    # Call the main segmentation script
    # It uses RESULTS_DIR from the environment, no need for -o
    "$PROJECT_ROOT/src/modules/segmentation.sh" \
        -s "$TEST_T1_IMAGE" \
        -a "$HARVARD_OXFORD_SUBCORTICAL_ATLAS"
    
    echo "Segmentation finished."
}

# Function to validate brainstem anatomical position
validate_brainstem_position() {
    local brainstem_mask="$BRAINSTEM_MASK_PATH"
    local reference_image="$TEST_T1_IMAGE"
    
    echo "=== Validating Brainstem Anatomical Position ==="
    
    if [ ! -f "$brainstem_mask" ]; then
        echo "✗ FAIL: Brainstem mask not found: $brainstem_mask"
        return 1
    fi
    
    # Calculate center of mass
    local com=$(fslstats "$brainstem_mask" -C)
    local x=$(echo "$com" | awk '{print $1}')
    local y=$(echo "$com" | awk '{print $2}')
    local z=$(echo "$com" | awk '{print $3}')
    
    # Get image dimensions
    local dims=$(fslinfo "$reference_image" | grep -E "^dim[1-3]" | awk '{print $2}')
    local dimx=$(echo "$dims" | sed -n '1p')
    local dimy=$(echo "$dims" | sed -n '2p')
    local dimz=$(echo "$dims" | sed -n '3p')
    
    echo "Brainstem center of mass: ($x, $y, $z)"
    echo "Image dimensions: ${dimx}x${dimy}x${dimz}"
    
    # Calculate relative position (should be near center in X, posterior in Y, inferior in Z)
    local rel_x=$(echo "scale=3; $x / $dimx" | bc -l)
    local rel_y=$(echo "scale=3; $y / $dimy" | bc -l)
    local rel_z=$(echo "scale=3; $z / $dimz" | bc -l)
    
    echo "Relative position: (${rel_x}, ${rel_y}, ${rel_z})"
    
    # Anatomical validation checks
    local validation_passed=true
    
    # Check X position (should be near midline: 0.4 < x < 0.6)
    if (( $(echo "$rel_x < 0.4 || $rel_x > 0.6" | bc -l) )); then
        echo "✗ FAIL: X position is not near midline ($rel_x)"
        validation_passed=false
    else
        echo "✓ PASS: X position is near midline ($rel_x)"
    fi
    
    # Check Z position (should be inferior: z < 0.5)
    if (( $(echo "$rel_z > 0.5" | bc -l) )); then
        echo "✗ FAIL: Z position is too superior ($rel_z)"
        validation_passed=false
    else
        echo "✓ PASS: Z position is inferior ($rel_z)"
    fi
    
    # Check volume (should be reasonable: 1000-50000 voxels depending on resolution)
    local volume=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    echo "Brainstem volume: $volume voxels"
    
    if [ "$volume" -lt 1000 ] || [ "$volume" -gt 50000 ]; then
        echo "✗ FAIL: Volume is not in the expected range ($volume voxels)"
        validation_passed=false
    else
        echo "✓ PASS: Volume is within the expected range ($volume voxels)"
    fi
    
    if [ "$validation_passed" = true ]; then
        echo "✓✓✓ All validation checks passed!"
    else
        echo "✗✗✗ Some validation checks failed."
        return 1
    fi
}

# Main execution
run_segmentation
validate_brainstem_position

echo "Test completed successfully."