#!/usr/bin/env bash

# Test script to debug segmentation path issues

# Source environment
source "$(dirname "${BASH_SOURCE[0]}")/modules/environment.sh"

echo "Current working directory: $(pwd)"
echo "RESULTS_DIR: ${RESULTS_DIR}"

# Check if RESULTS_DIR is relative or absolute
if [[ "$RESULTS_DIR" != /* ]]; then
    echo "RESULTS_DIR is relative, converting to absolute..."
    RESULTS_DIR="$(pwd)/$RESULTS_DIR"
    echo "Absolute RESULTS_DIR: $RESULTS_DIR"
fi

# Check segmentation directories
brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
pons_dir="${RESULTS_DIR}/segmentation/pons"

echo ""
echo "Checking directories:"
echo "Brainstem dir: $brainstem_dir"
echo "Pons dir: $pons_dir"

# Create directories if they don't exist
echo ""
echo "Creating directories..."
mkdir -p "$brainstem_dir" "$pons_dir"

# Check if directories exist and are writable
echo ""
echo "Directory status:"
if [ -d "$brainstem_dir" ]; then
    echo "✓ Brainstem directory exists"
    if [ -w "$brainstem_dir" ]; then
        echo "✓ Brainstem directory is writable"
    else
        echo "✗ Brainstem directory is NOT writable"
    fi
else
    echo "✗ Brainstem directory does NOT exist"
fi

if [ -d "$pons_dir" ]; then
    echo "✓ Pons directory exists"
    if [ -w "$pons_dir" ]; then
        echo "✓ Pons directory is writable"
    else
        echo "✗ Pons directory is NOT writable"
    fi
else
    echo "✗ Pons directory does NOT exist"
fi

# Test creating a file
echo ""
echo "Testing file creation..."
test_file="${brainstem_dir}/test_file.txt"
if echo "test" > "$test_file"; then
    echo "✓ Successfully created test file: $test_file"
    rm "$test_file"
else
    echo "✗ Failed to create test file"
fi

# List contents of segmentation directory
echo ""
echo "Contents of segmentation directory:"
if [ -d "${RESULTS_DIR}/segmentation" ]; then
    ls -la "${RESULTS_DIR}/segmentation/"
else
    echo "Segmentation directory doesn't exist yet"
fi