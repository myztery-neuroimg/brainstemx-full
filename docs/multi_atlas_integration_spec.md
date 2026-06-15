# Multi-Atlas Brainstem Labeling Integration Spec

Status: implemented in `src/modules/multi_atlas.sh`.

This document specifies how the BrainStemX pipeline integrates three additional
brain atlases — **Bianciardi BrainstemNavigator v1.0**, **CIT168**, and
**AAL3** — to produce nucleus-level and gross-subdivision masks in subject T1
space, layered on top of the Harvard-Oxford gross Brain-Stem extent.

The masks are written to `${RESULTS_DIR}/segmentation/detailed_brainstem/` with
names that `analysis.sh:find_all_atlas_regions` discovers, so the existing
per-region GMM hyperintensity detection consumes them with no further wiring.

## Prerequisite: atlases on disk

All atlases must be pre-downloaded under `$FSLDIR/data/atlases`
(`ATLAS_DIR`, default `${FSLDIR}/data/atlases`). The module degrades gracefully
(WARNING + non-fatal return) when an atlas, external tool, or template is
missing — it never hard-crashes.

```
$FSLDIR/data/atlases/
  Bianciardi/BrainstemNavigatorv1.0/1.0/
    2a.BrainstemNucleiAtlas_MNI/labels_thresholded_probabilistic_0.35/   (76 nuclei)
    2b.DiencephalicNucleiAtlas_MNI/labels_thresholded_probabilistic_0.35/ (10 nuclei)
    # NOTE: the IIT dirs 1a/1b are a DIFFERENT template and are EXCLUDED.
  CIT168/MNI152/
    tpl-MNI152NLin6Asym_atlas-CIT168_res-01_dseg.nii.gz                  (16 labels)
    CIT168_labels.txt
    # (the 2009cAsym variant is ignored)
  AAL3/AAL3/
    AAL3v1_1mm.nii.gz                                                    (170 labels)
    AAL3v1.nii.txt                                                       (LUT)
```

## Cache layout (`*/derived/`)

Expensive builds are cached and idempotent (rebuilt only when an input is newer
than the cache).

```
Bianciardi/derived/
  Bianciardi_MNI_brainstem-dien_dseg.nii.gz   int16 winner-take-all dseg, 182×218×182 FSL grid
  Bianciardi_MNI_labels.txt                    "# index  name  owned_voxels"
  Bianciardi_MNI_overlay_nuclei.txt            "# nucleus  source_prob_map"  (the 12 overlay nuclei)
  overlay/<nucleus>.nii.gz                      copies of overlay nuclei prob maps
AAL3/derived/
  AAL3v1_1mm_src.nii.gz                         unambiguous copy of the source (see AAL3 note)
  AAL3v1_1mm_std.nii.gz                         after fslreorient2std
  AAL3v1_1mm_fslmni.nii.gz                      resampled onto the FSL MNI152 grid (cache product)
```

Per-subject products live under `${RESULTS_DIR}/segmentation/multi_atlas/`
(warped dsegs, the shared MNI→subject SyN transform, warped overlay nuclei) and
`${RESULTS_DIR}/segmentation/detailed_brainstem/` (the per-region masks).

## Shared LUT parser: `parse_atlas_lut <lut_file>`

A single index→name parser tolerant of all three LUT formats:

| Atlas | LUT | Format |
|---|---|---|
| AAL3 | `AAL3v1.nii.txt` | `idx name color…` (1-indexed) |
| CIT168 | `CIT168_labels.txt` | `idx name` (**0-indexed**: idx 0 = Pu) |
| Bianciardi | generated `Bianciardi_MNI_labels.txt` | `idx name owned_voxels` (1-indexed) |

Behaviour: skip `#` and blank lines, tolerate CRLF, split on whitespace/tab,
`idx = field0` (must be an integer), `name = field1`, ignore trailing fields.
Emits normalized `idx<TAB>name`.

### LUT index vs. dseg voxel value (the CIT168 off-by-one)

A 0-indexed LUT names label 0 as a real structure, but a dseg image reserves
voxel value 0 for background. So for CIT168 the dseg voxel value is `LUT index + 1`
(verified: Putamen `Pu`, LUT index 0, is dseg value 1 with 14 346 voxels at 1 mm;
Red Nucleus `RN`, LUT index 7, is dseg value 8 with 858 voxels).

`split_dseg_to_region_masks` calls `_lut_image_offset`, which returns **1** when
the LUT's smallest index is 0 (CIT168) and **0** otherwise (AAL3, Bianciardi),
then thresholds the dseg at `idx + offset`. Output masks are named with the
*image value* (`cit168_pu_label1.nii.gz`), not the LUT index.

## Per-atlas space handling

### Bianciardi (no resample; hybrid argmax + overlay)

