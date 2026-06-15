# brainstemx-full: Brainstem/Pons MRI Analysis Pipeline

BrainStem X (_Brainstem/Pons specific_ intensityclustering implementation) is an end-to-end pipeline designed for precise analysis of subtle T2/FLAIR hyperintensity/T1 hypointensity clusters in these critical brain neuroanatomical regions. Brainstem regions can present clinically with very subtle variations below the clinical threshold to human radiologists and standard research methods. This pipeline tries to address some the  challenges via

- **Multi-modal integration** across T1/T2/FLAIR/SWI/DWI sequences with cross-modality anomaly detection
- **N4 Bias Field AND slice-acquisiton** correction (e.g., SAG-acquired FLAIR sequences).
- **Precise orientation preservation** critical for analyzing directionally sensitive brainstem microstructure
- **Zero-shot/unsupervised cluster analysis** which could identify signal anomalies without manual segmentation or human false negative biases
- **Multiple fallback methods** at various steps, activated by quantitative quality metrics, adding robustness to results even with suboptimal slice thickness, modalities and IPR
- **DICOM backtrace capability** for clinical validation of findings in native scanner format
- **Parallel processing** of subjects and optimisation of multithreaded performance and standardised outputs to support larger cohort analysis
- **Modern approach** Attempts to take modern non-ML analytics approaches as of 2023/2024 and combine them, see https://github.com/myztery-neuroimg/brainstemx-full/blob/main/docs/sota-comparison.md 

<image width="400" alt="Simulated Hyperintensity Cluster on T2-SPACE-FLAIR" src="https://github.com/user-attachments/assets/5dc95c74-e270-47cf-aad5-9afaf70c85c1" />

<img width="540" alt="Simulated Cluster Summary Table " src="https://github.com/user-attachments/assets/72f2f11f-b19c-41bc-8eda-10997b2e96eb" />

## Project status

The project is in active development as of October 2025. Whilst many improvements are in the works, we hope it already offers some helpful functionality. Future works including a platform portable docker implementation via neurodocker.

For a minimal pure-python implemention with synthetic data generation, LLM report generation and a web-ui, refer to https://github.com/myztery-neuroimg/brainstemx (currently a very immature implementation and work in progress).

## Recent Segmentation Improvements (June 2025)
- Corrected Harvard-Oxford atlas selection: now uses only brainstem index 7, eliminating erroneous multi-index summation.
- Improved MNI→native space transformation: switched to trilinear interpolation + 0.5 thresholding, preserving partial volumes.
- Consistent file naming: updated pipeline and modules to use `_brainstem.nii.gz` and `_brainstem_flair_intensity.nii.gz` uniformly.
- Updated Juelich pons segmentation: applied same interpolation fix, yielding anatomically reasonable voxel counts.
- Integrated FLAIR enhancement: generated separate FLAIR intensity masks for segmentation quality analysis.

## Parallel Multi-Method Segmentation, Multi-Atlas Labeling & Optional Modules

The default brainstem-segmentation mode is now **`BRAINSTEM_SEGMENTATION_METHOD=all`**: every enabled path runs as a **concurrent parallel path** and downstream per-region detection analyses the **union** of all masks they produce. The fast paths (Harvard-Oxford gross extent + multi-atlas warp, minutes) run side-by-side with the multi-hour FreeSurfer recon-all; each path is independent and **non-fatal** (a failed/skipped path logs a WARNING and never kills the others or the pipeline), and the shared MNI→subject SyN transform is computed once up front and reused. Per-path toggles `SEG_RUN_HARVARD_OXFORD` / `SEG_RUN_MULTI_ATLAS` / `SEG_RUN_FREESURFER` / `SEG_RUN_SYNTHSEG` (all default ON) drop individual paths — e.g. `SEG_RUN_FREESURFER=false` keeps the fast HO + multi-atlas paths and skips recon-all. The single-method values (`freesurfer`, `atlas`/`harvard_oxford`, `multi_atlas`/`bianciardi`) remain mutually exclusive and behave exactly as before. Each path's masks are provenance-tagged (`per_region_analysis/region_provenance.tsv`) so the reporting layer can attribute every region to its source method.

- **Multi-atlas brainstem labeling** (`BRAINSTEM_SEGMENTATION_METHOD=multi_atlas`/`bianciardi`, `multi_atlas.sh`) — warps the **Bianciardi BrainstemNavigator v1.0** (nucleus-level), **CIT168** subcortical, and (off-by-default) **AAL3** atlases into subject T1 space via one shared SyN→MNI registration plus label-aware `GenericLabel` interpolation, producing per-region masks the existing per-region GMM detection consumes directly. See [docs/multi_atlas_integration_spec.md](multi_atlas_integration_spec.md).
- **FreeSurfer full-recon harvest + ML methods** (`freesurfer_harvest.sh`) — recon-all is paid for **once**; the harvest then extracts the rest of its output (aseg/wmparc/aparc + `aparc.a2009s` stats, eTIV, optional thalamic / hypothalamic / hippo-amygdala subregions) with **no second recon**. Aseg/SynthSeg CSF + 4th-ventricle masks feed the FP-exclusion path. Fast contrast/resolution-agnostic ML methods run directly on a clinical/2D T1 with no recon: **SynthSeg+** (`mri_synthseg --robust`, default on), **SynthSR** (`mri_synthsr`, optional 1 mm T1 synthesis pre-step), and **sclimbic** (`mri_sclimbic_seg`, gated). Cheap harvests default ON; the multi-hour/extra-time pieces default OFF.
- **Atlas-availability check** — a startup `check_atlas_availability` step reports which atlases are present under `$FSLDIR/data/atlases` and warns if the selected method needs a missing one; absence is **non-fatal** (the pipeline degrades to the Harvard-Oxford gross mask).
- **Optional supervised / deep-learning WMH modules**, each intersected with the brainstem mask: FSL **BIANCA** (`wmh_bianca.sh`), **LST-AI + FreeSurfer SAMSEG** (`wmh_lst_samseg.sh`), **WMH-SynthSeg** (`wmh_synthseg.sh`), **segcsvdWMH** (`wmh_segcsvd.sh`), **SHIVA-WMH** (`wmh_shiva.sh`), and **MARS-WMH** (`wmh_mars.sh`). Each is self-gated — a no-op WARNING+skip until its tool/model/training data is present — so an enabled master switch is harmless until the tool is installed.
- **AANSegment** (`brainstem_aanseg.sh`) — **exploratory** FreeSurfer arousal-network nuclei segmentation (≤1 mm input only; large-lesion-sensitive).
- **Post-detection false-positive filter** (`fp_filter.sh`) — config-gated FP suppression that operates *after* detection, complementing the CSF/partial-volume exclusion that runs *before* thresholding. Lossy (removes true small lesions) — kept OFF by default for the brainstem.

> ⚠️ **None of the optional WMH/lesion modules is validated in the brainstem/pons.** All published WMH/lesion SOTA is supratentorial; the posterior fossa is repeatedly "under-evaluated", and Ryu et al. 2025 find DL segmentation "relatively poor" in the brainstem. Treat every optional module as exploratory, keep conservative pons QA with a human in the loop, and locally validate any tool before relying on it. These add-ons only **corroborate** — none alters the primary per-region-GMM FLAIR detection.

## Multi-Modal Corroboration (SWI / DWI / T2 end-to-end)

