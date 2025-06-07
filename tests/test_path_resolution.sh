#!/usr/bin/env bash
#
# test_path_resolution.sh - Simple test to verify DICOM path resolution
#

echo "=== DICOM Path Resolution Test ==="
echo "Current working directory: $(pwd)"
echo ""

# Test paths
DATASET_3DFLAIR_DIR="${DATASET_3DFLAIR_DIR:-../DICOM}"
DATASET_CLINICAL_MPR_DIR="${DATASET_CLINICAL_MPR_DIR:-../DICOM2}"

echo "Original relative paths:"
echo "  3D FLAIR: $DATASET_3DFLAIR_DIR"
echo "  Clinical MPR: $DATASET_CLINICAL_MPR_DIR"
echo ""

# Check if directories exist before conversion
echo "Directory existence check (relative paths):"
if [ -d "$DATASET_3DFLAIR_DIR" ]; then
    echo "  ✓ $DATASET_3DFLAIR_DIR exists"
    DATASET_3DFLAIR_DIR="$(cd "$DATASET_3DFLAIR_DIR" && pwd)"
    echo "  → Absolute path: $DATASET_3DFLAIR_DIR"
else
    echo "  ✗ $DATASET_3DFLAIR_DIR does not exist"
fi

if [ -d "$DATASET_CLINICAL_MPR_DIR" ]; then
    echo "  ✓ $DATASET_CLINICAL_MPR_DIR exists"
    DATASET_CLINICAL_MPR_DIR="$(cd "$DATASET_CLINICAL_MPR_DIR" && pwd)"
    echo "  → Absolute path: $DATASET_CLINICAL_MPR_DIR"
else
    echo "  ✗ $DATASET_CLINICAL_MPR_DIR does not exist"
fi

echo ""
echo "Final resolved paths:"
echo "  3D FLAIR: $DATASET_3DFLAIR_DIR"
echo "  Clinical MPR: $DATASET_CLINICAL_MPR_DIR"

echo ""
echo "Available directories in parent (..):"
ls -la .. | grep "^d" | awk '{print "  " $9}' || echo "  (cannot list parent directory)"

echo ""
echo "Test complete."