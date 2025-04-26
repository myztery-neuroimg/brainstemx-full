# Orientation Distortion Correction

## Overview

Orientation distortion is a common problem in medical image registration, particularly when registering different modalities or sequences. It occurs when the registration process introduces incorrect deformations that misalign anatomical structures, especially in regions with complex structures like the brainstem and pons.

This feature implements three complementary methods to correct orientation distortions:

1. **Topology-Preserving Registration**: Prevents orientation distortion during the initial registration
2. **Anatomically-Constrained Registration**: Uses anatomical priors to maintain orientation in critical structures 
3. **Post-Registration Correction**: Detects and corrects orientation distortions after registration is complete

## Configuration Parameters

Orientation distortion correction is controlled by the following parameters in `config/default_config.sh`:

### Main Toggle

```bash
# Enable or disable orientation preservation in registration
export ORIENTATION_PRESERVATION_ENABLED=true
```

### Topology Preservation Parameters

```bash
# Controls strength of topology preservation (0-1)
# Higher values enforce stronger orientation preservation but may reduce alignment accuracy
export TOPOLOGY_CONSTRAINT_WEIGHT=0.5

# Deformation field constraints in x,y,z dimensions
# Format is "XxYxZ" where each value controls allowed deformation in that dimension
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"
```

### Jacobian Regularization Parameters

```bash
# Weight for regularization (0-1)
# Higher values enforce smoother deformations and better preserve local orientation
export JACOBIAN_REGULARIZATION_WEIGHT=1.0 

# Weight for gradient field orientation matching (0-1)
# Controls how strongly the registration tries to preserve orientation from the original image
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5
```

### Correction Thresholds

```bash
# Mean angular deviation threshold to trigger correction
# If mean deviation exceeds this value (in radians), correction will be applied
export ORIENTATION_CORRECTION_THRESHOLD=0.3

# Scaling factor for correction deformation field
# Lower values apply gentler corrections
export ORIENTATION_SCALING_FACTOR=0.05

# Smoothing sigma for correction field (in mm)
# Higher values create smoother correction fields
export ORIENTATION_SMOOTH_SIGMA=1.5
```

### Quality Assessment Thresholds

```bash
# These thresholds determine the quality assessment of registration orientation
export ORIENTATION_EXCELLENT_THRESHOLD=0.1   # Mean angular deviation below this is excellent
export ORIENTATION_GOOD_THRESHOLD=0.2        # Mean angular deviation below this is good
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.3  # Mean angular deviation below this is acceptable

# Threshold for detecting significant shearing in transformations
# Measures deviation from orthogonality (0-1), with lower values being more sensitive
export SHEARING_DETECTION_THRESHOLD=0.05
```

## Scanner Metadata and Orientation Information

### Orientation Information Source

The orientation distortion correction works with images from all scanner vendors (Siemens, Philips, GE, etc.) because it leverages orientation information preserved during the DICOM-to-NIfTI conversion process:

1. **During DICOM Import**:
   - The dcm2niix tool preserves the patient orientation matrix from DICOM headers (Direction Cosines) in the NIfTI header
   - This information includes the scanner's coordinate system and patient orientation

2. **In NIfTI Format**:
   - Orientation information is stored in the qform/sform matrices in the NIfTI header
   - These matrices encode the transformation from voxel indices to physical space

3. **During Processing**:
   - Rather than directly using DICOM headers, our approach applies gradient operations on the images
   - This extracts orientation information directly from the image data, making it scanner-independent
   - The gradient fields represent anatomical orientation independent of scanner-specific coordinate systems

This approach ensures that the orientation preservation works regardless of scanner manufacturer, as it operates on the geometric properties of the image after conversion to NIfTI, rather than relying on vendor-specific DICOM tags.

## Quality Assurance and Visualization

The orientation distortion correction includes comprehensive QA features:

1. **Quantitative Metrics**:
   - Mean angular deviation: Measures average orientation change (in radians)
   - Shearing detection: Identifies non-linear orientation distortion
   - Region-specific metrics: Focused analysis for brainstem subregions

2. **Visual Reports**:
   - Orientation deviation maps: Color-coded visualization of distortion
   - Masked deviation maps: Focus on specific regions like brainstem
   - Integration with HTML reports: Metrics displayed with status indicators

