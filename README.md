# Brain MRI ANTs E2E Pipeline

End-to-end pipeline for processing brain MRI images, with a focus on brainstem segmentation and hyperintensity detection.

## Overview

This pipeline processes T1-weighted and T2-FLAIR MRI images to:

1. Extract and segment the brainstem and pons via Atlas based segmentation (though easily extensible to other regions)
2. Detect hyperintensities within those regions
3. Generate comprehensive QA visualizations and reports ensuring pipeline validity

The pipeline uses ANTs (Advanced Normalization Tools) as the primary processing framework, with some additional tools from FSL and Convert3D.

## Features

- DICOM to NIfTI conversion with metadata extraction
- Multi-axial image integration
- N4 bias field correction
- Brain extraction
- Registration of modalities such as FLAIR/SPACE-FLAIR/DWI/SWI against T1MPRAGE
- Brainstem and pons segmentation
- Hyperintensity detection with multiple thresholds
- Comprehensive QA/validation
- HTML report generation

## Requirements

- ANTs (Advanced Normalization Tools)
- FSL (FMRIB Software Library)
- Convert3D (c3d)
- dcm2niix (distributed with FreeSurfer)
- FreeSurfer (optional, for 3D visualization)
- Python 3 (for metadata extraction)
- GNU Parallel (via homebrew)
- MacOS or (untested) Linux OS

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/davidj-brewster/e2e-brain-MRI-lesion-segment.git
   cd e2e-brain-MRI-lesion-segment
   ```

2. Ensure all dependencies are installed and in your PATH. The easiest way to do this is either run tests/integration.sh or run_pipeline.sh.

3. Make the pipeline script executable:
   ```bash
   chmod +x pipeline.sh
   chmod +x tests/integration.sh
   chmod +x tests/test_parallel.sh
   ```

## Usage

### Basic Usage

```bash
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id
```

### Options

```
Options:
  -c, --config FILE    Configuration file (default: config/default_config.sh)
  -i, --input DIR      Input directory (default: ../DiCOM)
  -o, --output DIR     Output directory (default: ../mri_results)
  -s, --subject ID     Subject ID (default: derived from input directory)
  -q, --quality LEVEL  Quality preset (LOW, MEDIUM, HIGH) (default: MEDIUM)
  -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM) (default: FULL)
  -h, --help           Show this help message and exit
```

### Batch Processing

To process multiple subjects, create a subject list file with the following format:
```
subject_id1 /path/to/flair1.nii.gz /path/to/t1_1.nii.gz
subject_id2 /path/to/flair2.nii.gz /path/to/t1_2.nii.gz
```

Then run:
```bash
./pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output_base --subject-list /path/to/subject_list.txt
```

## Pipeline Modules

The pipeline is organized into modular components:

- **environment.sh**: Environment setup, logging, configuration
- **import.sh**: DICOM import, metadata extraction, conversion to NIfTI
- **preprocess.sh**: Multi-axial integration, bias correction, brain extraction
- **registration.sh**: T1 to FLAIR registration
- **segmentation.sh**: Brainstem and pons segmentation
- **analysis.sh**: Hyperintensity detection and analysis
- **visualization.sh**: QC visualizations, multi-threshold overlays, HTML reports
- **qa.sh**: Quality assurance and validation functions

## Output Structure

```
mri_results/
├── logs/                          # Processing logs
├── metadata/                      # DICOM metadata
├── combined/                      # Multi-axial combined images
├── bias_corrected/                # N4 bias-corrected images
├── brain_extraction/              # Brain-extracted images
├── standardized/                  # Dimension-standardized images
├── registered/                    # Registration results
├── segmentation/                  # Segmentation results
│   ├── brainstem/                 # Brainstem segmentation
│   └── pons/                      # Pons segmentation
├── hyperintensities/              # Hyperintensity detection results
│   ├── thresholds/                # Multiple threshold results
│   └── clusters/                  # Cluster analysis
├── validation/                    # Validation results
│   ├── registration/              # Registration validation
│   ├── segmentation/              # Segmentation validation
│   └── hyperintensities/          # Hyperintensity validation
├── qc_visualizations/             # QC visualizations
├── reports/                       # HTML reports
└── summary/                       # Summary results
```

## Customization

You can customize the pipeline by:

1. Creating a custom configuration file based on `config/default_config.sh`
2. Passing it to the pipeline with the `-c` option

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- ANTs (Advanced Normalization Tools)
- FSL (FMRIB Software Library)
- Convert3D
- dcm2niix
- FreeSurfer
- GNU Parallel
- Roo Code/Claude 3.7 :D 
