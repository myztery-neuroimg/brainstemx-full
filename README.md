# intensityclustering: Brainstem/Pons MRI Analysis Pipeline ("BrainstemX")

BrainStem X (_Brainstem/Pons specific_ intensityclustering implementation) is an end-to-end pipeline designed for precise analysis of subtle T2/FLAIR hyperintensity/T1 hypointensity clusters in these critical brain neuroanatomical regions. Brainstem regions can present clinically with very subtle variations below the clinical threshold to human radiologists and standard research methods. This pipeline tries to address some the  challenges via

- **Multi-modal integration** across T1/T2/FLAIR/SWI/DWI sequences with cross-modality anomaly detection
- **N4 Bias Field AND slice-acquisiton** correction (e.g., SAG-acquired FLAIR sequences).
- **Precise orientation preservation** critical for analyzing directionally sensitive brainstem microstructure
- **Zero-shot/unsupervised cluster analysis** which could identify signal anomalies without manual segmentation or human false negative biases
- **Multiple fallback methods** at various steps, activated by quantitative quality metrics, adding robustness to results even with suboptimal slice thickness, modalities and IPR
- **DICOM backtrace capability** for clinical validation of findings in native scanner format
- **Parallel processing** of subjects and optimisation of multithreaded performance and standardised outputs to support larger cohort analysis

## Project status

The project is in active development as of April 2025 and whilst many improvements are in the works, already offers some helpful functionality.

## What Makes BrainStem X Different

BrainStem X supports analysis of a wide variety of clinical neuroimaging MRI datasets:

- **High-end Research Protocols**: Optimized for 3D isotropic thin-slice acquisitions (1mm³ voxels)
  - 3D MPRAGE T1-weighted imaging
  - Optimisations for 3T scanners, accomodations for 1.5T
  - 3D SPACE/VISTA T2-FLAIR with SAG acquisition where available
  - Multi-parametric SWI/DWI integration as quantifiable support for T1W/FLAIR clustering results

- **Routine Clinical Protocols**: Robust fallback for standard clinical acquisitions
  - Thick-slice (3-5mm) 1.5T 2D axial FLAIR with gaps, along with standard T1/T1-MPR to register against
  - Non-isotropic voxel reconstruction estimation via ANTs
  - Single-sequence limited protocols e.g., AX FLAIR
  - Normalisation against MNT space and signal levels agaisnt the baseline of the individual subject

The pipeline extracts DICOM metadata including acquisition/scanner parameters, slice thickness, and orientation/modality/dimensionality to apply consistent, reliable, and transparent transformations, normalizations, and attempts registration techniques using ANTs and FSL libraries and atlas-based segmentation of the brainsteam, dorsal and ventral pons. 
Configurable N4 bias field correction and scanner orientation correction implementations help ensure integrity of your results. 20 validations within the qa module alone ensure consistency and reliability of your results.

These capabilities are included to support analysis of signal intensity actoss datasets from scans of varying imaging capabilities and protocols, making BrainStem X particularly effective for multi-center studies and retrospective analyses of existing clinical data.