3. **Quality Assessment**:
   - Automated quality ratings (Excellent/Good/Acceptable/Poor)
   - Quality thresholds configurable in default_config.sh
   - Integration with overall registration quality assessment

These QA features help validate that the orientation correction is working properly and provide intuitive visualizations of any remaining distortions after correction.

## Quality Preset Integration

The orientation preservation parameters are linked to the existing quality presets:

### HIGH Quality Preset (Default)
```bash
# Orientation preservation parameters for HIGH quality (strict preservation)
export ORIENTATION_PRESERVATION_ENABLED=true
export TOPOLOGY_CONSTRAINT_WEIGHT=0.5
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"
export JACOBIAN_REGULARIZATION_WEIGHT=1.0
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5
export ORIENTATION_CORRECTION_THRESHOLD=0.25  # Stricter threshold
export ORIENTATION_SCALING_FACTOR=0.05
export ORIENTATION_SMOOTH_SIGMA=1.0
export ORIENTATION_EXCELLENT_THRESHOLD=0.08
export ORIENTATION_GOOD_THRESHOLD=0.15
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.25
export SHEARING_DETECTION_THRESHOLD=0.04
```

### MEDIUM Quality Preset
```bash
# Orientation preservation parameters for MEDIUM quality (balanced)
export ORIENTATION_PRESERVATION_ENABLED=true
export TOPOLOGY_CONSTRAINT_WEIGHT=0.3
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"
export JACOBIAN_REGULARIZATION_WEIGHT=0.7
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.3
export ORIENTATION_CORRECTION_THRESHOLD=0.3
export ORIENTATION_SCALING_FACTOR=0.03
export ORIENTATION_SMOOTH_SIGMA=1.5
export ORIENTATION_EXCELLENT_THRESHOLD=0.1
export ORIENTATION_GOOD_THRESHOLD=0.2
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.3
export SHEARING_DETECTION_THRESHOLD=0.05
```

### LOW Quality Preset
```bash
# Orientation preservation parameters for LOW quality (faster processing)
export ORIENTATION_PRESERVATION_ENABLED=false  # Disabled for faster processing
export TOPOLOGY_CONSTRAINT_WEIGHT=0.2
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"
export JACOBIAN_REGULARIZATION_WEIGHT=0.5
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.2
export ORIENTATION_CORRECTION_THRESHOLD=0.4  # Less strict threshold
export ORIENTATION_SCALING_FACTOR=0.02
export ORIENTATION_SMOOTH_SIGMA=2.0
export ORIENTATION_EXCELLENT_THRESHOLD=0.15
export ORIENTATION_GOOD_THRESHOLD=0.3
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.4
export SHEARING_DETECTION_THRESHOLD=0.1
```

## Implementation Details

### Topology-Preserving Registration

This method constrains the allowable deformations during registration to preserve the topological structure of anatomical regions. It uses ANTs SyN with the `--restrict-deformation` parameter to maintain orientation relationships.

```bash
register_with_topology_preservation() {
    # Uses ANTs SyN with topology constraint parameter
    antsRegistration --dimensionality 3 \
      [...other parameters...] \
      --transform SyN[0.1,3,0] \
      --restrict-deformation ${TOPOLOGY_CONSTRAINT_FIELD} \
      [...other parameters...]
}
```

### Anatomically-Constrained Registration

This method uses anatomical priors (e.g., a brainstem mask) to guide registration and preserve orientation in critical structures. It calculates gradient fields to capture anatomical orientation and uses them as constraints.

```bash
register_with_anatomical_constraints() {
    # Create orientation priors (principal direction field)
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    fslmaths "$fixed" -gradient_y "${temp_dir}/fixed_grad_y.nii.gz"
    fslmaths "$fixed" -gradient_z "${temp_dir}/fixed_grad_z.nii.gz"
    
    # Uses ANTs with orientation constraints via jacobian regularization
    antsRegistration --dimensionality 3 \
      [...other parameters...] \
      --jacobian-regularization ${JACOBIAN_REGULARIZATION_WEIGHT} \
      --regularization-weight ${TOPOLOGY_CONSTRAINT_WEIGHT} \
      [...other parameters...]
}
```

### Post-Registration Correction

This method detects orientation distortions after registration by comparing gradient fields between the fixed and warped images. It then calculates a correction field and applies it to fix the distortions.

