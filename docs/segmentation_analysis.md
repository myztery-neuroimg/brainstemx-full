# Brain MRI Segmentation Analysis

## Recent Segmentation Improvements (June 2025)
- Corrected Harvard-Oxford atlas selection to index 7 (brainstem only).
- Switched MNI→native transform to trilinear interpolation + 0.5 thresholding.
- Unified file naming for T1 and FLAIR intensity outputs.
- Applied same interpolation fix to Juelich pons segmentation.
- Generated separate FLAIR intensity masks for segmentation QA.

## Introduction & Purpose
The segmentation modules (`segmentation.sh` and `segment_juelich.sh`) perform atlas-based brainstem and pons segmentation in T1 native space, leveraging FSL and ANTs tools. This document outlines workflows, dependencies, outputs, and validation steps.

## Pipeline Dependencies
- FSL: `fslmaths`, `flirt`, `fslstats`
- ANTs: `antsApplyTransforms`
- Python 3 (NiBabel, optional for custom scripts)

## Harvard-Oxford Brainstem Segmentation Workflow
1. Brainstem mask in MNI space:
   ```bash
   fslmaths $OXFORD_ATLAS -thr 7 -uthr 7 -bin brainstem_std_mask.nii.gz
   ```
2. Transform mask to T1 native space (trilinear interpolation):
   ```bash
   flirt -in brainstem_std_mask.nii.gz \
         -ref T1.nii.gz \
         -applyxfm -init std2t1.mat \
         -interp trilinear \
         brainstem_native_float.nii.gz
   fslmaths brainstem_native_float.nii.gz \
            -thr 0.5 -bin \
            brainstem_mask.nii.gz
   ```
3. Extract T1 intensities:
   ```bash
   fslmaths T1.nii.gz -mas brainstem_mask.nii.gz \
            brainstem_t1_intensity.nii.gz
   ```
4. (Optional) Extract FLAIR intensities:
   ```bash
   fslmaths FLAIR.nii.gz -mas brainstem_mask.nii.gz \
            brainstem_flair_intensity.nii.gz
   ```

## Juelich Pons Segmentation Workflow
1. Pons priors in MNI space (label 1 = pons):
   ```bash
   fslmaths $JUELICH_ATLAS -thr 1 -uthr 1 -bin pons_std_mask.nii.gz
   ```
2. Transform mask to T1 native space:
   ```bash
   flirt -in pons_std_mask.nii.gz \
         -ref T1.nii.gz \
         -applyxfm -init std2t1.mat \
         -interp trilinear \
         pons_native_float.nii.gz
   fslmaths pons_native_float.nii.gz \
            -thr 0.5 -bin \
            pons_mask.nii.gz
   ```
3. Subdivide pons into dorsal/ventral:
   ```bash
   # Example: split along principal axis
   python split_pons.py \
          --input pons_mask.nii.gz \
          --output-dir pons
   ```

## Interpolation & Thresholding Methods
- Trilinear interpolation preserves partial volumes when resampling binary masks.  
- Threshold at 0.5 converts floating masks to binary while including >50% voxels.

## Output File Structure
```text
segmentation/
├── brainstem_mask.nii.gz
├── brainstem_t1_intensity.nii.gz
├── brainstem_flair_intensity.nii.gz
├── pons/
│   ├── dorsal_pons_mask.nii.gz
│   └── ventral_pons_mask.nii.gz
├── combined_segmentation_label.nii.gz
└── segmentation_report.txt
```

## Validation & Volume Checks
- Use `fslstats -V` to compute voxel counts and volumes:
   ```bash
   fslstats brainstem_mask.nii.gz -V
   fslstats pons_mask.nii.gz -V
   ```
- Expected volumes:
  - Brainstem: ~2,000–5,000 voxels (~8–20 mL)  
  - Pons: ~500–1,000 voxels (~2–4 mL)  
- Pons-to-brainstem ratio should be within ~0.2–0.5.

## Example CLI Usage
```bash
./segmentation.sh \
  -i T1.nii.gz \
  -f FLAIR.nii.gz \
  -m std2t1.mat \
  -o segmentation
```
- Outputs masks, intensities, and a report in `segmentation/`.