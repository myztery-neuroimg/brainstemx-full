# Multi-Atlas Brainstem Labeling Integration Spec

Status: implemented in `src/modules/multi_atlas.sh` (built-in atlases) and
`src/modules/atlas_registry.sh` (registry-driven extra atlases).

This document specifies how the BrainStemX pipeline integrates the three
built-in atlases — **Bianciardi BrainstemNavigator v1.0**, **CIT168**, and
**AAL3** — plus the **atlas registry** (JHU ICBM-DTI-81 pontine tracts, FSL
XTRACT, Harvard AAN v2, locus-coeruleus and dorsal-raphe maps, the NextBrain
MNI152 rendering, and any future MNI atlas as a config entry) to produce
nucleus-, tract- and gross-subdivision masks in subject T1 space, layered on
top of the Harvard-Oxford gross Brain-Stem extent. The FreeSurfer-side
counterpart (NextBrain tool wrapper) is described at the end.

**No atlas data is vendored in this repository.** Every atlas is referenced by
citation, licence and download location and must be obtained by the user under
its own licence; the pipeline only reads them from `ATLAS_DIR`.

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

The overlay nuclei are warped individually AND exposed as their own region
masks `bianciardi_<nucleus>_label10NN.nii.gz` (the 1000+ "overlay" label range)
in `detailed_brainstem/`, so per-region detection analyses them instead of
silently dropping them.

### Consensus with many correlated atlases

Every registry key is one more source tag. Because atlas priors are
correlated (Bianciardi, AAN, the LC atlas and NextBrain all label the LC; JHU
and XTRACT both label the CST), the cross-source consensus counts one vote per
source **family** by default (`CONSENSUS_VOTE_BY=family`,
`CONSENSUS_SOURCE_FAMILIES`): `atlas`, `freesurfer` (FS parcels + NextBrain),
`harvard_oxford`, `synthseg`. Regions below `ANALYSIS_MIN_REGION_VOXELS` are
logged in `per_region_analysis/region_skips.tsv`.

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

## Atlas registry (extra MNI atlases as config entries)

`src/modules/atlas_registry.sh` (sourced by `multi_atlas.sh`) removes the need
to touch code when adding an MNI-space atlas. `run_multi_atlas_brainstem`
fans out to `run_registry_atlases` after the built-ins, reusing the **same
shared MNI→subject SyN warp**; each key ends as
`segmentation/detailed_brainstem/<key>_<name>_label<value>.nii.gz` masks (+
optional `<key>_pons.nii.gz`-style aggregates), a subject-space dseg
`segmentation/multi_atlas/<key>_in_subject.nii.gz`, a per-key
`<key>_provenance.tsv`, a `<key>_region_volumes.tsv` sidecar and a
fsleyes view script.

### Configuration model

```
MULTI_ATLAS_EXTRA="jhu xtract aan lc dr nextbrainmni"   # registry keys (lower-case tags)
USE_<KEY>=true|false
ATLAS_<KEY>_REL         dir relative to ATLAS_DIR
ATLAS_<KEY>_TYPE        dseg | prob4d | probdir | probmap
ATLAS_<KEY>_IMAGE       image file / dir (relative to REL, or absolute)
ATLAS_<KEY>_LUT         FSL atlas .xml | FreeSurfer colour LUT | "idx name" txt
ATLAS_<KEY>_LUT_FORMAT  auto | xml | freesurfer | txt
ATLAS_<KEY>_LUT_OFFSET  auto | 0 | 1          (image value = LUT index + offset)
ATLAS_<KEY>_SPACE       MNI152NLin6Asym (FSL MNI152, default) | MNI152NLin2009[abc]Asym
ATLAS_<KEY>_XFM         explicit ANTs transform chain into NLin6 (any source space)
ATLAS_<KEY>_PROB_THR    threshold for prob* types (default 0.25)
ATLAS_<KEY>_LABELS      subset: LUT indices or names
ATLAS_<KEY>_LABEL_REGEX case-insensitive name selector (whole-brain atlases)
ATLAS_<KEY>_RESTRICT    brainstem | none  (REQUIRED for whole-brain tract atlases)
ATLAS_<KEY>_SUBDIV      "<name_prefix>=<pons|midbrain|medulla> ..." aggregation
ATLAS_<KEY>_DILATE      dilate tiny nuclei n voxels in subject space (core kept as *_core)
ATLAS_<KEY>_URL / _CITATION / _LICENSE   informational (availability report, provenance)
MULTI_ATLAS_SOURCE_TAGS derived: "bianciardi cit168 aal3 ${MULTI_ATLAS_EXTRA}"
```

`MULTI_ATLAS_SOURCE_TAGS` (plus `SEG_TOOL_SOURCE_TAGS`, default `nextbrain`)
is the **single list** that `analysis.sh` (discovery globs, provenance,
consensus), `reporting.sh`/`reporting_tables.py` (source classification, run
manifest) and `visualization*.sh` (overlays, viewer layers) iterate over — a
new key needs no downstream edit.