```bash
correct_orientation_distortion() {
    # Calculate gradient fields
    fslmaths "$fixed" -gradient_x "${temp_dir}/fixed_grad_x.nii.gz"
    [...similar for y,z and warped image...]
    
    # Calculate gradient differences (velocity field)
    fslmaths "${temp_dir}/fixed_grad_x.nii.gz" -sub "${temp_dir}/warped_grad_x.nii.gz" "${temp_dir}/diff_x.nii.gz"
    [...similar for y,z...]
    
    # Apply correction
    ANTSIntegrateVelocityField 3 "${temp_dir}/scaled_diff.nii.gz" "${temp_dir}/correction_field.nii.gz" 1 5
    ComposeTransforms 3 "${temp_dir}/corrected_transform.nii.gz" -r "$transform" "${temp_dir}/correction_field.nii.gz"
    antsApplyTransforms -d 3 -i "$warped" -r "$fixed" -o "$output" -t "${temp_dir}/corrected_transform.nii.gz"
}
```

## Testing and Evaluation

A dedicated testing mode has been implemented to evaluate the effectiveness of the orientation distortion correction methods. To run the test:

```bash
./pipeline.sh -p ORIENTATION_TEST -i /path/to/dicom/dir -o /path/to/output/dir
```

The test performs the following:

1. Runs standard registration for comparison
2. Runs topology-preserving registration
3. Runs anatomically-constrained registration 
4. Applies orientation correction to standard registration
5. Calculates orientation metrics for all approaches
6. Generates a comparative report

The test report (`[output_dir]/orientation_test/orientation_test_report.txt`) includes:
- Mean angular deviation for each method
- Configuration parameters used
- Improvement metrics between methods

Example report:
```
Orientation Preservation Test Results
====================================

Standard Registration Mean Angular Deviation: 0.323451
Topology-Preserving Registration Mean Angular Deviation: 0.156732
Anatomically-Constrained Registration Mean Angular Deviation: 0.132195
Corrected Registration Mean Angular Deviation: 0.167654

Configuration Parameters:
  TOPOLOGY_CONSTRAINT_WEIGHT: 0.5
  TOPOLOGY_CONSTRAINT_FIELD: 1x1x1
  JACOBIAN_REGULARIZATION_WEIGHT: 1.0
  REGULARIZATION_GRADIENT_FIELD_WEIGHT: 0.5
  ORIENTATION_CORRECTION_THRESHOLD: 0.25
  ORIENTATION_SCALING_FACTOR: 0.05
  ORIENTATION_SMOOTH_SIGMA: 1.0

Improvement Metrics:
  Standard to Topology: 0.166719
  Standard to Anatomical: 0.191256
  Standard to Corrected: 0.155797

Test completed: Fri Apr 26 20:15:45 CEST 2025
```

## Pipeline Integration

The orientation preservation is integrated into the main pipeline workflow. When enabled (`ORIENTATION_PRESERVATION_ENABLED=true`), the pipeline:

1. Checks if a brainstem mask is already available
2. Uses anatomically-constrained registration if a mask exists, otherwise uses topology-preserving registration
3. Validates the registration with orientation metrics
4. Applies post-registration correction if the orientation deviation exceeds the threshold
5. Updates the registered image with the corrected version

## Recommendations

- For critical regions like the brainstem and pons, use the HIGH quality preset which enables strict orientation preservation
- For faster processing of less orientation-critical regions, use the LOW quality preset
- For examining the impact of orientation preservation, run the ORIENTATION_TEST pipeline
- Adjust the threshold parameters if you notice over-correction or under-correction

## Technical Background

Orientation distortion in medical image registration can significantly impact the accuracy of subsequent analyses, especially in regions with complex structures and directional tissue organization like the brainstem and pons. The three complementary methods implemented here address this issue from different angles:

1. **Preventing Distortion**: Topology preservation constrains the registration to prevent introducing distortions
2. **Guiding Registration**: Anatomical constraints use structural information to guide the registration
3. **Correcting Distortion**: Post-processing correction identifies and fixes distortions after they occur

The effectiveness of these methods is measured using orientation metrics, which quantify the angular deviation between gradient vectors in the fixed and warped images. Lower angular deviation indicates better preservation of anatomical orientation.