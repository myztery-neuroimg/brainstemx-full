#!/usr/bin/env python3
"""
Voxel Value Extraction for GMM Analysis

This script extracts individual voxel values from masked NIfTI images
for Gaussian Mixture Model analysis in the brain MRI processing pipeline.

Usage:
    python3 extract_voxel_values.py <masked_image.nii.gz> <output_values.txt>

Author: Generated for brainstemx-full pipeline
"""

import sys
import numpy as np
import nibabel as nib
from pathlib import Path


def extract_voxel_values(masked_image_path, output_file_path, debug=True):
    """
    Extract all non-zero finite voxel values from a masked NIfTI image.
    
    Args:
        masked_image_path (str): Path to the masked NIfTI image
        output_file_path (str): Path to output text file for values
        debug (bool): Whether to print debug information
    
    Returns:
        int: Number of voxel values extracted
    """
    try:
        # Load the masked z-score image
        if debug:
            print(f"Loading image: {masked_image_path}", file=sys.stderr)
        
        img = nib.load(masked_image_path)
        data = img.get_fdata()
        
        if debug:
            print(f"Image shape: {data.shape}", file=sys.stderr)
            print(f"Total voxels in image: {data.size}", file=sys.stderr)
            print(f"Non-zero voxels: {np.count_nonzero(data)}", file=sys.stderr)
            print(f"Data range: {np.min(data):.6f} to {np.max(data):.6f}", file=sys.stderr)
        
        # Extract ALL non-zero finite values
        mask_data = data[data != 0]
        finite_values = mask_data[np.isfinite(mask_data)]
        
        if debug:
            print(f"After filtering - finite non-zero values: {len(finite_values)}", file=sys.stderr)
        
        # Write values to output file
        with open(output_file_path, 'w') as f:
            if len(finite_values) > 0:
                # Output each individual voxel value on separate lines
                for val in finite_values:
                    f.write(f"{val:.6f}\n")
                
                if debug:
                    print(f"Successfully extracted {len(finite_values)} voxel values for GMM", file=sys.stderr)
                
                return len(finite_values)
            else:
                # Write fallback value if no values found
                f.write("0\n")
                if debug:
                    print("ERROR: No non-zero finite values found in masked image", file=sys.stderr)
                return 0
                
    except Exception as e:
        if debug:
            print(f"ERROR: Python extraction failed: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
        
        # Write fallback value
        try:
            with open(output_file_path, 'w') as f:
                f.write("0\n")
        except:
            pass
        
        return -1


def main():
    """Main function for command line usage."""
    if len(sys.argv) != 3:
        print("Usage: python3 extract_voxel_values.py <masked_image.nii.gz> <output_values.txt>", file=sys.stderr)
        sys.exit(1)
    
    masked_image_path = sys.argv[1]
    output_file_path = sys.argv[2]
    
    # Check if input file exists
    if not Path(masked_image_path).exists():
        print(f"ERROR: Input file not found: {masked_image_path}", file=sys.stderr)
        sys.exit(1)
    
    # Extract voxel values
    num_extracted = extract_voxel_values(masked_image_path, output_file_path, debug=True)
    
    if num_extracted < 0:
        sys.exit(1)
    elif num_extracted == 0:
        print("WARNING: No voxel values extracted", file=sys.stderr)
    else:
        print(f"SUCCESS: Extracted {num_extracted} voxel values", file=sys.stderr)


if __name__ == "__main__":
    main()