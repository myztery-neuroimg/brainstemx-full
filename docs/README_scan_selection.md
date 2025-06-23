# Enhanced Scan Selection with Multiple Modes

This document describes the scan selection system that has been implemented in the pipeline. The system can now operate in multiple modes, each optimized for different use cases.

## Scan Selection Modes

The pipeline now supports four different modes for selecting the best scan:

### 1. `original` Mode (Default for T1)

This mode exclusively prioritizes ORIGINAL acquisitions over DERIVED ones. It will always select an ORIGINAL scan even if DERIVED scans have higher resolution or better aspect ratios. This is ideal for sensitive analyses like brainstem lesion detection where you want the purest data with minimal processing artifacts.

- Extreme weighting: Acquisition type (ORIGINAL scans receive a massive score bonus)
- Low weighting: Resolution and quality score (only used as tie-breakers between ORIGINAL scans)
- Zero consideration: DERIVED scans (essentially ignored if any ORIGINAL scans exist)

### 2. `highest_resolution` Mode

This mode prioritizes scans with the highest resolution (smallest voxel sizes), regardless of aspect ratio or dimension matching. This is ideal when you want the highest quality standalone image.

- Highest weighting: Resolution (smallest voxels)
- Medium weighting: Overall quality score
- Low weighting: Acquisition type (ORIGINAL vs DERIVED)

### 3. `registration_optimized` Mode (Default for FLAIR)

This mode prioritizes scans that have voxel aspect ratios similar to the reference scan, making them more compatible for registration. This is ideal when the scan will be registered to another modality (e.g., FLAIR to T1).

- Highest weighting: Voxel aspect ratio similarity to reference scan
- Medium weighting: Resolution and quality score
- Low weighting: Acquisition type (ORIGINAL vs DERIVED)

### 4. `matched_dimensions` Mode

This mode prioritizes scans with dimensions that exactly match the reference scan. This is ideal for direct visual comparison between modalities without registration.

- Highest weighting: Exact dimension matching (voxel-for-voxel)
- Medium weighting: Quality score
- Low weighting: Resolution and acquisition type

### 5. `interactive` Mode

This mode displays all available scans with their metrics and lets the user choose which one to use. It includes recommendations for different scenarios.

## Configuration

The selection modes can be configured in `config/default_config.sh`:

```bash
# Scan selection options
export SCAN_SELECTION_MODE="registration_optimized"    # Global default
export T1_SELECTION_MODE="original"                    # T1-specific override
export FLAIR_SELECTION_MODE="registration_optimized"   # FLAIR-specific override
```

## Aspect Ratio Similarity

The system calculates voxel aspect ratios by normalizing the voxel dimensions to the smallest dimension, giving a ratio like `1:1.5:2`. This represents the relative proportions of voxels, which is critical for registration compatibility.

Two scans with similar aspect ratios will register better even if they have different absolute resolutions.

## Quality Metrics

The selection process considers several quality metrics:

- **File size**: Larger files often (not always) have more data/detail
- **Dimensions**: Higher matrix size (more voxels) is generally better
- **Voxel size**: Smaller voxels (higher resolution) is generally better
- **Acquisition type**: ORIGINAL acquisitions are preferred over DERIVED (+30 bonus)
- **Tissue contrast**: For T1 scans, the gray-white matter contrast is measured

## Example Output

When using the `interactive` mode, you'll see a table like this:

```
===== INTERACTIVE SCAN SELECTION =====
Please select the best FLAIR scan from the following options:

------------------------------------------------------------------------------------------------------------------------
                                            SCAN OPTIONS                                                                 
------------------------------------------------------------------------------------------------------------------------
#   | Filename                                | Type     | Dimensions     | Voxel Size (mm)      | Score  | Aspect Ratio         
------------------------------------------------------------------------------------------------------------------------
1   | T2_SPACE_FLAIR_Sag_CS_1035.nii.gz      | DERIVED  | 512x512x149    | 0.488x0.488x0.977    | 152.25 | 1:1:2                
2   | T2_SPACE_FLAIR_Sag_CS_1047.nii.gz      | DERIVED  | 160x512x511    | 0.977x0.618x0.618    | 120.31 | 1.58:1:1             
3   | T2_SPACE_FLAIR_Sag_CS_17.nii.gz        | ORIGINAL | 176x256x256    | 1.000x0.977x0.977    | 145.10 | 1.02:1:1             

Reference scan: T1_MPRAGE_SAG_12.nii.gz
Recommendations:
- For highest resolution: Option 1
- For best registration compatibility: Option 2
- For exact dimension matching: Option 3

Enter selection (1-3): 
```

## Technical Details

The aspect ratio similarity is calculated using the Euclidean distance between the normalized aspect ratios of two scans. The smaller the distance, the more similar they are. The similarity score is then computed as:

```
similarity = 100 / (1 + 10 * distance)
```

This provides a score from 0-100, where 100 means identical aspect ratios.

## Typical Usage Patterns

- For T1: Usually `original` is best to ensure purest data as reference image
- For FLAIR: Usually `registration_optimized` is best as FLAIR is often registered to T1
- For visual validation: `matched_dimensions` ensures a direct 1:1 comparison
- For sensitive structures (brainstem): `original` avoids any processing artifacts
- For research exploration: `interactive` allows examining all options

## Special Note on Brainstem Lesion Analysis

For brainstem analysis, using the `original` mode is particularly important as:

1. Even subtle processing artifacts introduced by resampling in DERIVED images can mimic or obscure small lesions
2. Brainstem structures are small and densely packed, requiring highest fidelity data
3. Registration-introduced interpolation can blur the boundaries between critical structures

When analyzing brainstem lesions, prefer using scans like T2_SPACE_FLAIR_Sag_CS_17.nii.gz that are:
- ORIGINAL acquisitions
- Have consistent dimensions with the T1 reference
- Avoid any unnecessary resampling or interpolation