Beyond the T1/FLAIR backbone, the pipeline brings the **secondary** T2-weighted modalities — SWI magnitude, the DERIVED DWI **trace** + **ADC** (not raw 4D diffusion), and a true T2 — all the way through, **only when they are present** (a T1+FLAIR-only study is byte-identically unchanged; the toggles default ON precisely because they are no-ops in the absence of the relevant series).

- **Contrast-matched cascaded registration** (`registration.sh:register_contrast_matched_cascade`, `CONTRAST_MATCHED_REGISTRATION=true`) anchors each T2-weighted secondary to its nearest same-contrast 3D structural rather than directly to T1: the cascade is `T1 ← FLAIR ← {T2, DWI, ADC, SWI}` (anchors set by `CONTRAST_ANCHOR_MAP`). Each secondary's transform is **composed** with the FLAIR→T1 transforms so it reaches T1/MNI in a single `antsApplyTransforms` application (no double interpolation); both the composed **forward and inverse** transform lists are persisted.
- **Cross-modal corroboration** (`cross_modal_analysis.sh`, `CROSS_MODAL_ANALYSIS_ENABLED=true`) samples each co-registered secondary inside every PRIMARY FLAIR cluster ROI and flags **DWI restriction** (trace ↑ AND ADC ↓ → acute/ischemic), **SWI hypointensity** (→ hemorrhage/microbleed), and **T2 hyperintensity** (→ corroborates FLAIR). Each modality is z-scored within the brainstem ROI so the thresholds (`CROSS_MODAL_*_Z`) are scanner-independent. This is corroboration **on top of** the primary detection — it never re-detects lesions and never alters the primary mask. Outputs a per-cluster table + summary under `analysis/cross_modal/`.

## Output & Reporting Layer

A final **reporting** stage (Step 8.5, `reporting.sh`, after analysis/QA/viz) aggregates every merged capability over the **canonical results tree**. It **discovers** outputs wherever modules wrote them and emits, all gated/graceful/idempotent (a minimal T1+FLAIR run still produces a valid smaller report; absent sections render as "No data" and are recorded `absent` in the run manifest):

- **Summary tables** under `reports/tables/`, each as **CSV/TSV + HTML**: `hyperintensity_per_region`, `wmh_tool_volumes`, `segmentation_volumes` (HO / FS / multi-atlas / SynthSeg-aseg / subregions), `cross_modal`, `freesurfer_morphometry` (aseg volumes + eTIV), and a `run_manifest`; plus a machine-readable `manifest.json`.
- **Report visualizations** under `visualizations/` — per-method segmentation overlays, hyperintensity clusters on FLAIR, and a multi-modal montage (FLAIR/DWI/SWI/T2).
- **Top-level report** `reports/brainstemx_report.html` (+ `.md` fallback) — a one-stop dashboard embedding all populated tables, the run manifest, and the discovered visualizations.

Governed by `REPORTING_ENABLED` (default `true`); report visualizations honour `SKIP_VISUALIZATION`. Full tree + table schemas: [docs/output_structure.md](output_structure.md).

## Recent advances & roadmap (2024–2026)

This section situates BrainStem X against the 2024–2026 literature and records the methods we have wired in (or are evaluating) and the honest caveats. Items marked **[preprint]** / **[provisional]** are not peer-reviewed or have no released code, and are cited with that caveat.

**Brain extraction.** SynthStrip (Hoopes et al., NeuroImage 2022;260:119474) is the contrast-agnostic primary, falling back to ANTs and BET (Smith, Hum Brain Mapp 2002;17(3):143-155); HD-BET (Isensee et al., Hum Brain Mapp 2019;40(17):4952-4964) is a possible alternative.

**Denoising / bias correction.** N4ITK (Tustison et al., IEEE TMI 2010;29(6):1310-1320) for bias; adaptive Rician NLM (Manjón et al., JMRI 2010;31(1):192-203) for structural; MP-PCA `dwidenoise` (Veraart et al., NeuroImage 2016;142:394-406) and Gibbs unringing (Kellner et al., MRM 2016;76(5):1574-1581) for DWI; Patch2Self2 (Fadnavis et al., CVPR 2024) and DeepN4 (Kanakaraj et al., Neuroinformatics 2024;22:193-205, T1-only) are candidate upgrades. FLAIR N4 is deliberately gentle because bias correction can absorb diffuse lesion contrast under high lesion load (Valdés Hernández et al., 2016, PMC4846712).

**Registration.** SyN (Avants et al., Med Image Anal 2008;12(1):26-41), benchmarked against the classic nonlinear-registration evaluation (Klein et al., NeuroImage 2009;46(3):786-802). Learned registration is maturing: SynthMorph (Hoffmann et al., Imaging Neuroscience 2024;2:1-33), uniGradICON (Tian et al., MICCAI 2024), and the LUMIR/Learn2Reg 2024 benchmark **[preprint, arXiv:2505.24160]**.

