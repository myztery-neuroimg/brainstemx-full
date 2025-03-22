# e2e MRI Processing Framework for hyperintensity detection
A comprehensive neuroimaging pipeline for automated analysis of brain MRI scans, focusing on white matter hyperintensity detection and quantification/clustering.

# Overview
This framework integrates multiple neuroimaging tools (ANTs, FSL, FreeSurfer, Convert3D) into a streamlined workflow for processing MRI data. It handles conversion from DICOM to NIfTI, applies bias field correction, registers multiple acquisition planes, and performs hyperintensity detection with robust statistical analysis.
It's specifically optimised for Siemens scanners but will also work independently of that.

# Key Features

* Multi-axial integration: Combines sagittal, coronal, and axial acquisitions to enhance resolution and signal quality
* Adaptive parameterization: Automatically optimizes processing parameters based on sequence type and scanner metadata
* Customizable quality presets: Supports configurable processing quality levels (LOW, MEDIUM, HIGH)
* Parallel processing: Leverages multi-core architectures for improved performance
* Comprehensive quality control: Generates visualization outputs and quantitative metrics at each processing stage
* White matter hyperintensity detection: Implements robust, tissue-aware algorithm for identifying and quantifying abnormalities

# Requirements
The pipeline requires the following neuroimaging tools and owes all of its usefulness to them:

* ANTs (Advanced Normalization Tools) https://github.com/ANTsX/ANTs
* FSL (FMRIB Software Library) https://fsl.fmrib.ox.ac.uk/fsl/docs/
* FreeSurfer https://surfer.nmr.mgh.harvard.edu
* Convert3D (c3d) http://www.itksnap.org/pmwiki/pmwiki.php?n=Convert3D.Convert3D
* dcm2niix https://github.com/rordenlab/dcm2niix
* Python with pydicom (for metadata extraction)
* GNU parallel (brew install parallel / apt-get install parallel)
* ImageMagick (can generally be installed with homebrew or apt-get)

# Installation

Clone this repository

```
git clone https://github.com/davidj-brewster/e2e-brain-MRI-lesion-segment.git
cd e2e-brain-MRI-lesion-segment
```

# Ensure dependencies are installed

```
./processing_script.sh check_dependencies
```

#Usage

## Basic Usage

# Place DICOM files in the DiCOM directory

```
cp /path/to/your/dicom/files/* DiCOM/
```

# Run the processing pipeline

```
./processing_script.sh
```

# Advanced Configuration

The framework supports customization through configuration parameters at the top of the script:

* Set quality preset, suggest to start with LOW
```
QUALITY_PRESET="HIGH"  # Options: LOW, MEDIUM, HIGH
```

* Configure threading based on the number of CPU cores. If you have NVIDIA CUDA hardware, ANTS may be able to use that, I didn't check
```
ANTS_THREADS=8
```

* Set hyperintensity detection parameters
```
THRESHOLD_WM_SD_MULTIPLIER=2.5  #Standard deviations from region-local intensity median to identify as outliers
MIN_HYPERINTENSITY_SIZE=5  #Minimum number of voxels, increase if there is noise, decrease potentially for very high quality (3T/etc) and 3D-FLAIR scans
```

# Processing Pipeline

The framework implements a sequential processing workflow:

* DICOM to NIfTI conversion: Transforms DICOM files to the NIfTI format using dcm2niix
* Scanner metadata extraction: Analyzes DICOM headers to optimize processing parameters, this is tuned for Siemens scanners currently but has defaults in place otherwise
* Multi-axial integration: Combines images from different acquisition planes
* N4 bias field correction: Removes intensity non-uniformities with sequence-specific parameters
* Dimension standardization: Ensures consistent spatial resolution across images
* Registration: Aligns all images to a common reference space
* Quality assessment: Calculates SNR and generates visualization outputs
* Intensity normalization: Standardizes intensity profiles for consistent analysis
* Hyperintensity detection: Identifies white matter abnormalities through adaptive thresholding and morphological operations
* Statistical analysis: Quantifies detected abnormalities and generates reports

# Outputs

The pipeline generates structured outputs in the mri_results directory:

* combined/: High-resolution volumes from multi-axial integration
* bias_corrected/: N4-corrected images
* standardized/: Dimension-standardized images
* registered/: Images aligned to common space
* quality_checks/: SNR measurements and quality visualizations
* intensity_normalized/: Intensity-standardized images
* hyperintensities/: Detected white matter abnormalities
* cropped/: Brain-extracted images
* hyperintensity_report.txt: Statistical summary of findings

# Visualization

The framework includes scripts for visualizing results in FreeSurfer's Freeview:

```
./mri_results/view_all_results.sh
```

# View specific hyperintensity results

```
./mri_results/hyperintensities/FLAIR_*_view_in_freeview.sh
```

# Technical Notes

* The hyperintensity detection uses an adaptive threshold based on white matter statistics: WM_mean + (WM_SD * THRESHOLD_WM_SD_MULTIPLIER)
* Registration employs different similarity metrics for same-modality (correlation) and cross-modality (mutual information) alignment
* Tissue segmentation incorporates data from T1 when available, with fallback to intensity-based segmentation
* The N4 bias field correction parameters are optimized separately for each sequence type

# Comparative notes vs industry leading approaches

* Multi-axial Integration
This pipeline combines sagittal, coronal, and axial acquisitions to enhance resolution. This is an advanced approach similar to high-end research pipelines but less common in standard clinical tools. The implementation using antsMultivariateTemplateConstruction2.sh for combining multiple views is quite nice

* Adaptive Parameterization
This framework's ability to optimize processing parameters based on sequence type and scanner metadata is a strength. 

* The Siemens MAGNETOM Sola-specific optimizations demonstrate excellent vendor-specific tuning that many general packages lack.

* N4 Bias Field Correction Implementation
The sequence-specific bias correction parameters (especially the FLAIR-specific settings) show advanced understanding of how different pulse sequences require customized preprocessing. This level of sequence-specific tuning is found in high-end research implementations but less commonly in standard packages.

* Future improvements can be machine learning and deep learning integrations which the most advanced tools use. However, these require manually labelled data which introduces another potential failure domain.

# Acknowledgments

This framework integrates tools developed by the neuroimaging community:

* ANTs: http://stnava.github.io/ANTs/
* FSL: https://fsl.fmrib.ox.ac.uk/fsl/
* FreeSurfer: https://surfer.nmr.mgh.harvard.edu/
* Convert3D: http://www.itksnap.org/pmwiki/pmwiki.php?n=Convert3D
* dcm2niix: https://github.com/rordenlab/dcm2niix
As well as GNU parallel, imagemagick, Claude, Gemini and ChatGPT who did more than a little of the heavy lifting and teaching., ;) 