- Source: the **MNI** thresholded-probabilistic maps only (`2a` + `2b`,
  `labels_thresholded_probabilistic_0.35/`). Each file = one nucleus; the file
  stem is the label, `_l`/`_r` denote laterality. Each map is
  182×218×182 @1 mm with an **sform identical to FSL `MNI152_T1_1mm`** — no
  resample is needed.
- The **IIT** dirs (`1a`/`1b`) are excluded (different template).

**Build (`build_bianciardi_dseg`)** — a streaming winner-take-all *argmax* over
the 86 prob maps, one volume loaded at a time (never all 86 at once), producing
an int16 dseg on the 182³ FSL grid plus a LUT.

**CRITICAL CORRECTION — overlap caveat and the hybrid decision.** Bianciardi is
an *overlapping* probabilistic atlas; a single-label dseg cannot represent
overlaps. A naive argmax fully overwrites 12 overlapping reticular-formation
nuclei, which end with **0 owned voxels**:

```
iMRtl_l iMRtl_r  iMRtm_l iMRtm_r  mRta_l mRta_r  mRtd_l mRtd_r  sMRtl_l sMRtl_r  sMRtm_l sMRtm_r
```

So the build is a **hybrid**:

1. the dseg holds the nuclei that own ≥1 voxel (74 of 86 in practice);
2. the LUT carries an `owned_voxels` column;
3. a sidecar `Bianciardi_MNI_overlay_nuclei.txt` lists every nucleus with
   `owned_voxels == 0`, and their thresholded-prob maps are copied into
   `derived/overlay/` as a per-nucleus **overlay set** — these are warped and
   analyzed individually rather than dropped.

Verified: 86 total nuclei → 74 own ≥1 voxel, 12 overlay (exactly the reticular
list above).

### CIT168 (no resample)

- Source: `tpl-MNI152NLin6Asym_atlas-CIT168_res-01_dseg.nii.gz`, a single dseg
  with 16 labels. Its sform is identical to FSL `MNI152_T1_1mm` — no resample.
- The 2009cAsym variant is ignored.
- The LUT is **0-indexed** (see the off-by-one note above); the split applies
  offset = 1.

### AAL3 (reorient + resample; off by default)

- Source: `AAL3v1_1mm.nii.gz`, a single dseg with 170 labels.
- **⚠️ stored NEUROLOGICAL** (sform `+x`, origin `−90`) on the **SPM grid**, NOT
  the FSL MNI152 grid (sform `−x`, origin `+90`). It must be reoriented and
  resampled onto the FSL grid before warping.

**Normalize (`normalize_aal3_to_fsl_mni`)**:

1. The atlas dir ships *both* `AAL3v1_1mm.nii` and `AAL3v1_1mm.nii.gz`; FSL
   refuses the ambiguous basename ("No image files match"), so the `.nii.gz`
   is first copied to an unambiguous staging name in `derived/`.
2. `fslreorient2std` → std radiological orientation.
3. `flirt -applyxfm -usesqform -interp nearestneighbour -ref MNI152_T1_1mm`
   resamples onto the FSL MNI152 grid with label-preserving NN interpolation.
   (`antsApplyTransforms -n GenericLabel -r MNI152_T1_1mm` is an equivalent
   alternative.)
4. **L-R flip sanity check**: compares the centre-of-gravity x of `Precentral_L`
   vs `Precentral_R`. In FSL radiological space the left hemisphere is at smaller
   x; a violation logs a WARNING. Verified: `Precentral_L` COG x = −38.4 < `_R`
   = +41.6 (not flipped); 0 fractional voxels (labels stayed integral).

AAL3 is whole-brain and **off by default** (`USE_AAL3=false`); when enabled only
its brainstem-relevant subset matters for this pipeline.

## Warp + split flow

`run_multi_atlas_brainstem <subject_t1> <basename> [flair]` orchestrates, per
enabled atlas:

1. **Ensure cached MNI dseg** — `build_bianciardi_dseg` / (CIT168 used as-is) /
   `normalize_aal3_to_fsl_mni`.
2. **One shared MNI→subject SyN registration** (`antsRegistrationSyN.sh -t s`,
   cached as `mni_to_subject_*`), mirroring `hierarchical_joint_fusion.sh`.
3. **Warp** each MNI dseg into subject space — `warp_atlas_dseg_to_subject`
   reuses `registration.sh:apply_transformation` with its `is_label=true` path
   (label-aware interpolation `GenericLabel`, configurable via
   `REG_LABEL_INTERPOLATION`), falling back to a direct `antsApplyTransforms`
   call (`-t warp -t affine -n GenericLabel`, the inverse/atlas→subject order).
   Bianciardi overlay prob maps are warped individually.
