# BrainStemX-Full

An end-to-end neuroimaging pipeline for analyzing T2/FLAIR hyperintensity and T1 hypointensity clusters in brainstem and pons regions. Combines multi-modal MRI analysis (T1/T2/FLAIR/SWI/DWI) with zero-shot anomaly detection.

<image width="400" alt="Simulated Hyperintensity Cluster on T2-SPACE-FLAIR" src="https://github.com/user-attachments/assets/5dc95c74-e270-47cf-aad5-9afaf70c85c1" />

## Key Features

- **Multi-modal integration** across T1/FLAIR plus SWI / DWI-trace / ADC / T2 (modality-aware selection), with **cross-modal corroboration** of every primary FLAIR cluster (DWI restriction → acute, SWI → hemorrhage, T2 → corroborates)
- **Contrast-matched cascaded registration** (`T1 → FLAIR → {DWI, T2, SWI}`, default on, graceful) anchors each secondary modality to its nearest same-contrast 3D structural, with composed forward+inverse transforms
- **Zero-shot cluster analysis** identifies signal anomalies without manual segmentation — per-region GMM with FreeSurfer-CSF-aware CSF/partial-volume exclusion is the PRIMARY detector
- **Parallel multi-method brainstem segmentation** (default `BRAINSTEM_SEGMENTATION_METHOD=all`): Harvard-Oxford gross extent + FreeSurfer substructures + multi-atlas nuclei + SynthSeg+ run concurrently, union-fed and provenance-tagged (per-method `SEG_RUN_*` toggles)
- **Full FreeSurfer recon harvest** (aseg/wmparc/aparc stats, eTIV, optional thalamic/hypothalamic/hippo-amygdala subregions) plus extra ML methods (SynthSeg+, SynthSR, sclimbic)
- **8-stage resumable pipeline** with intelligent checkpoint detection
- **Canonical results tree + reporting layer** — per-method/cluster/multi-modal visualizations, CSV/HTML summary tables, and a top-level `reports/brainstemx_report.html` dashboard
- **DICOM backtrace capability** for clinical validation in native scanner format (cluster→source mapping is currently gated off pending a rewrite — `RUN_DICOM_MAPPING=false`)
- **Adaptive processing** handles both high-end research and routine clinical protocols
- **Optional multi-atlas brainstem nuclei labeling** (Bianciardi/CIT168/AAL3) warped into subject space
- **Optional supervised/DL WMH modules** (BIANCA, LST-AI/SAMSEG, segcsvdWMH, SHIVA-WMH, MARS-WMH, WMH-SynthSeg) — exploratory; none validated in the brainstem

## Quick Start

### Requirements

- ANTs (Advanced Normalization Tools)
- FSL (FMRIB Software Library)
- dcm2niix
- Convert3D (c3d)
- GNU Parallel
- Python 3.12.8 (managed via `uv`)

### Installation

```bash
# Clone repository
git clone https://github.com/myztery-neuroimg/brainstemx-full
cd brainstemx-full

# Install Python dependencies
uv sync

# Make scripts executable
chmod +x src/pipeline.sh src/modules/*.sh tests/*.sh
```

### Basic Usage

```bash
# Source environment and run pipeline
source ~/.bash_profile && src/pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id

# High quality processing
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001 -q HIGH

# Resume from specific stage
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001 -t registration
```

### Pipeline Stages

The pipeline consists of 8 resumable stages:

1. **import** - DICOM import and conversion (all series kept; no modality filtering)
2. **preprocess** - Modality-aware denoising (Rician NLM for T1/T2/FLAIR, MP-PCA for DWI) + N4 bias correction (field-strength `-b`; gentler lesion-aware FLAIR)
3. **brain_extraction** - SynthStrip primary (ANTs/BET fallback) + robustfov + posterior-fossa QC, plus standardization
4. **registration** - Multi-stage ANTs alignment (cross-modality SyN uses Mutual Information) + the contrast-matched cascade routing any present SWI/DWI/ADC/T2 into the common analysis space
5. **segmentation** - Parallel multi-method brainstem segmentation (default `BRAINSTEM_SEGMENTATION_METHOD=all`): Harvard-Oxford gross extent (thr25) + FreeSurfer substructures + multi-atlas nuclei (Bianciardi/CIT168/AAL3) + SynthSeg+, union-fed; also `freesurfer` / `atlas` / `multi_atlas` single-method values
6. **analysis** - Per-region GMM hyperintensity detection with CSF/PV exclusion + cross-modal corroboration of each cluster
7. **visualization** - Generate QC + report visualizations
8. **tracking** - Pipeline progress validation

A final **reporting** step (Step 8.5) then aggregates everything into CSV/HTML summary tables and the top-level `reports/brainstemx_report.html` dashboard.

Use `-t STAGE` to resume from any stage (e.g., `-t 4` or `-t registration`).

## Documentation

- **[Technical Overview](docs/TECHNICAL_OVERVIEW.md)** - Comprehensive technical documentation
- **[Output Structure](docs/output_structure.md)** - Canonical results tree, summary tables, and the top-level report
- **[Multi-Atlas Integration](docs/multi_atlas_integration_spec.md)** - Optional Bianciardi/CIT168/AAL3 brainstem labeling
- **[FreeSurfer Brainstem Substructures](docs/brainstem_freesurfer_segmentation_spec.md)** - Iglesias 2015 `segmentBS` parcels (replaces Talairach)
- **[Scan Selection](docs/README_scan_selection.md)** - Details on intelligent scan selection
- **[Reference Space Selection](docs/README_reference_space_selection.md)** - Reference space optimization
- **[Synthetic Test Data](docs/synthetic_test_data.md)** - Generating synthetic phantoms for testing
- **[Testing Guide](docs/README_tests.md)** - Testing framework and validation

## Project Status

Active development as of June 2026. While functional, improvements are ongoing. For a minimal bare-bones pure-Python implementation with web UI, see [brainstemx](https://github.com/myztery-neuroimg/brainstemx) - it also needs a lot more work at this moment.

## Acknowledgments

This pipeline leverages established neuroimaging tools:
- **ANTs** - Advanced Normalizations Tools
- **FSL** - FMRIB Software Library
- **FreeSurfer** - Brainstem substructure segmentation (Iglesias 2015 `segmentBS`), full recon harvest (aseg/wmparc/aparc stats, eTIV, subregions), ML methods (SynthSeg+, SynthSR, sclimbic), and 3D visualization
- **Harvard-Oxford Atlas** - Gross brainstem extent mask
- **MNI152 Templates** - Registration targets

Optional multi-atlas brainstem labeling (warped MNI→subject, GenericLabel):
- **Bianciardi Brainstem Navigator** - Probabilistic brainstem-nuclei atlas (Bianciardi et al., *Brain Connect* 2015)
- **CIT168** - Subcortical atlas (Pauli, Nili & Tyszka, *Sci Data* 2018;5:180063)
- **AAL3** - Anatomical atlas (Rolls et al., *NeuroImage* 2020;206:116189)

## License

MIT License - see LICENSE file for details.

Note: Dependencies may have different licenses. Users must accept responsibility for installing and accepting the license terms of those projects individually.

## Citation

```bibtex
@software{BrainStemX2025,
  author = {D.J. Brewster},
  title = {BrainStem X: Advanced Brainstem/Pons MRI Analysis Pipeline},
  year = {2025},
  url = {https://github.com/myztery-neuroimg/brainstemx-full}
}
```

## Contributing

Contributions welcome! Submit PRs or comment on the repository. Neuroresearch feedback on radiological and computational pipeline foundations is especially appreciated.
