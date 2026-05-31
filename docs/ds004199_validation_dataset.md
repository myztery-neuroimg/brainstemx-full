# ds004199 Validation Dataset Notes

Local ignored dataset path:

```text
mri-brain-examples-ds004199-1.0.6/
```

Dataset:
- OpenNeuro `ds004199`, version `1.0.6`
- 170 subjects: 85 focal cortical dysplasia, 85 healthy controls
- Siemens, mostly 3T
- Each subject has one T1w and one FLAIR NIfTI in BIDS layout
- FCD subjects include FLAIR lesion ROI masks

This is not a brainstem-specific lesion dataset, but it is useful for proving
pipeline robustness around NIfTI input handling, T1/FLAIR registration,
reference-space selection, anisotropic FLAIR handling, threshold reporting, and
false-positive behavior on controls.

## Dataset Shape

- T1w acquisitions:
  - `iso08`: 120 subjects, usually `208 x 320 x 320`, `0.8 mm isotropic`
  - `sag111`: 49 subjects, `160 x 256 x 256`, `1.0 mm isotropic`
  - `sag111VNS`: 1 subject
- FLAIR acquisitions:
  - `T2sel`: 126 subjects, usually `160 x 256 x 256`, `1.0 mm isotropic`
  - `tse3dvfl`: 36 subjects, `160 x 256 x 256`, `1.0 mm isotropic`
  - 8 stress acquisitions with thick-slice or unusual geometry
- ROI masks:
  - 85 FCD subjects have `_FLAIR_roi.nii.gz`
  - 85 healthy controls have no ROI mask

## Suggested Smoke Set

Use these first for quick regression coverage:

- `sub-00006`: FCD, matched 1 mm T1/FLAIR, very small ROI, test split
- `sub-00001`: FCD, 0.8 mm T1 vs 1 mm FLAIR, typical geometry
- `sub-00005`: healthy control, 0.8 mm T1 vs 1 mm FLAIR, no ROI
- `sub-00014`: FCD, matched 1 mm T1/FLAIR, `tse3dvfl`
- `sub-00048`: FCD, test split, small ROI

These should exercise:
- basic NIfTI import/symlink harness
- T1/FLAIR registration
- segmentation mask transform direction
- `ATLAS_GMM` volume reporting
- no-ROI control behavior

## Suggested Stress Set

These are the valuable weird cases:

- `sub-00002`: healthy control, FLAIR has 157 slices instead of 160
- `sub-00018`: FCD, coronal hippocampal FLAIR, `0.667 x 0.667 x 4.4 mm`
- `sub-00027`: FCD, axial ACPC FLAIR, `0.667 x 0.667 x 3.675 mm`
- `sub-00053`: FCD, VNS acquisition, thick axial FLAIR
- `sub-00074`: FCD, coronal 3 mm optimized FLAIR, thick slices
- `sub-00112`: FCD, axial 4 mm FLAIR
- `sub-00120`: FCD, coronal ACPC 4 mm FLAIR
- `sub-00130`: FCD, coronal 4 mm FLAIR, large ROI volume

These should be used to stress:
- orientation/geometry handling
- anisotropic FLAIR registration
- brain extraction and standardization
- reference-space selection
- threshold stability under thick-slice partial volume effects

## Useful Assertions

Per subject:
- Pipeline completes or fails with a clear categorized error.
- Registered moving image exists and has the reference grid.
- Segmentation masks remain in-bounds after any reference-space transform.
- Hyperintensity output includes `_threshATLAS_GMM_bin.nii.gz`.
- Volume CSV contains an `ATLAS_GMM` row.
- Cluster report exists and has non-negative cluster counts.
- Healthy controls should not produce large brainstem-region detections.

For FCD subjects, FLAIR ROI masks can be used as an adversarial/negative-control
check: the lesion is cortical, so brainstem detections should usually have low
or zero overlap with the ROI unless registration or masking has gone badly wrong.