4. **Split** — `split_dseg_to_region_masks` writes per-region binary masks
   (`safe_fslmaths -thr v -uthr v -bin`). For Bianciardi, nuclei are additionally
   aggregated into the gross `midbrain`/`pons`/`medulla` (+ left/right)
   subdivisions via `_bianciardi_nucleus_subdivision`, named so
   `find_all_atlas_regions` discovers them (`*_left_pons.nii.gz`,
   `*_midbrain.nii.gz`, …) while nucleus-level masks
   (`bianciardi_<nucleus>_label<v>.nii.gz`) are also kept.

## Dispatch hook

`config/default_config.sh` documents the `BRAINSTEM_SEGMENTATION_METHOD`
values that trigger this path: **`multi_atlas`** and its alias **`bianciardi`**
(single-method), and the default **`all`** mode, in which the multi-atlas warp
runs as one of the concurrent parallel paths whenever `SEG_RUN_MULTI_ATLAS=true`
(the default). `segmentation.sh:extract_brainstem_final` always produces the
Harvard-Oxford gross extent first, then — for these methods (or in `all` mode
with the multi-atlas path enabled) — calls `run_multi_atlas_brainstem`. The
`freesurfer` and `atlas`/`harvard_oxford` single-method cases are unchanged; an
unknown value still falls back to the HO gross mask.

`multi_atlas.sh` is sourced by both `segmentation.sh` and `pipeline.sh`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_DIR` | `${FSLDIR}/data/atlases` | Atlas root |
| `MULTI_ATLAS_CACHE_DIR` | `${ATLAS_DIR}` | Cache root (`*/derived/` per atlas) |
| `USE_BIANCIARDI` | `true` | Enable Bianciardi |
| `USE_CIT168` | `true` | Enable CIT168 |
| `USE_AAL3` | `false` | Enable AAL3 (whole-brain; off by default) |
| `BIANCIARDI_PROB_THRESHOLD` | `0.35` | Matches the thresholded subdir name |
| `BIANCIARDI_MNI_SUBDIRS` | `2a…/2b…` | Bianciardi MNI source subdirs |
| `REG_LABEL_INTERPOLATION` | `GenericLabel` | Label-aware warp interpolation |
| `BRAINSTEM_SEGMENTATION_METHOD` | `freesurfer` | `multi_atlas`/`bianciardi` to enable |

## References

Method-specific references for the atlases and the labeling approach used here.

**Atlases**
- **Bianciardi BrainstemNavigator** — Bianciardi M, et al. *Toward an in vivo
  neuroimaging template of human brainstem nuclei of the ascending arousal,
  autonomic, and motor systems.* Brain Connect 2015;5(10):597-607. Toolkit v1.0
  release: Hannanu FF, et al., ISMRM 2025 #0950 (NITRC) — *conference abstract;
  treat as provisional.*
- **CIT168** — Pauli WM, Nili AN, Tyszka JM. *A high-resolution probabilistic
  in vivo atlas of human subcortical brain nuclei.* Sci Data 2018;5:180063.
- **AAL3** — Rolls ET, et al. *Automated anatomical labelling atlas 3.*
  NeuroImage 2020;206:116189.
- **Harvard-Oxford (gross extent baseline)** — Desikan RS, et al. NeuroImage
  2006;31(3):968-980 (Makris N, et al. 2006).

**Registration / label warping**
- **SyN** (the MNI→subject transform reused per atlas) — Avants BB, et al.
  *Symmetric diffeomorphic image registration with cross-correlation.* Med Image
  Anal 2008;12(1):26-41.

**Exploratory nucleus segmentation (not wired into multi-atlas split)**
- **AANSegment** (arousal-network nuclei; `brainstem_aanseg.sh`) — Olchanyi MD,
  et al. *Automated MRI segmentation of brainstem nuclei critical to
  consciousness.* Hum Brain Mapp 2025;46(14):e70357. *Caveat: ≤1 mm input only;
  CC BY-NC-ND; large-lesion-sensitive — exploratory.*

### Why argmax + an overlay set (not a single dseg)

A winner-take-all *argmax* collapses Bianciardi's *overlapping* probabilistic
prob maps into a single integer dseg, which is the natural representation for the
downstream per-region `safe_fslmaths -thr/-uthr` split. The trade-off is that a
single-label dseg cannot encode overlap, so the 12 overlapping reticular-formation
nuclei lose all voxels to neighbours; the hybrid build keeps those as an
individually-warped **overlay set** rather than dropping them (see *CRITICAL
CORRECTION* above). This argmax/maximum-probability rule for combining
overlapping probabilistic atlases is the standard label-fusion choice; the
multi-atlas-warp-then-combine rationale follows the general nonlinear-registration
and label-propagation literature (Avants 2008, above; Klein A, et al. *Evaluation
of 14 nonlinear deformation algorithms…* NeuroImage 2009;46(3):786-802).