### Types and builders

| TYPE | Input | Build | Example |
|---|---|---|---|
| `dseg` | one label image + LUT | LUT normalised to "value name" (`atlas_lut_to_tsv`) | JHU labels, AAN v2, NextBrain-MNI |
| `prob4d` | 4D probability atlas (volume *i* = LUT index *i*) | thresholded streaming argmax → value *i*+1 | XTRACT |
| `probdir` | one probability map per structure | thresholded argmax + overlay set for fully-overlapped structures (Bianciardi rule) | per-nucleus bundles |
| `probmap` | single probability/binary map | `-thr -bin` → label 1 | LC, dorsal raphe |

### LUT offsets (the FSL convention trap)

FSL atlas XMLs come in two flavours: `<type>Label</type>` (JHU labels: XML
`index` **is** the voxel value, index 0 = "Unclassified") and
`<type>Probabilistic</type>` (XTRACT / Harvard-Oxford: the maxprob summary
image is `index + 1`). `_atlas_lut_offset` applies 0 / 1 respectively (or the
explicit `ATLAS_<KEY>_LUT_OFFSET`); `atlas_lut_to_tsv` then writes **image
values**, so the downstream `split_dseg_to_region_masks` offset heuristic sees
`min ≥ 1` and adds nothing. FreeSurfer colour LUTs ("idx Name words R G B A")
are auto-detected and their multi-word names joined with `_`.

### Template space (the silent-misregistration trap)

The pipeline's shared warp is computed against FSL `MNI152_T1_1mm`
(MNI152NLin6Asym). Atlases released on the ICBM 2009a/b/c nonlinear grids are
**not** on that grid. The registry brings them into NLin6 with the TemplateFlow
image transform `tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5`
(`MNI_2009C_TO_NLIN6_XFM`, `TEMPLATEFLOW_HOME`, or `ATLAS_DIR/templateflow/`;
download from `https://templateflow.s3.amazonaws.com/tpl-MNI152NLin6Asym/`).
2009a/b/c share one nonlinear average and differ only in grid/FOV, so the same
transform applies to all three. When the transform is absent the atlas is
**skipped with a WARNING** — never warped through the wrong template. Other
source spaces (e.g. the linear MNIavg152 grid of the Dahl 2022 LC meta-mask)
use `ATLAS_<KEY>_XFM` with the transform chain the atlas ships. Same-space
atlases on a different grid (0.5 mm, 2 mm) are resampled onto the 1 mm grid
(NN for labels, trilinear for probabilities).

### Brainstem restriction

Whole-brain tract atlases (JHU, XTRACT) would flood brainstem per-region
detection with supratentorial voxels (the corticospinal tract runs to the
cortex). `ATLAS_<KEY>_RESTRICT=brainstem` intersects the MNI dseg with the
Harvard-Oxford Brain-Stem label (value 8, `HO_SUB_MAXPROB_THR`, dilated one
voxel, cached under `HarvardOxford/derived/`) **before** warping; if HO is
absent the atlas is skipped rather than admitted unrestricted.

### Tiny nuclei

`analysis.sh` skips regions with < 50 brain voxels. The locus coeruleus is
~20 voxels at 1 mm, the dorsal-raphe mask ~32 mm³. `ATLAS_<KEY>_DILATE=1`
dilates the subject-space mask once (an "LC neighbourhood"); the undilated mask
is kept as `*_core.nii.gz` (excluded from discovery). Treat statistics on such
regions as exploratory.

### Registry atlases shipped in `config/default_config.sh`

| key | atlas | space | type | pons content | obtain | licence |
|---|---|---|---|---|---|---|
| `jhu` | JHU ICBM-DTI-81 WM labels (Mori 2005; Hua 2008) | NLin6 1 mm | dseg | MCP, pontine crossing tract, CST, medial lemniscus, ICP/SCP, cerebral peduncle (labels 1,2,7–16) | ships with FSL (`JHU/`) | FSL |
| `xtract` | XTRACT HCP tract atlas (Warrington 2020) | NLin6 1 mm | prob4d (thr 0.30) | CST L/R (15/16), MCP (35) | ships with FSL ≥ 6.0.4 (`XTRACT/`) | FSL |
| `aan` | Harvard Ascending Arousal Network v2.0 (Edlow 2024) | MNI152 1 mm | dseg + FreeSurfer LUT | LC, PBC, PnO, LDTg, MnR, PTg (+ DR, PAG, VTA, mRt) | Dryad doi:10.5061/dryad.zw3r228d2 → `AAN/` | Dryad |
| `lc` | Locus coeruleus probability map (Ye 2021 7T; alt. Dahl 2022 meta-mask) | ICBM 2009b asym 0.5 mm (Ye, verified) / linear MNI (Dahl, use `ATLAS_LC_XFM`) | probmap (`LC*prob*.nii*` glob), dilate 1 | LC | NITRC `lc_7t_prob` (free NITRC login required for the zip) / OSF `sf2ky` → `LC/` | CC BY-NC-ND 4.0 (Ye) / CC BY 4.0 (Dahl) |
| `dr` | Dorsal raphe supratrochlear mask (Wearn 2024) | 2009b | probmap, dilate 1 | DR | Zenodo 10680563 → `DorsalRaphe/` | CC BY 4.0 |
| `nextbrainmni` | NextBrain whole-brain atlas rendered on MNI152 1 mm (496 ROIs) | NLin6 1 mm | dseg + FreeSurfer LUT, name regex | pontine nuclei, LC, raphe, reticular formation, lemnisci, peduncles, cranial-nerve nuclei | github.com/compneurobilbao/nextbrain-mni-atlas → `NextBrain/` | see repo / NextBrain |

