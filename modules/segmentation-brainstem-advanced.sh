#!/usr/bin/env bash

# Source common functions
source "environment.sh"

compare_segmentation_methods() {
    local input_file="$1"
    local output_dir="$2"
    
    # Ensure Python environment is activated
    if [ -z "$CONDA_DEFAULT_ENV" ]; then
        log_formatted "ERROR" "Python environment not activated"
        return 1
    }
    
    # Create output directories
    mkdir -p "${output_dir}/suit"
    mkdir -p "${output_dir}/harvard"
    mkdir -p "${output_dir}/comparison"
    
    # Run Python-based segmentation
    python3 - <<EOF
import sys
sys.path.append("${PIPELINE_DIR}/modules")
from segment_pons_suitlib import SUITSegmentation
import ants

# Initialize segmentation
segmenter = SUITSegmentation("${SUIT_DIR}")

# Load and process image
image = ants.image_read("${input_file}")
results = segmenter.segment_pons(image, method="both")

# Save results
for method in ['suit', 'harvard']:
    ants.image_write(results[method]['pons'], 
                    "${output_dir}/${method}/pons.nii.gz")
    ants.image_write(results[method]['dorsal'], 
                    "${output_dir}/${method}/dorsal_pons.nii.gz")
    ants.image_write(results[method]['ventral'], 
                    "${output_dir}/${method}/ventral_pons.nii.gz")

# Save consensus if available
if 'consensus' in results:
    ants.image_write(results['consensus'], 
                    "${output_dir}/comparison/consensus_pons.nii.gz")
EOF
    
    # Validate results
    validate_segmentation_results "${output_dir}"
    
    return 0
}

validate_segmentation_results() {
    local output_dir="$1"
    
    # Calculate Dice coefficients between methods
    python3 - <<EOF
import ants
import numpy as np

def dice_coefficient(img1, img2):
    intersection = np.sum(img1.numpy() * img2.numpy())
    return 2.0 * intersection / (np.sum(img1.numpy()) + np.sum(img2.numpy()))

suit_pons = ants.image_read("${output_dir}/suit/pons.nii.gz")
harvard_pons = ants.image_read("${output_dir}/harvard/pons.nii.gz")

dice = dice_coefficient(suit_pons, harvard_pons)

with open("${output_dir}/comparison/validation_report.txt", 'w') as f:
    f.write(f"Segmentation Comparison Report\n")
    f.write(f"===========================\n")
    f.write(f"Dice coefficient between methods: {dice:.3f}\n")
EOF
}



# Export functions
export -f compare_segmentation_methods
export -f validate_segmentation_results

log_message "Segmentation comparison module loaded"