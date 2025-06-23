#!/usr/bin/env bash

# Script to clean up bad symlinks in segmentation directories

# Source environment
source "$(dirname "${BASH_SOURCE[0]}")/modules/environment.sh"

echo "Cleaning up segmentation directory symlinks..."
echo ""

# Ensure RESULTS_DIR is set
if [ -z "${RESULTS_DIR}" ]; then
    echo "ERROR: RESULTS_DIR is not set"
    exit 1
fi

# Convert to absolute path if relative
if [[ "$RESULTS_DIR" != /* ]]; then
    RESULTS_DIR="$(cd "$(dirname "$RESULTS_DIR")" && pwd)/$(basename "$RESULTS_DIR")"
fi

echo "RESULTS_DIR: $RESULTS_DIR"
echo ""

# Segmentation directories
brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
pons_dir="${RESULTS_DIR}/segmentation/pons"

# Function to clean directory
clean_directory() {
    local dir="$1"
    local dir_name="$2"
    
    if [ ! -d "$dir" ]; then
        echo "$dir_name directory doesn't exist: $dir"
        return
    fi
    
    echo "Cleaning $dir_name directory: $dir"
    
    # Find and remove broken symlinks
    local broken_count=0
    while IFS= read -r -d '' file; do
        if [ -L "$file" ] && [ ! -e "$file" ]; then
            echo "  Removing broken symlink: $(basename "$file")"
            rm -f "$file"
            broken_count=$((broken_count + 1))
        fi
    done < <(find "$dir" -type l -print0)
    
    echo "  Removed $broken_count broken symlinks"
    
    # List remaining files
    echo "  Remaining files:"
    ls -la "$dir" | grep -v "^total\|^d" | awk '{print "    " $0}'
    echo ""
}

# Clean brainstem directory
clean_directory "$brainstem_dir" "Brainstem"

# Clean pons directory
clean_directory "$pons_dir" "Pons"

echo "Cleanup complete!"
echo ""
echo "You can now run the segmentation again."