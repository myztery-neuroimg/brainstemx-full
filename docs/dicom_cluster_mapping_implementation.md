# DICOM Cluster Mapping Implementation

> **Status (2026): implemented and ON by default** (`RUN_DICOM_MAPPING=true` in
> `config/default_config.sh`). The stage runs at the tail of Step 6 (Analysis)
> in `pipeline.sh` and maps every detected hyperintensity cluster back to its
> nearest source DICOM slice. Set `RUN_DICOM_MAPPING=false` to opt out (the
> stage is then skipped). Implemented in `src/modules/dicom_cluster_mapping.sh`
> (orchestration + reverse spatial chain) and `src/modules/map_clusters_to_dicom.py`
> (NIfTI affine + pydicom slice matching).

## Overview

Hyperintense clusters are detected in processed NIfTI space. This stage maps
each cluster back to the specific **source DICOM file/slice** it corresponds to,
so a reviewer can open the lesion directly in a PACS / DICOM viewer. Output is a
per-cluster CSV + human-readable TXT carrying, for each cluster: id, volume,
native voxel COG, world mm, DICOM patient mm, matched source DICOM file,
`InstanceNumber`, `SOPInstanceUID`, `SliceLocation`, and the match distance.

## Implemented flow

The pipeline detects clusters in `orig_flair` space — the brain-extracted FLAIR,
which **preserves the original native FLAIR voxel grid** (brain extraction either
runs directly on the native image or maps its mask back onto the native grid via
`map_mask_to_original_grid` in `utils.sh`). The cluster index volume
(`clusters.nii.gz`, integer cluster ids, written by `analyze_hyperintensity_clusters`
in `qa.sh`) is therefore on the native FLAIR grid, whose NIfTI sform encodes the
scanner geometry `dcm2niix` wrote.

1. **Input contract — the cluster index volume.** `perform_cluster_to_dicom_mapping`
   discovers `clusters.nii.gz` under the cluster-analysis directory. There is no
   prose/report parsing: per-cluster COGs are re-derived directly from the
   integer label volume (mean voxel index per label), which is robust to the
   voxel-vs-mm ambiguity of the sidecar `cluster_stats.csv` (whose `X,Y,Z` are
   `fslstats -C` **voxel** centroids).

2. **Reverse spatial step → native grid (identity).** `resample_index_to_native`
   resamples the cluster index volume onto the original native FLAIR grid with
   `antsApplyTransforms -d 3 -n GenericLabel` (GenericLabel preserves discrete
   cluster ids). Because clusters are detected in `orig_flair` space, which is
   already the native FLAIR grid, this is an **identity** transform — a pure
   resample, no `-t` transforms. The COG is then re-derived on that grid rather
   than point-transformed through hand-inverted crop/pad/resample. (We
   deliberately do **not** apply the contrast-matched cascade's
   `*_to_t1_inverse_transforms.txt` here: those map T1 to a *different* modality
   — DWI/SWI/T2 — and would displace the FLAIR-space clusters. The persisted
   inverse chains from PR #134 remain available for any future feature that
   detects clusters in a registered reference space.)

3. **Native voxel → world mm → DICOM patient mm.** `map_clusters_to_dicom.py`
   converts each native-grid COG voxel → world millimetres via the NIfTI
   sform/qform affine (nibabel), then flips NIfTI RAS → DICOM LPS by negating the
   first two world axes: `lps = (-ras_x, -ras_y, ras_z)`.

4. **DICOM file/slice matching.** The Python helper reads the source DICOM
   headers with pydicom (`stop_before_pixels=True`), groups slices by
   `SeriesInstanceUID`, and for each cluster finds the nearest slice by the proper
   **slice-normal projection**: with the series' `ImageOrientationPatient` row/col
   direction cosines it computes the slice normal `n = row × col`, and the
   perpendicular distance of the cluster's LPS point to each slice plane is
   `|n · (point − ImagePositionPatient)|` (full 3D, not Z-only). The nearest
   slice's `InstanceNumber`, `SOPInstanceUID`, `SliceLocation` and match distance
   are emitted. Nested series directories (`SE####/IM####`) are traversed
   recursively, and files are sniffed by extension or the `DICM` magic.

5. **Fallbacks.** When pydicom is unavailable, coordinates are still emitted and
   a `dcmdump`-based matcher (`match_with_dcmdump`, no DCMTK Python binding
   needed) fills the match columns by nearest 3D distance using a single AWK pass
   (no subshell variable-loss). When ANTs or the native reference is unavailable,
   the cluster grid is used directly.

## Outputs

Per cluster index volume processed, under `${RESULTS_DIR}/dicom_cluster_mapping/`:

- `<name>_dicom_mapping.csv` — machine-readable, one row per cluster. Columns:
  `ClusterID, Volume_mm3, Voxel_i, Voxel_j, Voxel_k, World_X_mm, World_Y_mm,
  World_Z_mm, DICOM_X_mm, DICOM_Y_mm, DICOM_Z_mm, DICOM_File, SeriesDescription,
  InstanceNumber, SOPInstanceUID, SliceLocation, MatchDistance_mm`.
- `<name>_dicom_mapping.txt` — human-readable per-cluster report.
- `<name>_native_index.nii.gz` — the cluster index resampled onto the native grid.
- `cluster_dicom_mapping_summary.txt` — run summary.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `RUN_DICOM_MAPPING` | `true` | Run the stage; set `false` to opt out |
| `DICOM_MATCH_TOLERANCE_MM` | `5.0` | Reporting tolerance; the nearest slice is always reported, clusters beyond tolerance are flagged in the log (not dropped) |

## Coordinate systems

- **NIfTI** affines are RAS+ (x→Right, y→Anterior, z→Superior).
- **DICOM** patient space is LPS (x→Left, y→Posterior, z→Superior).
- Conversion is therefore `lps = (-ras_x, -ras_y, ras_z)` — a negation of the
  first two world axes.

## Dependencies

- **ANTs**: `antsApplyTransforms` (reverse-chain resample; GenericLabel interp).
- **Python (via `uv`)**: `nibabel`, `numpy` (required), `pydicom` (required for
  DICOM matching) — all declared in `pyproject.toml`.
- **dcmdump** (optional): fallback matcher when pydicom is unavailable.

## Testing

- `tests/test_map_clusters_to_dicom.py` (pytest): synthetic round-trip — a known
  native voxel COG through the NIfTI affine to world mm to DICOM LPS recovers the
  input to sub-millimetre tolerance (off-origin, anisotropic affine, RAS↔LPS
  flip); synthetic pydicom-written axial series — each cluster matches the
  correct slice and emits the right `InstanceNumber`/`SOPInstanceUID`; nested
  `SE####/IM####` traversal; CLI end-to-end.
- `tests/test_dicom_mapping_integration.sh` (bash): module load/exports, pipeline
  integration, un-gated default + opt-out, native-FLAIR reference discovery, and a
  **real ANTs identity round-trip** (a cluster on an anisotropic off-origin native
  grid is resampled onto that grid via `resample_index_to_native` and its COG
  world coordinate is recovered within 1 mm).
