#!/usr/bin/env bash
#
# test_orientation_preservation.sh - Test script for orientation preservation features
#
# This script tests the three orientation preservation methods implemented in
# orientation_correction.sh and generates a comparative report.
#
# Usage: ./test_orientation_preservation.sh <t1_image> <other_modality_image> <output_dir>
#

# Get script directory for later use
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source the environment
source "${SCRIPT_DIR}/modules/environment.sh" 2>/dev/null || {
    echo "ERROR: Could not source environment.sh"
    exit 1
}

# Source necessary modules
source "${SCRIPT_DIR}/modules/utils.sh" 2>/dev/null || {
    echo "ERROR: Could not source utils.sh"
    exit 1
}

source "${SCRIPT_DIR}/modules/registration.sh" 2>/dev/null || {
    echo "ERROR: Could not source registration.sh"
    exit 1
}

source "${SCRIPT_DIR}/modules/orientation_correction.sh" 2>/dev/null || {
    echo "ERROR: Could not source orientation_correction.sh"
    exit 1
}

# Check if orientation module is available
if ! command -v run_orientation_test &>/dev/null; then
    echo "ERROR: Orientation correction module not loaded or not available"
    echo "Make sure orientation_correction.sh is in the modules directory"
    exit 1
fi

# Parse arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <t1_image> <other_modality_image> <output_dir>"
    echo ""
    echo "Arguments:"
    echo "  t1_image          : The T1 reference image"
    echo "  other_modality    : The other modality image to register (e.g., FLAIR, T2, etc.)"
    echo "  output_dir        : The output directory for test results"
    exit 1
fi

T1_IMAGE="$1"
OTHER_MODALITY="$2"
OUTPUT_DIR="$3"

# Verify input files exist
if [ ! -f "$T1_IMAGE" ]; then
    echo "ERROR: T1 image not found: $T1_IMAGE"
    exit 1
fi

if [ ! -f "$OTHER_MODALITY" ]; then
    echo "ERROR: Other modality image not found: $OTHER_MODALITY"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Force enable orientation preservation for the test
export ORIENTATION_PRESERVATION_ENABLED=true

echo "===== Orientation Preservation Test ====="
echo "T1 Image: $T1_IMAGE"
echo "Other Modality: $OTHER_MODALITY"
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Run the test suite
echo "Running orientation test suite..."
BEST_METHOD=$(run_orientation_test "$T1_IMAGE" "$OTHER_MODALITY" "$OUTPUT_DIR")

echo ""
echo "Test completed successfully!"
echo "Best performing method: $BEST_METHOD"
echo "Detailed report saved to: ${OUTPUT_DIR}/orientation_test/orientation_test_report.txt"

# Create an HTML visualization if possible
if command -v fsleyes &>/dev/null; then
    echo ""
    echo "Creating visualization scripts..."
    
    # Create a script to view results in FSLeyes
    cat > "${OUTPUT_DIR}/view_results.sh" << EOL
#!/usr/bin/env bash
# Visualization script for orientation test results

fsleyes ${T1_IMAGE} \\
    ${OUTPUT_DIR}/orientation_test/standardWarped.nii.gz -cm red-yellow \\
    ${OUTPUT_DIR}/orientation_test/topologyWarped.nii.gz -cm blue-lightblue \\
    ${OUTPUT_DIR}/orientation_test/anatomicalWarped.nii.gz -cm green \\
    ${OUTPUT_DIR}/orientation_test/correctedWarped.nii.gz -cm copper
EOL
    chmod +x "${OUTPUT_DIR}/view_results.sh"
    
    echo "Visualization script created: ${OUTPUT_DIR}/view_results.sh"
    echo "Run this script to visualize and compare results"
fi

exit 0