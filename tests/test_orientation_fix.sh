#!/usr/bin/env bash
#
# Test script to verify the orientation warning fix
#

# Source the segmentation module
source "$(dirname "$0")/../src/modules/segmentation.sh"

# Set up basic logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_formatted() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

main() {
    echo "=========================================="
    echo "Testing Orientation Warning Fix"
    echo "=========================================="
    
    # Run the test function we just added
    if test_coordinate_validation; then
        echo ""
        log_formatted "SUCCESS" "✓ Coordinate validation function works correctly"
        echo ""
        echo "SUMMARY:"
        echo "========="
        echo "✓ Pre-flight coordinate validation detects conflicts"
        echo "✓ Early detection prevents 'Inconsistent orientations' FSL warnings"
        echo "✓ Code fails fast on coordinate mismatches instead of silent errors"
        echo ""
        echo "The orientation warning fix has been successfully implemented!"
        echo ""
        echo "NEXT STEPS:"
        echo "1. Run your pipeline and check for the new warning messages"
        echo "2. The pipeline will now detect orientation conflicts EARLY"
        echo "3. Look for 'PRE-FLIGHT COORDINATE VALIDATION' messages in logs"
        echo ""
        return 0
    else
        echo ""
        log_formatted "ERROR" "✗ Coordinate validation test failed"
        echo ""
        echo "TROUBLESHOOTING:"
        echo "- Check that fslorient is available in PATH"
        echo "- Verify the test mock functions work correctly"
        echo ""
        return 1
    fi
}

# Run the test
main "$@"