**Segmentation / atlases.** FreeSurfer brainstem substructures (Iglesias et al., NeuroImage 2015;113:184-195; Fischl, NeuroImage 2012;62(2):774-781) and Harvard-Oxford (Desikan et al., NeuroImage 2006;31(3):968-980) are the defaults; the multi-atlas path adds Bianciardi (Bianciardi et al., Brain Connect 2015;5(10):597-607; Toolkit v1.0 **[conference abstract]** Hannanu et al., ISMRM 2025 #0950), CIT168 (Pauli, Nili & Tyszka, Sci Data 2018;5:180063), and AAL3 (Rolls et al., NeuroImage 2020;206:116189). Talairach has been **removed** (single 1988 post-mortem brain; the MNI↔Talairach disparity, Lancaster et al. 2007, PMC2856713, is worst exactly inferiorly/posteriorly — i.e. in the brainstem). Contrast-agnostic learned segmentation is on the radar: SynthSeg (Billot et al., Med Image Anal 2023;86:102789), SynthSR (Iglesias et al., Sci Adv 2023;9(5):eadd3607); brainstem-specific DL includes AANSegment (Olchanyi et al., Hum Brain Mapp 2025;46(14):e70357) and MARS/dl-brainstem (Gesierich et al., Hum Brain Mapp 2025;46(3):e70141). Tissue priors via FSL FAST (Zhang et al., IEEE TMI 2001;20(1):45-57) or Atropos (Avants et al., Neuroinformatics 2011;9(4):381-400).

**WMH / lesion detection.** Optional back-ends: BIANCA (Griffanti et al., NeuroImage 2016;141:191-205), LST-AI (Wiltgen et al., NeuroImage: Clinical 2024;42:103611), SAMSEG lesions (Cerri et al., NeuroImage 2021;225:117471), segcsvdWMH (Gibson et al., Hum Brain Mapp 2024;45(18):e70104), SHIVA-WMH (Tran et al., Hum Brain Mapp 2024;45(1):e26548), MARS-WMH (Gesierich et al., Cereb Circ Cogn Behav 2025;9:100393), and WMH-SynthSeg (Laso et al., IEEE ISBI 2024; arXiv:2312.05119). Further context: DeepWMH (Liu et al., Science Bulletin 2024;69(7):872-875), normative/generative anomaly detection (Bercea et al., Nat Commun 2025;16:1624), the WMH methods review (Rahmani et al., Brain Imaging Behav 2024;18:1310-1322), and benchmarks (Wu et al., J Imaging Inform Med 2026; DELCODE, Front Psychiatry 2023;13:1010273; Martersteck et al., Alzheimer's & Dementia 2025; WMH Segmentation Challenge, Kuijf et al., IEEE TMI 2019;38(11):2556-2568).

**Infratentorial false positives (CSF pulsation).** The dominant brainstem FP source. Review of CSF-flow artifacts (Pai et al., Insights into Imaging 2025;16:288); the peri-CSF pseudolesion class (Bawil et al., BioMed Eng OnLine 2026;25:69); acquisition-side fix C-FLAIR (Graf et al., Radiology 2025;317(2)); joint ventricle×WMH modelling (SegAE, Atlason et al., PLOS ONE 2022;17(8):e0274212); the small-lesion-removal caveat (Molchanova et al., 2024, **[preprint, arXiv:2507.12092]**); and the brainstem reality check (Ryu et al., Sci Rep 2025;15:13214).

**Standards.** McDonald 2024 (Montalban et al., Lancet Neurol 2025;24(10):850-865), MAGNIMS-CMSC-NAIMS 2024 (Barkhof et al., Lancet Neurol 2025;24(10):866-879), and STRIVE-2 (Duering et al., Lancet Neurol 2023;22(7):602-618).

**Roadmap caveats (read these).**
1. **No method is validated in the brainstem/pons.** Every cited WMH/segmentation tool was evaluated supratentorially; the posterior fossa is repeatedly "under-evaluated" and Ryu 2025 finds DL "relatively poor" there. Any adopted tool needs local brainstem validation; we keep conservative pons QA / human-in-the-loop.
2. **3D-FLAIR acquisition is the single biggest lever** for infratentorial specificity — a high-quality isotropic 3D-FLAIR helps more than any post-processing step we could add.
3. **Per-region GMM thresholding in the brainstem is a genuine published gap** (no 2024–2026 precedent we could find). That is simultaneously this project's novelty *and* a lack-of-external-validation caveat: the approach is unproven against an established brainstem reference.

## Features

### Acquisition-Specific Processing and Registration
- Orientation standardization
  - Uses `fslswapdim` + `fslorient` then ANTs transform to enforce RAS orientation
  - Fallback for missing/ambiguous header fields via header-driven heuristics in `src/modules/preprocess.sh`
- Modality-aware denoising
  - T1/T2/FLAIR → iterative patch-based Rician NLM via `antsDenoiseImage` tuned by local variance; DWI → MP-PCA (`dwidenoise`, MRtrix); SWI/TOF skipped
  - Full DWI preprocessing path (`dwi_preprocess.sh`: dwidenoise → optional Gibbs → bias correction), gated by `PROCESS_DWI`
  - Auto-switch to FSL SUSAN for structural NLM when ANTs binaries are unavailable or memory-constrained
- Metadata-driven parameter tuning
  - Python metadata extractor reads DICOM tags to set N4 smoothing and denoising patch sizes dynamically
  - Ensures consistency across scanners/field strengths without manual config
- Multi-stage ANTs registration
  - Rigid → Affine → SyN with subject-specific mask weighting from white-matter segmentation (`src/modules/registration.sh`)
  - Template resolution automatically chosen based on voxel size; two-pass registration for submillimeter accuracy
  - Emergency fallback to SyNQuick or FSL FLIRT when MI/CC drops below QA thresholds
- White-matter guided initialization
  - Builds a WM mask via FSL FAST and uses it to bias initial transform for improved pons alignment
- Comprehensive hyperintensity clustering
  - Per-subject z-score thresholding on FLAIR intensities, minimum cluster-size filter, morphological closing
  - 3-plane confirmation to eliminate spurious outliers
  - DICOM backtrace JSON mapping results into original scanner coordinates for PACS validation

### Advanced Segmentation
- **FreeSurfer brainstem substructures** (Iglesias 2015 `segmentBS`/`brainstemSsLabels`) for the detailed subdivision into midbrain / pons / medulla / SCP, run by default (the `all` mode runs them alongside the other paths; also selectable as the single-method `BRAINSTEM_SEGMENTATION_METHOD=freesurfer`)
- **Harvard-Oxford subcortical atlas** (index 7, tightened to `maxprob-thr25`) used only for the gross brainstem extent mask and as the FreeSurfer fallback
- **Atlas-to-subject transformation** preserving native resolution by bringing the MNI HO atlas to subject space; FreeSurfer segments the subject's own T1 directly
- **Subject-specific brainstem refinement** using tissue segmentation to address shape variance in pathological cases
- **FLAIR integration** for enhanced multi-modal segmentation with intensity information
- Quantified "quality assessment" of the brain extraction, registration quality and segmentation accuracy with an extremely "over-the-top" QA module

### Cluster Analysis
- Statistical hyperintensity detection with multiple threshold approaches (1.5-3.0 SD, or whatever you want to configure, from the baseline intensity, and also whatever minimum size).
- Cross-modality cluster overlap quantification across MRI sequences
- Smoothing of white-matter regions so you don't just pick up spotty outlier pixels
- Cross-plane confirmation:- validate via axial, sagital and coronal views that what you're seeing is a real cluster of hyperintense pixels on FLAIR
- Pure quantile-bassd anomaly detection specific to subject, independent of manual labelling bias associated with deep learning models
- This means you can manipulate DICOM files to add clusters, hyperintensities/hypointensities and manually validate the _process_ - every step of its decision making - rather than it being a "black box"

### Technical Implementation

#### Preprocessing (preprocess.sh)
- **RAS/LPS orientation enforcement** with header-heuristic fallback for missing/ambiguous DICOM orientation fields
- **Modality-aware denoising** with Rician NLM for T1/T2/FLAIR, MP-PCA (`dwidenoise`) for DWI, and SWI/TOF skipped; automatic patch selection based on local image variance and noise characteristics
- **N4 bias-field correction** where field strength adjusts the b-spline mesh / spline distance (`-b`); FLAIR uses a gentler, lesion-aware preset so diffuse lesion contrast is not absorbed into the bias field
- **Brain extraction** via SynthStrip (FreeSurfer `mri_synthstrip`, contrast-agnostic) primary, with an automatic SynthStrip → ANTs(Otsu) → BET fallback chain, a shared `robustfov` neck-removal pre-step, modality-specific BET `-f`, and a posterior-fossa QC gate (`BRAIN_EXTRACTION_METHOD`)
- **Scanner metadata parameter optimization** automatically adjusts processing parameters based on field strength, vendor, and acquisition settings

#### Registration Pipeline (registration.sh)
- **Template & resolution detection** automatically selects MNI152 or custom atlas templates based on input voxel dimensions
- **Multi-resolution registration stages** with white-matter mask weighting for improved anatomical correspondence
- **Modality-aware SyN metric** Mutual Information for cross-modality (FLAIR↔T1), cross-correlation for same-modality, with `--winsorize-image-intensities`; atlases/masks warped with label-aware `GenericLabel` interpolation
- **Emergency fallback triggers** using quantitative QA metrics (mutual information, cross-correlation thresholds) to switch methods
- **Transform validation** outputs detailed QA plots and metrics for each registration stage with comprehensive error handling

#### Enhanced Validation & Hyperintensity Analysis (enhanced_registration_validation.sh)
- **Extended registration metrics** including cross-correlation, normalized mutual information, and histogram skewness analysis
- **Coordinate-space and file-integrity checks** performed before each major processing step with detailed error reporting
- **Regional intensity mask creation** over the Harvard-Oxford gross brainstem extent and the FreeSurfer brainstem substructures
- **Comprehensive cluster analysis** with volume quantification, morphological characterization, and interactive HTML visualization
- **DICOM coordinate backtrace** maintains mapping between processed results and original scanner coordinate systems

#### DICOM Import & Data Management (import.sh)
- **Vendor-agnostic DICOM conversion** with dcm2niix using scanner-specific optimization flags for Siemens/Philips/GE systems
- **Maximum data preservation** approach prevents slice loss through multiple fallback conversion strategies and series-by-series processing
- **Intelligent deduplication control** permanently disabled to prevent accidental removal of unique slices with safety checks for different series
- **Metadata extraction pipeline** extracts scanner parameters, field strength, and acquisition settings for downstream parameter optimization
- **Parallel DICOM processing** with GNU parallel for multi-series datasets and automatic series detection

#### Intelligent Scan Selection (scan_selection.sh)
- **Multi-modal quality assessment** evaluates file size, dimensions, voxel isotropy, and tissue contrast for optimal scan selection
- **ORIGINAL vs DERIVED acquisition detection** from DICOM metadata with significant scoring bonus for original acquisitions
- **Registration-optimized selection modes** including aspect ratio matching, dimension matching, and resolution-based selection
- **Interactive scan selection interface** with detailed comparison tables showing quality metrics, acquisition types, and recommendations
- **Cross-sequence compatibility analysis** calculates voxel similarity and aspect ratio matching between T1/FLAIR sequences

#### Advanced Brain Extraction & Standardization (brain_extraction.sh)
- **SynthStrip-primary extraction** (FreeSurfer `mri_synthstrip`, contrast-agnostic) with an automatic SynthStrip → ANTs(Otsu) → BET fallback chain, a shared `robustfov` neck-removal pre-step, modality-specific BET `-f` (T1 0.3 / FLAIR 0.2), and a posterior-fossa QC gate; selected via `BRAIN_EXTRACTION_METHOD`
- **3D isotropic sequence detection** automatically identifies MPRAGE, SPACE, VISTA sequences to prevent quality degradation from multi-axial combination
- **Enhanced resolution quality metrics** considers voxel anisotropy, total volume, and in-plane resolution for optimal processing path selection
- **Multi-axial template construction** combines SAG/COR/AX orientations using antsMultivariateTemplateConstruction2.sh for 2D sequences
- **Smart dimension standardization** with optimal resolution detection across sequences and reference grid matching for identical matrix dimensions
- **Orientation consistency validation** performs detailed sform/qform matrix comparison with comprehensive error reporting

#### Additional Pipeline Modules

#### Advanced Segmentation (segmentation.sh)
- **Harvard-Oxford gross brainstem extent** using subcortical index 7, tightened to `maxprob-thr25`, as the extent mask and the fallback
- **FreeSurfer brainstem substructures** (Iglesias 2015 `segmentBS`/`brainstemSsLabels`) for the detailed subdivision into midbrain / pons / medulla / SCP, gated by an FS↔HO agreement (Dice + leakage) QC check
- **Parallel multi-method mode** (default `BRAINSTEM_SEGMENTATION_METHOD=all`) runs the HO, FreeSurfer-substructure, multi-atlas, and SynthSeg+ paths concurrently and feeds their union to per-region detection; per-path `SEG_RUN_*` toggles. Single-method values (`freesurfer`, `atlas`/`harvard_oxford`, `multi_atlas`/`bianciardi`) remain available and mutually exclusive
- **Atlas-to-subject transformation** preserving native resolution by bringing the MNI HO atlas to subject space; FreeSurfer segments the subject's own T1 directly
- **Subject-specific refinement** using tissue segmentation (Atropos/FAST) to address shape variance in hydrocephalus & Chiari cases
- **FLAIR enhancement integration** creating both T1 and FLAIR intensity versions for multi-modal analysis
- **Native space preservation** maintains segmentation accuracy in subject's original high-resolution space rather than downsampling to template resolution

#### Comprehensive Analysis Pipeline (analysis.sh, gmm_threshold.py)
- **Region-based analysis** using the FreeSurfer brainstem substructures (midbrain/pons/medulla/SCP) for per-region hyperintensity detection (falls back to the HO gross brainstem mask when substructures are absent)
- **Standalone GMM threshold estimation** via `src/modules/gmm_threshold.py` — reads z-score and region mask NIfTI files directly, fits an adaptive Gaussian Mixture Model (2–3 components based on data density), and returns threshold parameters to the calling bash process via stdout (no intermediate files)
- **CSF / partial-volume exclusion** subtracts a CSF mask derived from the FSL FAST CSF PVE map (posterior-fossa CSF is the dominant false-positive source) before thresholding
- **Single authoritative fallback SD multiplier** (`THRESHOLD_WM_SD_MULTIPLIER`) reconciled across the bash path and `gmm_threshold.py`, applied when GMM is skipped
- **Centralized configuration** — all GMM tuning parameters (component limits, SD multipliers, weight cutoffs, floor/fallback percentiles) are set in `config/default_config.sh` and passed as CLI arguments, with defaults that match the config for standalone use
- **Per-region z-score normalization** addressing tissue inhomogeneity across different brainstem regions
- **Connectivity weighting** for refined detection using 3D morphological operations (fslmaths)
- **Multi-threshold hyperintensity detection** with configurable standard deviation multipliers and minimum cluster size filtering
- **Cross-modality validation** analyzes both FLAIR hyperintensities and T1 hypointensities with statistical correlation
- **Cross-modal corroboration** (`cross_modal_analysis.sh`, default on/graceful) annotates each primary FLAIR cluster with co-registered SWI/DWI-trace/ADC/T2 evidence (DWI restriction → acute, SWI → hemorrhage, T2 → corroborates), without altering the primary mask
- **Optional supervised / DL WMH modules** (each self-gated — no-op until its tool/model/training data is present), each intersecting results with the brainstem mask: FSL BIANCA (`wmh_bianca.sh`), LST-AI + FreeSurfer SAMSEG (`wmh_lst_samseg.sh`), WMH-SynthSeg (`wmh_synthseg.sh`), segcsvdWMH (`wmh_segcsvd.sh`), SHIVA-WMH (`wmh_shiva.sh`), MARS-WMH (`wmh_mars.sh`); plus a post-detection false-positive filter (`fp_filter.sh`, off by default)

#### Advanced Visualization & QA (visualization.sh, qa.sh)
- **Interactive 3D rendering** creates volume renderings of hyperintensity clusters with customizable opacity and color mapping
- **Multi-threshold comparison visualizations** generates side-by-side comparisons across different detection thresholds
- **Comprehensive QA validation** performs 20+ validation checks including file integrity, coordinate space consistency, and segmentation accuracy
- **Enhanced visual QA interface** with real-time FSLView integration for immediate visual feedback during processing

#### DICOM Integration & Clinical Validation (dicom_analysis.sh, dicom_cluster_mapping.sh)
- **Vendor-agnostic DICOM metadata extraction** analyzes scanner parameters, acquisition settings, and sequence characteristics for optimal processing
- **Clinical coordinate backtrace** maps processed results back to original DICOM coordinate system for PACS viewer compatibility
- **Cluster-to-DICOM mapping** (`dicom_cluster_mapping.sh`) creates coordinate lookup tables enabling medical imaging viewer navigation to identified clusters — **currently gated off** (`RUN_DICOM_MAPPING=false`) pending a rewrite; a normal run skips it
- **Scanner-specific optimization** automatically detects Siemens, Philips, and GE scanners and applies vendor-specific processing parameters

#### Intelligent Reference Space Selection (reference_space_selection.sh)
- **Adaptive reference space optimization** analyzes T1 and FLAIR scan quality, resolution, and acquisition parameters to select optimal processing space
- **Multi-modal compatibility assessment** calculates voxel aspect ratios, dimension matching, and registration compatibility between sequences
- **Resolution preservation strategy** intelligently chooses between maintaining native high-resolution vs standardized template space based on data quality
- **ORIGINAL vs DERIVED acquisition prioritization** significantly weights selection toward original scanner acquisitions over post-processed images

#### Environment & Utilities (environment.sh, utils.sh, fast_wrapper.sh)
- **Dynamic environment configuration** automatically detects available tools (ANTs, FSL, FreeSurfer) and configures optimal processing paths
- **Enhanced ANTs command execution** provides comprehensive error handling, progress monitoring, and automatic fallback strategies
- **Parallel FSL FAST wrapper** optimizes tissue segmentation with intelligent job distribution and memory management
- **Comprehensive validation framework** performs file integrity checks, coordinate space validation, and processing pipeline verification

#### Core Pipeline Integration
- **8-stage resumable pipeline** with intelligent checkpoint detection allowing restart from any processing stage
- **Smart data flow management** automatically tracks file dependencies and validates upstream processing completion
- **Comprehensive error handling** with graceful degradation and detailed diagnostic reporting for troubleshooting
- **Orientation distortion correction** leveraging ANTs transformation frameworks with comprehensive validation
- **Quantitative registration validation** with comprehensive QA metrics and emergency fallback triggers
- **Efficient resource utilization** through intelligent parallel processing with CPU-intensive job management
- **3D visualization pipeline** via standard NiFTi volumes and masks with comprehensive HTML reporting and DICOM backtrace

### Actual Implementation Details

#### Segmentation Module (segmentation.sh)
The segmentation module implements a **two-tier approach** (gross extent + substructures):

1. **Harvard-Oxford Subcortical Atlas (Gross Extent)**
   - Uses index 7 for the gross brainstem extent, tightened to `maxprob-thr25` (`HO_SUB_MAXPROB_THR`)
   - Warped into subject space; creates both `_brainstem.nii.gz` and `_brainstem_flair_intensity.nii.gz`
   - Always produced — serves as the FreeSurfer fallback and the reference for the FS↔HO agreement QC gate

2. **FreeSurfer Brainstem Substructures (Detailed Subdivision)**
   - Iglesias 2015 `segmentBS`/`brainstemSsLabels` → midbrain / pons / medulla / SCP masks in subject space (FreeSurfer segments the subject's own T1, no warp)
   - Run by default: the default `BRAINSTEM_SEGMENTATION_METHOD=all` mode runs this path concurrently with the HO / multi-atlas / SynthSeg+ paths (toggle with `SEG_RUN_FREESURFER`); also selectable as the single-method value `freesurfer` (`atlas`/`harvard_oxford` = gross mask only)
   - Gated by an FS↔HO agreement check (Dice + leakage); on disagreement or missing FreeSurfer/license, falls back to the HO gross mask and flags low confidence
   - Talairach has been removed entirely (single 1988 post-mortem brain; largest MNI-mapping error inferiorly/posteriorly — worst exactly in the brainstem)

3. **Subject-Specific Refinement**
   - Uses ANTs Atropos or FSL FAST tissue segmentation as fallback
   - Addresses shape variance in hydrocephalus and Chiari malformation cases
   - Integrates CSF, gray matter, and white matter probability maps

#### Analysis Module (analysis.sh + gmm_threshold.py)
The analysis module implements **region-based hyperintensity detection**:

1. **GMM Threshold Estimation** (`src/modules/gmm_threshold.py`)
   - Standalone Python script invoked per FreeSurfer brainstem substructure (falls back to the HO gross mask when substructures are absent)
   - Reads z-score NIfTI + region mask directly (no intermediate text files)
   - Adaptive component count (2–3) based on voxel density within each region
   - Weight-aware threshold adjustment: small hyperintense populations trigger more conservative thresholds to reduce false positives
   - Floor percentile prevents unreasonably low thresholds; data-driven fallback when GMM fit fails
   - All parameters configurable via `config/default_config.sh` (`GMM_*` variables)
   - Single authoritative fallback SD multiplier (`THRESHOLD_WM_SD_MULTIPLIER`) reconciled across bash and Python, applied when GMM is skipped
   - Results emitted as key=value on stdout; diagnostics to stderr — no filesystem IPC

2. **CSF / Partial-Volume Exclusion**
   - Builds a CSF exclusion mask from the FSL FAST CSF PVE map (computed once per subject, reused per region)
   - Removes posterior-fossa CSF (4th ventricle, basal cisterns), the dominant false-positive source, before thresholding

3. **Multi-Modal Integration**
   - FLAIR hyperintensity detection with configurable SD thresholds
   - T1 hypointensity correlation analysis
   - Cross-modal validation using statistical correlation

4. **Cluster Filtering**
   - 3D connectivity analysis with 26-neighbor connectivity (fslmaths)
   - Minimum cluster size filtering (configurable via `MIN_HYPERINTENSITY_SIZE`)
   - Morphological closing operations to eliminate noise

5. **Optional Supervised / DL WMH Modules** (each self-gated; no-op until its tool/model/training data is present)
   - Each intersects results with the brainstem mask: FSL BIANCA (`wmh_bianca.sh`), LST-AI + FreeSurfer SAMSEG (`wmh_lst_samseg.sh`), WMH-SynthSeg (`wmh_synthseg.sh`), segcsvdWMH (`wmh_segcsvd.sh`), SHIVA-WMH (`wmh_shiva.sh`), MARS-WMH (`wmh_mars.sh`)
   - A post-detection false-positive filter (`fp_filter.sh`) can be applied afterward (config-gated; off by default — lossy for small lesions)
   - **None is validated in the brainstem** — keep conservative pons QA / human-in-the-loop; these corroborate, they never alter the primary detection

#### QA Module (qa.sh)
The QA module performs **20+ comprehensive validation checks**:

1. **File Integrity Validation**
   - NIfTI header consistency across processing stages
   - Coordinate space validation (sform/qform matrices)
   - Volume preservation checks throughout pipeline

2. **Registration Quality Assessment**
   - Cross-correlation and normalized mutual information metrics
   - Histogram skewness analysis for registration accuracy
   - Emergency fallback triggers based on quantitative thresholds

3. **Segmentation Accuracy Validation**
   - Volume consistency across atlas spaces
   - Anatomical location verification (brainstem center-of-mass)
   - Cross-atlas agreement analysis

### Key Algorithmic Functions

#### Advanced Scan Selection & Reference Space Optimization
- **`select_best_scan()`** - Multi-modal quality assessment with registration-optimized selection modes including `original`, `highest_resolution`, `registration_optimized`, `matched_dimensions`, and `interactive` modes
- **`select_optimal_reference_space()`** - Intelligent reference space selection that analyzes voxel dimensions, aspect ratios, and acquisition types to determine the optimal template space for registration
- **`evaluate_scan_quality()`** - Comprehensive quality scoring based on file size, dimensions, voxel isotropy, tissue contrast, and ORIGINAL vs DERIVED acquisition detection

#### Enhanced N4 Bias Correction Pipeline
- **`process_n4_correction()`** - Adaptive N4 bias field correction with scanner-specific parameter optimization
- **Dynamic convergence settings** based on field strength (1.5T vs 3T) and acquisition protocol (2D vs 3D)
- **Iterative shrink-factor optimization** automatically adjusts based on image resolution and tissue contrast
- **Multi-stage bias correction** for severely biased images with progressive refinement

#### Intelligent Resolution & Template Detection
- **`detect_optimal_resolution()`** - Cross-sequence resolution analysis to determine the finest achievable target grid
- **`calculate_voxel_aspect_ratio()`** - Registration compatibility assessment between sequences
- **`is_3d_isotropic_sequence()`** - Automatic detection of 3D MPRAGE, SPACE, VISTA sequences to prevent quality degradation
- **Template resolution matching** automatically selects MNI152 templates based on input voxel dimensions for optimal registration accuracy

### Clinical Focus
- Vendor-specific optimizations for Siemens and Philips scanners (future: implement DICOM-RT and PACS integration as well)
- Practical configuration support to optimise output validity across 1.5T and 3T field strengths
- A novel DICOM backtrace for clinical verification of findings in native viewer format, because nothing in post-processing pipelines is proven until you can map it back to source of truth raw scanner output

### Data compatibility 
BrainStem X supports analysis of a wide variety of clinical neuroimaging MRI datasets:

- **High-end Research Protocols**: Optimized for 3D isotropic thin-slice acquisitions (1mm³ voxels)
  - 3D MPRAGE T1-weighted imaging
  - Optimisations for 3T scanners, accomodations for 1.5T
  - 3D SPACE/VISTA T2-FLAIR with SAG acquisition where available
  - Multi-parametric SWI/DWI integration as quantifiable support for T1W/FLAIR clustering results

- **Routine Clinical Protocols**: Robust fallback for standard clinical acquisitions
  - Thick-slice (3-5mm) 1.5T 2D axial FLAIR with gaps, where we likely have thin slice 3D T1/T1-MPR to register against
  - Non-isotropic voxel reconstruction estimation via ANTs
  - Single-sequence limited protocols e.g., AX FLAIR
  - Normalisation against MNT space and signal levels agaisnt the baseline of the individual subject

The pipeline extracts DICOM metadata including acquisition/scanner parameters, slice thickness, and orientation/modality/dimensionality to apply consistent, reliable, and transparent transformations, normalizations, and attempts registration techniques using ANTs and FSL libraries and atlas-based segmentation of the brainsteam, dorsal and ventral pons. 
Configurable N4 bias field correction and scanner orientation correction implementations help ensure integrity of the results. 20 validations within the qa module alone ensure consistency and reliability of your results.

These capabilities are included to support analysis of signal intensity actoss datasets from scans of varying imaging capabilities and protocols, making BrainStem X particularly effective for multi-center studies and retrospective analyses of existing clinical data.

This kind of visualisation with the ability to track back to raw DICOM files and map clusters across modalities could potentially be quite useful, even without machine learning techniques which of course are all the rage nowadays. This is a very much first-principles approach but it uses the very latest techniques and grounded research up to 2023.

### Example Workflow

```mermaid
graph TD
    A[Import DICOM Data] --> B[Sequence Quality Assessment]
    B -->|3D Thin-Slice| C1[Direct 3D Processing]
    B -->|2D Thick-Slice| C2[Multi-axial Integration]
    C1 --> E[N4 Bias Correction]
    C2 --> E
    E --> F[Multi-method Brainstem Segmentation]
    F --> G[Dorsal/Ventral Pons Subdivision]
    G --> H[Multi-threshold Hyperintensity Detection]
    H --> I[Cross-modality Cluster Analysis]
    I --> J[DICOM Backtrace & Reporting]
    
    style B fill:#f96,stroke:#333,stroke-width:2px
    style C2 fill:#f96,stroke:#333,stroke-width:2px
```

### 8-Stage Resumable Pipeline Architecture

The pipeline implements a sophisticated 8-stage processing workflow with intelligent checkpoint detection and resumability:

#### Stage 1: DICOM Import & Data Management
- **Vendor-agnostic DICOM conversion** using dcm2niix with scanner-specific optimization flags
- **Maximum data preservation** through series-by-series processing and emergency fallback conversion strategies
- **Intelligent metadata extraction** captures scanner parameters, field strength, acquisition settings for downstream optimization
- **Quality assessment** validates DICOM integrity and performs initial sequence classification

#### Stage 2: Preprocessing (Modality-Aware Denoising + N4 Bias Correction)
- **Adaptive reference space selection** analyzes scan quality and chooses optimal T1/FLAIR combination using [`select_optimal_reference_space()`](src/modules/reference_space_selection.sh:1)
- **Registration-optimized scan selection** with multiple modes: `original`, `highest_resolution`, `registration_optimized`, `matched_dimensions`
- **Modality-aware denoising** routes T1/T2/FLAIR to Rician NLM, DWI to MP-PCA (`dwidenoise`), skips SWI/TOF; a full DWI path (`dwi_preprocess.sh`) is gated by `PROCESS_DWI`
- **Enhanced N4 bias correction** where field strength tunes the b-spline mesh / spline distance (`-b`); FLAIR uses a gentler, lesion-aware preset
- **Orientation consistency validation** performs detailed sform/qform matrix comparison with comprehensive error reporting

#### Stage 3: Brain Extraction, Standardization & Cropping
- **Smart resolution detection** via [`detect_optimal_resolution()`](src/modules/brain_extraction.sh:214) analyzes voxel dimensions across sequences
- **Reference grid standardization** ensures T1 and FLAIR have identical matrix dimensions while preserving highest resolution
- **SynthStrip-primary brain extraction** (FreeSurfer `mri_synthstrip`, contrast-agnostic) with an automatic SynthStrip → ANTs(Otsu) → BET fallback chain, a shared `robustfov` neck-removal pre-step, modality-specific BET `-f`, and a posterior-fossa QC gate (`BRAIN_EXTRACTION_METHOD`)
- **3D isotropic sequence detection** prevents quality degradation from unnecessary multi-axial combination

#### Stage 4: Registration with Bidirectional Transform Management
- **Multi-stage ANTs registration** Rigid → Affine → SyN with white-matter guided initialization
- **Modality-aware SyN metric** Mutual Information for cross-modality (FLAIR↔T1), cross-correlation for same-modality, with `--winsorize-image-intensities`; atlases/masks warped with label-aware `GenericLabel` interpolation
- **Bidirectional space mapping** calculates native ↔ MNI transforms without resampling high-resolution data
- **Emergency fallback system** automatic SyNQuick or FSL FLIRT when quality metrics drop below thresholds
- **Enhanced registration validation** comprehensive metrics including cross-correlation, mutual information, normalized CC

#### Stage 5: Brainstem Segmentation
- **Parallel multi-method segmentation** (default `BRAINSTEM_SEGMENTATION_METHOD=all`): Harvard-Oxford gross extent + FreeSurfer substructures + multi-atlas nuclei + SynthSeg+ run as concurrent, independent, non-fatal paths whose masks are union-fed to per-region detection and provenance-tagged; per-path `SEG_RUN_*` toggles. Single-method values (`freesurfer`, `atlas`/`harvard_oxford`, `multi_atlas`/`bianciardi`) remain available
- **Harvard-Oxford gross extent** subcortical atlas (index 7, `maxprob-thr25`) for the brainstem boundary mask and as the fallback
- **FreeSurfer brainstem substructures** (Iglesias 2015 `segmentBS`) for midbrain / pons / medulla / SCP, gated by an FS↔HO agreement QC check; plus the full FreeSurfer recon harvest (aseg/wmparc/aparc stats, eTIV, optional subregions) and ML methods (SynthSeg+, SynthSR, sclimbic) from the same recon
- **Subject-specific refinement** using tissue segmentation to address shape variance in pathological cases
- **Native space preservation** maintains segmentation accuracy in subject's original high-resolution space
- **FLAIR integration** creates both T1 and FLAIR intensity versions for comprehensive analysis
- **Volume consistency validation** with anatomical location verification and comprehensive QA reporting

#### Stage 6: Comprehensive Hyperintensity Analysis
- **Per-region GMM thresholding** via standalone `gmm_threshold.py` — adaptive 2–3 component Gaussian Mixture Models fitted per FreeSurfer brainstem substructure, with all tuning parameters driven from `config/default_config.sh` and a single authoritative fallback SD multiplier (`THRESHOLD_WM_SD_MULTIPLIER`)
- **CSF / partial-volume exclusion** using the FSL FAST CSF PVE map before thresholding
- **Multi-threshold detection** configurable SD multipliers with minimum cluster size filtering
- **Cross-modality validation** analyzes hyperintensity patterns across T1/T2/FLAIR with statistical correlation
- **Cross-modal corroboration** samples each co-registered secondary (SWI/DWI-trace/ADC/T2) inside every primary FLAIR cluster and flags DWI restriction (→ acute), SWI hypointensity (→ hemorrhage), and T2 hyperintensity (→ corroborates) — on top of, never altering, the primary detection
- **Optional supervised / DL WMH** BIANCA, LST-AI + SAMSEG, WMH-SynthSeg, segcsvdWMH, SHIVA-WMH, MARS-WMH modules (each self-gated, no-op until its tool/data is present), intersected with the brainstem mask; optional `fp_filter.sh` post-detection FP suppression
- **Native-to-standard space mapping** enables analysis in both subject native and standardized coordinates
- **DICOM cluster backtrace** — the cluster→DICOM-source mapping (`dicom_cluster_mapping.sh`) is currently **gated off** (`RUN_DICOM_MAPPING=false`) pending a rewrite, so a normal run skips it

#### Stage 7: Advanced Visualization & Reporting
- **3D volume rendering** with customizable opacity and color mapping for hyperintensity clusters
- **Multi-threshold comparison** side-by-side visualizations across different detection thresholds
- **Report visualizations** per-method segmentation overlays, hyperintensity-on-FLAIR, and a multi-modal montage (FLAIR/DWI/SWI/T2)
- **Interactive QA interface** real-time FSLView integration for immediate visual feedback
- **Comprehensive HTML reporting** with embedded visualizations and quantitative metrics

#### Stage 8: Progress Tracking & Validation
- **Pipeline completion validation** verifies all processing stages and output file integrity
- **Comprehensive QA reporting** 20+ validation checks including coordinate space consistency
- **Batch processing summary** CSV reports with volume metrics and registration quality scores
- **Error tracking and diagnostics** detailed logging for troubleshooting and quality assurance

#### Stage 8.5: Aggregation & Reporting Layer
- **Summary tables** under `reports/tables/` as CSV/TSV + HTML (per-region hyperintensity, WMH tool volumes, segmentation volumes, cross-modal, FreeSurfer morphometry, run manifest)
- **Top-level dashboard** `reports/brainstemx_report.html` (+ `.md` fallback) embeds all populated tables and discovered visualizations; `manifest.json` records which sections were populated
- **Discovers** outputs wherever modules wrote them; gated/graceful/idempotent (`REPORTING_ENABLED`). See [docs/output_structure.md](output_structure.md)

**Complete Module Implementation:**
- Core Pipeline → [`src/pipeline.sh`](src/pipeline.sh:1)
- Environment & Configuration → [`src/modules/environment.sh`](src/modules/environment.sh:1), [`src/modules/utils.sh`](src/modules/utils.sh:1)
- DICOM Import & Data Management → [`src/modules/import.sh`](src/modules/import.sh:1)
- DICOM Analysis & Clinical Integration → [`src/modules/dicom_analysis.sh`](src/modules/dicom_analysis.sh:1), [`src/modules/dicom_cluster_mapping.sh`](src/modules/dicom_cluster_mapping.sh:1)
- Intelligent Scan Selection → [`src/modules/scan_selection.sh`](src/modules/scan_selection.sh:1)
- Reference Space Optimization → [`src/modules/reference_space_selection.sh`](src/modules/reference_space_selection.sh:1)
- Advanced Brain Extraction & Standardization → [`src/modules/brain_extraction.sh`](src/modules/brain_extraction.sh:1)
- Preprocessing → [`src/modules/preprocess.sh`](src/modules/preprocess.sh:1)
- Registration → [`src/modules/registration.sh`](src/modules/registration.sh:1)
- Brainstem Segmentation (HO gross extent + FreeSurfer substructures) → [`src/modules/segmentation.sh`](src/modules/segmentation.sh:1), [`src/modules/brainstem_freesurfer.sh`](src/modules/brainstem_freesurfer.sh:1)
- Multi-Atlas Labeling (Bianciardi/CIT168/AAL3) → [`src/modules/multi_atlas.sh`](src/modules/multi_atlas.sh:1)
- FreeSurfer Recon Harvest + ML methods (SynthSeg+/SynthSR/sclimbic) → [`src/modules/freesurfer_harvest.sh`](src/modules/freesurfer_harvest.sh:1)
- Comprehensive Analysis → [`src/modules/analysis.sh`](src/modules/analysis.sh:1), [`src/modules/gmm_threshold.py`](src/modules/gmm_threshold.py:1)
- Cross-Modal Corroboration → [`src/modules/cross_modal_analysis.sh`](src/modules/cross_modal_analysis.sh:1), [`src/modules/cross_modal_sample.py`](src/modules/cross_modal_sample.py:1)
- Optional WMH Modules (default add-ons) → [`src/modules/wmh_bianca.sh`](src/modules/wmh_bianca.sh:1), [`src/modules/wmh_lst_samseg.sh`](src/modules/wmh_lst_samseg.sh:1), [`src/modules/wmh_synthseg.sh`](src/modules/wmh_synthseg.sh:1), [`src/modules/wmh_segcsvd.sh`](src/modules/wmh_segcsvd.sh:1), [`src/modules/wmh_shiva.sh`](src/modules/wmh_shiva.sh:1), [`src/modules/wmh_mars.sh`](src/modules/wmh_mars.sh:1), [`src/modules/brainstem_aanseg.sh`](src/modules/brainstem_aanseg.sh:1), [`src/modules/fp_filter.sh`](src/modules/fp_filter.sh:1)
- Enhanced Registration Validation → [`src/modules/enhanced_registration_validation.sh`](src/modules/enhanced_registration_validation.sh:1)
- Advanced Visualization → [`src/modules/visualization.sh`](src/modules/visualization.sh:1)
- Aggregation & Reporting Layer → [`src/modules/reporting.sh`](src/modules/reporting.sh:1), [`src/modules/reporting_tables.py`](src/modules/reporting_tables.py:1)
- Quality Assurance → [`src/modules/qa.sh`](src/modules/qa.sh:1)
- Parallel Processing → [`src/modules/fast_wrapper.sh`](src/modules/fast_wrapper.sh:1)

## Installation

### Requirements

- ANTs (Advanced Normalization Tools): https://github.com/ANTsX/ANTs/wiki/Installing-ANTs-release-binaries
- FSL (FMRIB Software Library): https://git.fmrib.ox.ac.uk/fsl/conda/installer
- Convert3D (c3d) (SourceForge download link for Apple Silicon: https://sourceforge.net/projects/c3d/files/c3d/Nightly/c3d-nightly-MacOS-x86_64.dmg/download or just use Homebrew)
- dcm2niix (distributed with FreeSurfer): install via homebrew
- FreeSurfer (optional, for 3D visualization): https://surfer.nmr.mgh.harvard.edu/fswiki/rel7downloads
- Python 3 (for metadata extraction): use `conda` or preferably `uv` to manage python versions
- GNU Parallel (via homebrew)
- MacOS or (untested) Linux OS
- Python 3.12 (various libraries are unavailable on 3.13 at the time of writing)
- I reccomend the ITK-SNAP visualisation and manual segmentation tool so that you can compare the autoamted results vs manual segmentation. I also have a separate CNN based segmentation but it doesn't go down to the level that the automated tooling does.

### Install dependencies

Ensure you have ANTs, FSL, Convert3D, dcm2niix, Parallel and FreeSurfer installed. 
* NOTE: Some of these tools and ATLASes have different licences and you must agree or disagree individually with their licence terms.*
Most are available via `homebrew` (macOS). If you don't the script will conveniently tell you

``` 
==== Dependency Checker ====
[ERROR] ✗ dcm2niix is not installed or not in PATH
[INFO] Try: brew install dcm2niix
[INFO] Checking ANTs tools...
[SUCCESS] ✓ ANTs (antsRegistrationSyN.sh) is installed (/Users/username/ants/bin/antsRegistrationSyN.sh)
[SUCCESS] ✓ ANTs (N4BiasFieldCorrection) is installed (/Users/username/ants/bin/N4BiasFieldCorrection)
[SUCCESS] ✓ ANTs (antsApplyTransforms) is installed (/Users/username/ants/bin/antsApplyTransforms)
[SUCCESS] ✓ ANTs (antsBrainExtraction.sh) is installed (/Users/username/ants/bin/antsBrainExtraction.sh)
[INFO] Checking FSL...
[ERROR] ✗ FSL (fslinfo) is not installed or not in PATH
[ERROR] ✗ FSL (fslstats) is not installed or not in PATH
[ERROR] ✗ FSL (fslmaths) is not installed or not in PATH
[ERROR] ✗ FSL (bet) is not installed or not in PATH
[ERROR] ✗ FSL (flirt) is not installed or not in PATH
[ERROR] ✗ FSL (fast) is not installed or not in PATH
[INFO] Checking FreeSurfer...
[ERROR] ✗ FreeSurfer (mri_convert) is not installed or not in PATH
[ERROR] ✗ FreeSurfer (freeview) is not installed or not in PATH
[INFO] Checking Convert3D...
[SUCCESS] ✓ Convert3D is installed (/usr/local/bin/c3d)
[INFO] Checking operating system...
[SUCCESS] ✓ Running on macOS
[INFO] ==== Checking optional but recommended tools ====
[ERROR] ✗ ImageMagick is not installed or not in PATH
[INFO] Install with: brew install imagemagick
[WARNING] ImageMagick is recommended for image conversions
[ERROR] ✗ GNU Parallel is not installed or not in PATH
[INFO] Install with: brew install parallel
[ERROR] GNU Parallel is required for faster processing
[INFO] ==== Dependency Check Summary ====
[ERROR] 3 required dependencies are missing.
```

### Python dependencies

```
python -m pip install -r requirements.txt
```

Pro-tip: prefereably use `uv` - everything is already packaged for this and its much easier.

I will release a docker image some time in the future but bear in mind that GPU acceleration isn't available in Docker on Apple Silicon.

### Setup

1. Clone this repository:
   ```
   git clone https://github.com/myztery-neuroimg/brainstemx-full
   cd brainstemx-full
   ```

2. Ensure all dependencies are installed and in your PATH. The easiest way to do this is either run tests/integration.sh or run_pipeline.sh.

3. Make the pipeline script executable:
   ```
   chmod +x pipeline.sh
   chmod +x modules/*.sh
   chmod +x tests/*.sh
   ```

4. Create a python venv and install required packages. I *strongly* recommend to use `uv` instead of `venv` especially to ensure python 3.12
   ```
   python -m venv venv .
   source ./bin/activate
   pip install -r requirements.txt
   # alternatively:
   uv init
   uv python pin #version
   uv pip install -r requirements.txt
   uv venv / uv sync
   ```

### Quick Start

```
# Basic usage with default parameters
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id

# High quality processing for research use
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id -q HIGH

# Batch processing multiple subjects
./pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output_base --subject-list /path/to/subject_list.txt
```

## Acknowledgments 

BrainStem X leverages established neuroimaging tools, reinventing very little but combining some of these excellent projects:

- **ANTs**: Advanced Normalizations Tools ecosystem - highly incorporated in the pipeline
- **FSL**: Integrated with enhanced cluster analysis thresholding
- **FreeSurfer**: Utilized for 3D visualization of anomaly distribution
- **Custom Python modules**: Implemented for cross-modality registration and cluster correlation
- **Convert3D**
- **dcm2niix**
- **DCMTK**: dcmdump utility for extracting headers from DiCOM files
- **ITK-SNAP**

### Atlases & Templates

- **Harvard-Oxford Subcortical Structural Atlas** - Gross brainstem extent mask (index 7, `maxprob-thr25`)
- **FreeSurfer brainstem substructures** (Iglesias 2015 `segmentBS`) - Detailed subdivision (midbrain, pons, medulla, SCP)
- **MNI152 Standard Space Templates** - Registration targets with automatic resolution selection

### Programming Resources / Libraries (including..)
- Python Neuroimaging Libraries (NiBabel, PyDicom, antspyx)
- GNU Parallel
- Matplotlib & Seaborn
- NumPy, scikit-learn

## Independent Development

This project was developed independently without institutional or any other backing. I'm making this as available as possible to inspire development in this area of research.

I should qualify my background is Computer Science and Mathematics. I don't know the inner workings of the brainstem, what "normal" looks like, but I tried to find as many open source datasets as I could and relied on AI assistance in the radioneurological details, my expertise is in glueing things together. Real neuroradiological expertise would help a whole bunch here.. but I think computer science and mathematics have a lot to offer the field in terms of processing pipelines that put it all together and so this is our naive attempt.

This is a purely exploratory research project to understand the capabilities of existing tools in advanced pipelines in identifiying specific types of computationally "noticable" but clinically non-obvious anomalies. It is not clinically validated or necessarily robust or accurate and decisions and interpretations should always be made by qualified medical staff. 

## License
This project is released under the MIT License - see the LICENSE file for details.

Note: 
- Please review the licence terms of dependencies when setting up the environment for brainstemx.
- Users must accept responsibility for installing and accepting the licence terms of those projects individually.
- We have attempted where possible to minimise individual dependencies or provide alternatives (pluggable atlasses, for example); however, in practice some of these dependencies are going to be absolutely required as noted in the installation script and for convenience, in the output above.

If you use BrainStem X in your research, feel free to cite:

```
@software{BrainStemX2025,
  author = {D.J. Brewster},
  title = {BrainStem X: Advanced Brainstem/Pons MRI Analysis Pipeline},
  year = {2025},
  url = {https://github.com/myztery-neuroimg/brainstemx-full}
}
```

## Contributing
- Yes, please! Submit a PR or comment on the repository page if you like, all contributions are welcome.
- In particular, any neuroresearch related feedback about the neurological, radiological and computational/technical pipeline foundations would be amazing and will be cited if used to progress the project.
