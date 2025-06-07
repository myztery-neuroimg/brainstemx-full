#!/usr/bin/env bash
#
# Quick test to verify ORIGINAL detection is working with JSON files
#

# Source the reference space selection module
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/../src/modules/reference_space_selection.sh"

echo "=== Testing ORIGINAL Detection from JSON Files ==="
echo ""

# Create test function to check JSON detection
test_json_detection() {
    local json_file="$1"
    local expected_name="$2"
    
    echo "Testing: $expected_name"
    echo "JSON file: $(basename "$json_file")"
    
    if [ ! -f "$json_file" ]; then
        echo "❌ JSON file not found: $json_file"
        return 1
    fi
    
    # Create a dummy .nii file path for testing
    local nii_file="${json_file%.json}.nii"
    
    if is_original_acquisition "$nii_file"; then
        echo "✅ Correctly detected as ORIGINAL"
        echo "   ImageType content:"
        if command -v jq &> /dev/null; then
            jq -r '.ImageType' "$json_file" 2>/dev/null || echo "   (jq parsing failed)"
        else
            grep '"ImageType"' "$json_file" || echo "   (grep search failed)"
        fi
    else
        echo "❌ NOT detected as ORIGINAL"
    fi
    echo ""
}

# Test with known JSON files - using absolute paths to the files we examined
echo "Testing with known JSON files..."

# Direct test with the JSON files we examined earlier
T1_JSON="/Users/davidbrewster/Documents/workspace/2025/mri_results/tests/reference_space_selection/session_20250607_034049/3dflair_dataset/extracted/T1_MPRAGE_SAG_12_T1_MPRAGE_SAG.json"
FLAIR_JSON="/Users/davidbrewster/Documents/workspace/2025/mri_results/tests/reference_space_selection/session_20250607_034049/3dflair_dataset/extracted/T2_SPACE_FLAIR_SAG_CS_17_T2_SPACE_FLAIR_Sag_CS.json"

if [ -f "$T1_JSON" ]; then
    test_json_detection "$T1_JSON" "T1 MPRAGE"
else
    echo "❌ T1 JSON not found at expected location"
fi

if [ -f "$FLAIR_JSON" ]; then
    test_json_detection "$FLAIR_JSON" "T2 SPACE FLAIR"
else
    echo "❌ FLAIR JSON not found at expected location"
fi

# Also test any JSON files we can find in the current workspace
echo "Looking for any JSON files in workspace..."
WORKSPACE_JSONS=$(find .. -name "*.json" -type f | head -3)
if [ -n "$WORKSPACE_JSONS" ]; then
    echo "Found some JSON files to test with:"
    for json_file in $WORKSPACE_JSONS; do
        if grep -q '"ImageType"' "$json_file" 2>/dev/null; then
            test_json_detection "$json_file" "$(basename "$json_file" .json)"
        fi
    done
else
    echo "No JSON files found in workspace"
fi

echo "=== JSON Detection Logic Test Complete ==="