All default **on** and cost nothing when the files are absent (the startup
atlas check prints a per-key present/absent line with the download hint).

### Adding an atlas

1. Put the files under `$ATLAS_DIR/<REL>/`.
2. Add a key to `MULTI_ATLAS_EXTRA` and its `ATLAS_<KEY>_*` block to config
   (or export them in the environment).
3. Nothing else — discovery, provenance, reporting and visualisation follow
   the tag list. Unit tests: `tests/test_atlas_registry_unit.sh`.

## NextBrain histological atlas (FreeSurfer tool)

`src/modules/brainstem_nextbrain.sh` wraps FreeSurfer 8's
`mri_histo_atlas_segment_fireants` (Casamitjana et al., *Nature* 2025; fast
version Puonti et al., *Imaging Neuroscience* 2026;
fswiki/HistoAtlasSegmentation): Bayesian, contrast-agnostic segmentation of
~300 ROIs per hemisphere **directly from the T1 (no recon-all)** in 15–30 min
per side on CPU. The wrapper runs both sides with stdin closed (the first-run
atlas-download prompt fails fast instead of hanging — run the tool once
interactively to fetch the atlas), resamples `seg.<side>.nii.gz` (0.4 mm) onto
the subject grid, keeps the brainstem labels selected by
`NEXTBRAIN_LABEL_REGEX` on `lut.txt`, and writes
`detailed_brainstem/nextbrain_<name>_<l|r>_label<v>.nii.gz` (source tag
`nextbrain`). In `all` mode it is one more parallel path
(`SEG_RUN_NEXTBRAIN`, `BRAINSTEM_NEXTBRAIN_ENABLED`, both default on, no-op
when the tool or licence is absent). Outputs and provenance live under
`segmentation/nextbrain/`. Unit tests: `tests/test_nextbrain_unit.sh`.

Caveat: histology-derived priors are not lesion-validated; large brainstem
lesions can distort the Bayesian fit. Treat NextBrain nuclei as corroborating
anatomy.

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

**Registry atlases**
- **JHU ICBM-DTI-81** — Mori S, et al. *MRI Atlas of Human White Matter.*
  Elsevier 2005; Hua K, et al. *Tract probability maps in stereotaxic spaces.*
  NeuroImage 2008;39(1):336-347.
- **XTRACT** — Warrington S, et al. *XTRACT — Standardised protocols for
  automated tractography in the human and macaque brain.* NeuroImage
  2020;217:116923.
- **Harvard AAN atlas v2.0** — Edlow BL, et al. *Sustaining wakefulness:
  Brainstem connectivity in human consciousness.* Sci Transl Med
  2024;16(745):eadj4303 (Dryad doi:10.5061/dryad.zw3r228d2); v1: Edlow BL, et
  al. J Neuropathol Exp Neurol 2012;71(6):531-546.
- **Locus coeruleus** — Ye R, et al. *An in vivo probabilistic atlas of the
  human locus coeruleus at ultra-high field.* NeuroImage 2021;225:117487
  (NITRC `lc_7t_prob`, ICBM 2009b 0.5 mm); Dahl MJ, et al. *Locus coeruleus
  integrity is related to tau burden and memory loss in autosomal-dominant
  Alzheimer's disease.* Neurobiol Aging 2022 / LC meta-mask OSF `sf2ky`.
- **Dorsal raphe mask** — Wearn AR, et al. Zenodo 2024,
  doi:10.5281/zenodo.10680563 (ICBM 2009b; CC BY 4.0).
- **NextBrain** — Casamitjana A, et al. *A probabilistic histological atlas of
  the human brain for MRI segmentation.* Nature 2025; Puonti O, et al. *Fast
  segmentation with the NextBrain histological atlas.* Imaging Neuroscience
  2026. MNI152 rendering: github.com/compneurobilbao/nextbrain-mni-atlas.
- **TemplateFlow** (template-to-template transforms) — Ciric R, et al.
  *TemplateFlow: FAIR-sharing of multi-scale, multi-species brain models.*
  Nat Methods 2022;19:1568-1571.

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