![image](https://github.com/user-attachments/assets/5dc95c74-e270-47cf-aad5-9afaf70c85c1)

## Features

### Acquisition-Specific Processing and Registration
- Detection of 3D isotropic sequences through header metadata analysis
- Multi-axial integration for 2D sequences with gap interpolation
- Resolution-specific parameter selection for registration and segmentation
- Quantitative quality metrics that reflect acquisition limitations

### Advanced Segmentation
- Harvard-Oxford, Talairach and ANTs segmentation approaches with automatic fallback
- Support for SUIT Atlas sub-region segmentation of the Brainstem (I wasnt able to find the SUIT dataset so this likely needs small modifications)
- Precise dorsal/ventral pons division using principal component analysis eg WM tissue in this anatomical region
- Geometric approximation of brainsteam architecture as fallback when atlas segmentation approachess fail
- Quantified "quality assessment" of the brain extraction, registration quality and segmentation accuracy

### Cluster Analysis
- Statistical hyperintensity detection with multiple threshold approaches (1.5-3.0 SD)
- Cross-modality cluster overlap quantification across MRI sequences
- Pure quantile-bassd anomaly detection specific to subject, independent of manual labelling bias associated with deep learning models

### Technical Implementation
- Orientation distortion correction leveraging ANTs transformation frameworks
- Quantitative registration validation with comprehensive QA metrics
- Efficient resource utilization through parallel processing
- 3D visualization via standard NiFTi volumes and masks of anomalies with comprehensive HTML reporting

### Clinical Focus
- Vendor-specific optimizations for Siemens and Philips scanners (future: implement DICOM-RT and PACS integration as well)
- Practical configuration support to optimise output validity across 1.5T and 3T field strengths
- A novel DICOM backtrace for clinical verification of findings in native viewer format, because nothing in post-processing pipelines is proven until you can map it back to source of truth raw scanner output

## Example Workflow

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

## Installation

## Requirements

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

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/myztery-neuroimg/intensityclustering
   cd intensityclustering
   ```

2. Ensure all dependencies are installed and in your PATH. The easiest way to do this is either run tests/integration.sh or run_pipeline.sh.

3. Make the pipeline script executable:
   ```bash
   chmod +x pipeline.sh
   chmod +x modules/*.sh
   chmod +x tests/*.sh
   ```

4. Create a python venv and install required packages. I *strongly* recommend to use `uv` instead of `venv` especially to ensure python 3.12
   ```bash
   python -m venv venv .
   source ./bin/activate
   pip install -r requirements.txt
   # alternatively:
   uv init
   uv python pin #version
   uv pip install -r requirements.txt
   uv venv / uv sync
   ```

# Install dependencies
# Ensure you have ANTs, FSL, Convert3D, dcm2niix, and FreeSurfer installed

If you don't the script will conveniently tell you

 ``` 
==== Dependency Checker ====
[ERROR] ✗ dcm2niix is not installed or not in PATH
[INFO] Try: brew install dcm2niix
[INFO] Checking ANTs tools...
[SUCCESS] ✓ ANTs (antsRegistrationSyN.sh) is installed (/Users/davidbrewster/ants/bin/antsRegistrationSyN.sh)
[SUCCESS] ✓ ANTs (N4BiasFieldCorrection) is installed (/Users/davidbrewster/ants/bin/N4BiasFieldCorrection)
[SUCCESS] ✓ ANTs (antsApplyTransforms) is installed (/Users/davidbrewster/ants/bin/antsApplyTransforms)
[SUCCESS] ✓ ANTs (antsBrainExtraction.sh) is installed (/Users/davidbrewster/ants/bin/antsBrainExtraction.sh)
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

## Then install Python requirements

```
python -m pip install -r requirements.txt
```

Pro-tip: prefereably use `uv` - everything is already packaged for this and its much easier.

I will release a docker image some time in the future but bear in mind that GPU acceleration isn't available in Docker on Apple Silicon.

## Quick Start

```
# Basic usage with default parameters
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id

# High quality processing for research use
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id -q HIGH

# Batch processing multiple subjects
./pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output_base --subject-list /path/to/subject_list.txt
```

## Unique Advantages

BrainStem X provides:

### Specialized Brainstem Focus: Targeted methods for brainstem and pontine lesion detection
### Acquisition-Specific Processing: Tailored workflows for both research-grade and standard clinical protocols
### Objective Anomaly Detection: Statistical cluster identification using intensity distribution analysis
### Multi-modality Integration: Correlative analysis across T1/T2/FLAIR/SWI/DWI sequences
### Clinical Translation: DICOM backtrace for radiological verification in standard clinical viewers
### Reliability: Comprehensive validation metrics for registration and segmentation quality

# Acknowledgments 

BrainStem X leverages established neuroimaging tools while extending them for brainstem-specific analysis:

- **ANTs**: Extended with custom orientation preservation constraints
- **FSL**: Integrated with enhanced cluster analysis thresholding
- **FreeSurfer**: Utilized for 3D visualization of anomaly distribution
- **Custom Python modules**: Implemented for cross-modality registration and cluster correlation

## Neuroimaging Tools

* ANTs (Advanced Normalization Tools)
* FSL (FMRIB Software Library)
* FreeSurfer
* Convert3D
* dcm2niix
* ITK-SNAP

## Atlases & Templates

* Harvard-Oxford Subcortical Structural Atlas
* Talairach Atlas
* MNI152 Standard Space Templates
* SUIT Cerebellar Atlas

## Programming Resources / Libraries (including..)

* Python Neuroimaging Libraries (NiBabel, PyDicom)
* GNU Parallel
* Matplotlib & Seaborn
* NumPy & SciPy

# Independent Development

This project was developed independently without institutional backing

## Citation

If you use BrainStem X in your research, you may cite:
@software{BrainStemX2025,
  author = {Myztery Evaluation c/o LazyEvaluation},
  title = {BrainStem X: Advanced Brainstem/Pons MRI Analysis Pipeline},
  year = {2025},
  url = {https://github.com/myzteryneuro/intensityclustering}
}

# License
This project is licensed under the MIT License - see the LICENSE file for details.

# Contributing
Yes, please! Just submit a PR, all contributions are welcome as are research or clinical feedback about the radiological and technical pipeline foundations! Thanks in advance..
