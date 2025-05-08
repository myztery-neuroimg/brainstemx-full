# FSL Gradient Calculation Issue

## Problem Description

The orientation correction module (`src/modules/orientation_correction.sh`) uses `fslmaths` with the `-gradient_x`, `-gradient_y`, and `-gradient_z` operations to calculate spatial gradients in three directions. These gradient operations are essential for:

1. Creating orientation priors in `register_with_anatomical_constraints()`
2. Detecting orientation distortion in `correct_orientation_distortion()`
3. Calculating orientation deviation in `calculate_orientation_deviation()`

However, these gradient operations are not supported in the current FSL installation. When running the scripts, operations like:

```bash
fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
```

fail because the `-gradient_x/y/z` functions aren't available in the installed FSL version.

## Importance of Gradient Operations

Gradient operations are critical for the orientation preservation functionality because:

1. They capture directional information about anatomical structures
2. They are used to measure orientation deviation between images
3. They help identify and correct orientation distortions during registration
4. They provide a way to calculate angular deviation between registered images

Without these gradient operations, the orientation correction features cannot function properly.

## Options Considered

### 1. Using Alternative FSL Operations

We examined the available operations in the current FSL installation using `fslmaths -help`. The available operations include:

- Basic operations like `-exp`, `-log`, `-sin`, etc.
- Kernel operations like `-kernel 3D`, `-kernel box`, etc.
- Filtering operations like `-dilM`, `-ero`, `-fmedian`, `-fmean`, etc.
- Edge detection via `-edge` (but this only gives overall edge strength, not directional gradients)
- Difference of Gaussians edge filter via `-dog_edge` (also not directional)

None of these operations provide the directional gradient information needed for the orientation correction module.

### 2. Python-based Gradient Calculation

A viable solution would be to create a Python helper script that uses `nibabel` and `numpy` to calculate spatial gradients in x, y, and z directions. This script would:

- Take an input image, output path, and direction (x/y/z) as parameters
- Load the input image using `nibabel`
- Calculate directional gradients using `numpy.gradient()`
- Save the result as a new NIFTI file with the same header information

Example implementation concept:

```python
#!/usr/bin/env python3
# gradient_calc.py
import sys
import os
import nibabel as nib
import numpy as np

def calculate_gradient(input_path, output_path, direction):
    """Calculate gradient in specified direction (x=0, y=1, z=2)"""
    # Load the image
    img = nib.load(input_path)
    data = img.get_fdata()
    
    # Calculate gradient in specified direction
    grad = np.gradient(data, axis=direction)
    
    # Create new Nifti image with same header
    grad_img = nib.Nifti1Image(grad, img.affine, img.header)
    
    # Save the result
    nib.save(grad_img, output_path)
    
    print(f"Gradient calculated and saved to {output_path}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: gradient_calc.py input_image output_image direction[x/y/z]")
        sys.exit(1)
    
    input_path = sys.argv[1]
    output_path = sys.argv[2]
    direction = sys.argv[3].lower()
    
    # Map direction to axis number
    direction_map = {'x': 0, 'y': 1, 'z': 2}
    
    if direction not in direction_map:
        print("Direction must be one of: x, y, z")
        sys.exit(1)
    
    calculate_gradient(input_path, output_path, direction_map[direction])
```

The shell script would then be modified to call this Python script instead of using `fslmaths` for gradient calculations:

```bash
# Instead of:
# fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"

# Use:
python3 gradient_calc.py "$fixed" "${temp_dir}/fixed_grad_x.nii.gz" "x"
```

### 3. Using ANTs or Other Tools

Another option would be to use ANTs (Advanced Normalization Tools) or other neuroimaging libraries that provide gradient calculation. However, this would require significant rewrites to the entire orientation correction module and would introduce new dependencies.

### 4. Modified FSL Build

A more complex solution would be to build a modified version of FSL that includes the missing gradient operations. This would require access to the FSL source code and compilation expertise, making it a more challenging option to implement.

## Implementation Plan (For Future Reference)

When implementing the Python-based solution, we would need to:

1. Create the `gradient_calc.py` script in an appropriate directory (e.g., `src/modules/`)
2. Make it executable with `chmod +x gradient_calc.py`
3. Modify the orientation_correction.sh script to use this helper in three functions:
   - `register_with_anatomical_constraints()`
   - `correct_orientation_distortion()`
   - `calculate_orientation_deviation()`
4. Add checks for Python and required libraries (nibabel, numpy) in the orientation_correction.sh script
5. Update the documentation to reflect the new gradient calculation method

## Impact Analysis

The issue affects:
- `src/modules/orientation_correction.sh` (main implementation)
- `src/test_orientation_preservation.sh` (testing script)
- `docs/orientation-distortion-correction.md` (documentation)

Fixing this issue would restore the orientation preservation functionality, which is important for maintaining anatomical orientation during registration and correcting orientation distortions that might occur.

## Next Steps

This issue will be parked for now, with implementation to be considered at a later time. When implementation is ready to proceed, the Python-based gradient calculation approach is the recommended solution.