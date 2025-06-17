#!/usr/bin/env bash
#
# Test script for the new comprehensive segmentation QA function
#

# Source the required modules
source src/modules/environment.sh
source src/modules/utils.sh
source src/modules/qa.sh

# Set up test environment
export RESULTS_DIR="${RESULTS_DIR:-../mri_results}"

log_message "Testing comprehensive segmentation verification..."
log_message "Results directory: $RESULTS_DIR"

# Run the comprehensive QA function
if qa_verify_all_segmentations "$RESULTS_DIR"; then
    log_formatted "SUCCESS" "Segmentation verification completed successfully"
    exit_code=0
else
    log_formatted "ERROR" "Segmentation verification failed"
    exit_code=1
fi

echo ""
echo "=== USAGE INSTRUCTIONS ==="
echo "To run comprehensive segmentation verification in your pipeline:"
echo "  qa_verify_all_segmentations \"\$RESULTS_DIR\""
echo ""
echo "This function will:"
echo "  - Find all segmentation files automatically"
echo "  - Use correct directory paths: \${RESULTS_DIR}/segmentation/\${region}/"
echo "  - Create verification reports alongside segmentation files"
echo "  - Handle both standard and original space segmentations"

exit $exit_code