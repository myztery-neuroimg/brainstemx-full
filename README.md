# intensityclustering: Brainstem/Pons MRI Analysis Pipeline ("BrainstemX")

BrainStem X is an end-to-end pipeline designed for precise analysis of the brainstem and pons - critical neuroanatomical regions that traditional neuroimaging pipelines often handle poorly. This pipeline addresses the unique challenges of brainstem imaging with:

- **Multi-modal integration** across T1/T2/FLAIR/SWI/DWI sequences with cross-modality anomaly detection
- **Precise orientation preservation** critical for analyzing directionally sensitive brainstem microstructure
- **Real-time cluster analysis** that identifies signal anomalies without manual segmentation bias
- **Multiple fallback methods** ensuring robust results even with suboptimal input data
- **DICOM backtrace capability** for clinical validation of findings in native scanner format

## What Makes BrainStem X Different

BrainStem X supports analysis of the entire spectrum of available clinical data:

- **High-end Research Protocols**: Optimized for 3D isotropic thin-slice acquisitions (1mm³ voxels)
  - 3D MPRAGE T1-weighted imaging
  - 3D SPACE/VISTA T2-FLAIR with SAG acquisition
  - Multi-parametric SWI/DWI integration

- **Routine Clinical Protocols**: Robust fallback for standard clinical acquisitions
  - Thick-slice (3-5mm) 2D axial FLAIR with gaps
  - Non-isotropic voxel reconstruction
  - Single-sequence limited protocols

The pipeline extracts DICOM metadata including detailed acquisition parameters, slice thickness, and orientation/modality/dimensionality to apply consistent, reliable, and transparent transformations, normalizations, and registration techniques using research-grade ANTs and FSL libraries and segmentation against cutting-edge atlases. This comprehensive approach enables analysis of datasets from centers with varying imaging capabilities and protocols, making BrainStem X particularly effective for multi-center studies and retrospective analyses of existing clinical data.

## Key Features

### Acquisition-Specific Processing and Registration
- Detection of 3D isotropic sequences through header metadata analysis
- Multi-axial integration for 2D sequences with gap interpolation
- Resolution-specific parameter selection for registration and segmentation
- Quantitative quality metrics that reflect acquisition limitations

### Advanced Segmentation
- Harvard-Oxford, Talairach and ANTs segmentation approaches with automatic fallback
- Precise dorsal/ventral pons division using principal component analysis
- Geometric approximation fallback when atlas approaches fail

### Cluster Analysis
- Statistical hyperintensity detection with multiple threshold approaches (1.5-3.0 SD)
- Cross-modality cluster overlap quantification across MRI sequences
- Objective anomaly detection independent of manual segmentation bias

### Technical Implementation
- Orientation distortion correction leveraging ANTs transformation frameworks
- Quantitative registration validation with comprehensive QA metrics
- Efficient resource utilization through parallel processing
- 3D visualization of anomalies with comprehensive HTML reporting

### Clinical Focus
- Vendor-specific optimizations for Siemens, Philips, and GE scanners
- Validated processing across 1.5T and 3T field strengths
- DICOM backtrace for clinical verification of findings in native viewer format

## Technical Foundation

BrainStem X leverages established neuroimaging tools while extending them for brainstem-specific analysis:

- **ANTs**: Extended with custom orientation preservation constraints
- **FSL**: Integrated with enhanced cluster analysis thresholding
- **FreeSurfer**: Utilized for 3D visualization of anomaly distribution
- **Custom Python modules**: Implemented for cross-modality registration and cluster correlation

### Acquisition-Specific Processing and Registration
- Detection of 3D isotropic sequences through header metadata analysis
- Multi-axial integration for 2D sequences with gap interpolation
- Resolution-specific parameter selection for registration and segmentation
- Quantitative quality metrics that reflect acquisition limitations

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
Installation
bash# Clone the repository
git clone https://github.com/yourusername/brainstem-x
cd brainstem-x

# Install dependencies
# Ensure you have ANTs, FSL, Convert3D, dcm2niix, and FreeSurfer installed

If you don't the script will conveniently tell you

```bash
[INFO] ==== MRI Processing Dependency Checker ====
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

# Then install Python requirements
```bash
python -m pip install -r requirements.txt
Quick Start
bash# Basic usage with default parameters
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id

# High quality processing for research use
./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id -q HIGH

# Batch processing multiple subjects
./pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output_base --subject-list /path/to/subject_list.txt
```

