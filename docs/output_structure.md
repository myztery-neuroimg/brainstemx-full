# BrainStemX-Full output structure

This document defines the **canonical results tree** produced by a pipeline run
and describes the **aggregation / reporting layer** that sits over it.

The reporting layer (`src/modules/reporting.sh` + `reporting_tables.py`) does not
require every module to write to a fixed path — it **discovers** outputs wherever
they land. The tree below is the canonical layout the pipeline creates up front
(`create_directories` in `environment.sh`) and that the reporting stage targets.
Everything is **graceful**: a minimal `T1 + FLAIR` run produces a valid (smaller)
set of tables and a top-level report; sections whose inputs are absent are
skipped cleanly and recorded as `absent` in the run manifest.

## Canonical tree

```
<RESULTS_DIR>/
├── metadata/                       # DICOM header analysis, scan selection
├── combined/                       # multi-axis combined volumes (when used)
├── bias_corrected/                 # N4 bias-corrected inputs  (preprocess)
├── brain_extraction/               # SynthStrip/ANTs/BET brain + masks
├── standardized/                   # *_std.nii.gz reference-space inputs
├── registered/                     # ANTs registration outputs
│   └── contrast_matched/           # contrast-matched cascade (T2/DWI/ADC/SWI → FLAIR/T1)
├── segmentation/
│   ├── tissue/                     # tissue segmentation (FAST/Atropos)
│   ├── brainstem/                  # Harvard-Oxford GROSS brainstem extent
│   ├── pons/                       # pons subdivision
│   ├── detailed_brainstem/         # FS substructures + multi-atlas nuclei + SynthSeg
│   │                               #   FS parcels:        <base>_{midbrain,pons,medulla,scp}.nii.gz
│   │                               #   Bianciardi nuclei: bianciardi_*.nii.gz
│   │                               #   CIT168 nuclei:     cit168_*.nii.gz
│   │                               #   AAL3 (optional):   aal3_*.nii.gz
│   └── freesurfer/  (or freesurfer/ at top level — harvest under harvest/)
├── freesurfer/
│   └── harvest/                    # FS recon harvest (freesurfer_harvest.sh)
│       ├── stats/                  # aseg.stats, wmparc.stats, *_volumes.tsv, aparc tsv
│       ├── csf_masks/              # aseg/synthseg CSF + ventricle masks (FP-exclusion)
│       ├── synthseg/               # synthseg_seg.nii.gz, synthseg_vols.csv
│       ├── subregions/             # thalamus / hypothalamus / hippo-amygdala labels
│       └── harvest_provenance.txt
├── hyperintensities/               # primary per-region GMM lesion masks + clusters/
│   └── clusters/                   # clusters.nii.gz (cluster index volume)
├── per_region_analysis/            # per-region GMM working dirs + provenance
│   ├── region_provenance.tsv       # region_tag / region_base / source / mask_path
│   └── region_stats.tsv            # (built by reporting) volume / clusters / z per region
├── analysis/
│   ├── wmh/                        # optional WMH tools, one subdir each
│   │   ├── bianca/ lst_samseg/ synthseg/ segcsvd/ shiva/ mars/
│   │   └── …/<tool>_wmh_summary.txt   (key=value: whole_brain_wmh_mm3, brainstem_wmh_mm3, …)
│   └── cross_modal/                # per-cluster corroboration table + summary
│       ├── cross_modal_clusters.csv
│       └── cross_modal_summary.txt
├── qc_visualizations/              # legacy QC PNGs / fsleyes scripts
├── advanced_visualization/         # 3D renderings, intensity profiles
├── visualizations/                 # report visualizations (NEW)
│   ├── seg_harvard_oxford_brainstem.png
│   ├── seg_{freesurfer,bianciardi,cit168,aal3}.png
│   ├── hyperintensities_on_flair.png
│   └── montage_{FLAIR,DWI,SWI,T2}.png
├── validation/                     # per-stage validation reports
├── summary/                        # batch-level summaries
└── reports/
    ├── tables/                     # summary tables (NEW)
    │   ├── hyperintensity_per_region.{tsv,html}
    │   ├── wmh_tool_volumes.{tsv,html}
    │   ├── segmentation_volumes.{tsv,html}
    │   ├── cross_modal.{tsv,html}
    │   ├── freesurfer_morphometry.{tsv,html}
    │   ├── run_manifest.{tsv,html}
    │   └── manifest.json
    ├── brainstemx_report.html      # one-stop dashboard (NEW)
    └── brainstemx_report.md        # markdown fallback (NEW)
```

## Summary tables

The reporting stage emits each of these as **both** a CSV/TSV and an HTML
fragment under `reports/tables/`. Each is gated on its inputs.

| Table | Columns | Source |
|---|---|---|
| `hyperintensity_per_region` | region, source, cluster_count, volume_mm3, mean_z, peak_z | per-region GMM `region_provenance.tsv` + `region_stats.tsv` sidecar |
| `wmh_tool_volumes` | tool, total_wmh_mm3, total_clusters, brainstem_wmh_mm3, brainstem_clusters | each enabled tool's `<tool>_wmh_summary.txt` |
| `segmentation_volumes` | region, source, volume_mm3, n_voxels | discovered masks (HO / FS / multi-atlas / SynthSeg-aseg / subregions) via `fslstats` |
| `cross_modal` | cluster_id, n_voxels, …, corroboration, n_corroborating | `analysis/cross_modal/cross_modal_clusters.csv` (passthrough) |
| `freesurfer_morphometry` | structure, volume_mm3 | `freesurfer/harvest/stats/aseg.stats` (incl. eTIV) |
| `run_manifest` | item, status, detail | which seg paths / WMH tools / modalities / tables ran |

## Top-level report

`reports/brainstemx_report.html` embeds all populated tables, the run manifest,
and any discovered visualizations (from `visualizations/`, plus a few legacy QC
PNGs). `reports/brainstemx_report.md` is a plain-text fallback. `manifest.json`
records, machine-readably, which sections were populated.

## Graceful minimal-run behaviour

A `T1 + FLAIR`-only run typically produces only the HO gross brainstem mask, a
per-region GMM hyperintensity table, and (if FreeSurfer ran) morphometry. In that
case:

- `hyperintensity_per_region` and `segmentation_volumes` are populated.
- `wmh_tool_volumes`, `cross_modal`, and (without FS) `freesurfer_morphometry`
  render as empty sections marked "No data for this section".
- The `run_manifest` lists every optional capability as `absent`.
- The top-level report still renders and is a valid dashboard.

## Pipeline wiring

The reporting stage runs as the FINAL step (Step 8.5, after analysis/QA/viz) in
`run_pipeline()`. It is idempotent (re-running overwrites the same outputs) and
never aborts the pipeline (every failure is logged as a non-fatal WARNING). It
is governed by `REPORTING_ENABLED` (default `true`); report visualizations honour
`SKIP_VISUALIZATION`.
