# BrainStemX-Full

An end-to-end neuroimaging pipeline for analyzing T2/FLAIR hyperintensity and T1 hypointensity clusters in brainstem and pons regions. Combines multi-modal MRI analysis (T1/T2/FLAIR/SWI/DWI) with zero-shot anomaly detection.

<image width="400" alt="Simulated Hyperintensity Cluster on T2-SPACE-FLAIR" src="https://github.com/user-attachments/assets/5dc95c74-e270-47cf-aad5-9afaf70c85c1" />

## Key Features

- **Multi-modal integration** across T1/T2/FLAIR/SWI/DWI sequences
- **Zero-shot cluster analysis** identifies signal anomalies without manual segmentation
- **8-stage resumable pipeline** with intelligent checkpoint detection
- **DICOM backtrace capability** for clinical validation in native scanner format
- **Adaptive processing** handles both high-end research and routine clinical protocols

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

1. **import** - DICOM import and conversion
2. **preprocess** - Rician denoising + N4 bias correction
3. **brain_extraction** - Brain extraction and standardization
4. **registration** - Multi-stage alignment to standard space
5. **segmentation** - Brainstem and pons region extraction
6. **analysis** - Hyperintensity detection and clustering
7. **visualization** - Generate reports and visualizations
8. **tracking** - Pipeline progress validation

Use `-t STAGE` to resume from any stage (e.g., `-t 4` or `-t registration`).

## Documentation

- **[Technical Overview](docs/TECHNICAL_OVERVIEW.md)** - Comprehensive technical documentation
- **[Scan Selection](docs/README_scan_selection.md)** - Details on intelligent scan selection
- **[Reference Space Selection](docs/README_reference_space_selection.md)** - Reference space optimization
- **[Testing Guide](docs/README_tests.md)** - Testing framework and validation

## Project Status

Active development as of February 2026. While functional, improvements are ongoing. For a minimal pure-Python implementation with web UI, see [brainstemx](https://github.com/myztery-neuroimg/brainstemx).

## Acknowledgments

This pipeline leverages established neuroimaging tools:
- **ANTs** - Advanced Normalizations Tools
- **FSL** - FMRIB Software Library
- **FreeSurfer** - 3D visualization
- **Harvard-Oxford & Talairach Atlases** - Brainstem segmentation
- **MNI152 Templates** - Registration targets

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
