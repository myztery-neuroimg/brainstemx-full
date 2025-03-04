# MRI Processing Framework
A comprehensive neuroimaging pipeline for automated analysis of brain MRI scans, focusing on white matter hyperintensity detection and quantification.

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
The pipeline requires the following neuroimaging tools:

* ANTs (Advanced Normalization Tools)
* FSL (FMRIB Software Library)
* FreeSurfer
* Convert3D (c3d)
* dcm2niix
* Python with pydicom (for metadata extraction)

# Optional but recommended:

* GNU Parallel
* ImageMagick

# Installation

Clone this repository

```
git clone https://github.com/davidj-brewster/brainMRI-clustering.git
cd mri-processing-framework
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

* Set quality preset
```
QUALITY_PRESET="HIGH"  # Options: LOW, MEDIUM, HIGH
```

* Configure threading
```
ANTS_THREADS=8
```

* Set hyperintensity detection parameters
```
THRESHOLD_WM_SD_MULTIPLIER=2.5
MIN_HYPERINTENSITY_SIZE=5
```

# Processing Pipeline

The framework implements a sequential processing workflow:

* DICOM to NIfTI conversion: Transforms DICOM files to the NIfTI format using dcm2niix
* Scanner metadata extraction: Analyzes DICOM headers to optimize processing parameters
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
This pipeline combines sagittal, coronal, and axial acquisitions to enhance resolution. This is an advanced approach similar to high-end research pipelines but less common in standard clinical tools. The implementation using antsMultivariateTemplateConstruction2.sh for combining multiple views is particularly sophisticated.

* Adaptive Parameterization
This framework's ability to optimize processing parameters based on sequence type and scanner metadata is a significant strength. This approach is comparable to sophisticated platforms like:
** MRIQC (MRI Quality Control)
** The Human Connectome Project pipelines

* The Siemens MAGNETOM Sola-specific optimizations demonstrate excellent vendor-specific tuning that many general packages lack.

* N4 Bias Field Correction Implementation
The sequence-specific bias correction parameters (especially the FLAIR-specific settings) show advanced understanding of how different pulse sequences require customized preprocessing. This level of sequence-specific tuning is found in high-end research implementations but less commonly in standard packages.

# Lack of machine learning / CNN model integration - simply due to lack of appropriate datasets:

## Machine Learning Approaches:

* FSL-BIANCA uses k-nearest neighbor classification with spatial features
* LST (Lesion Segmentation Tool) employs a lesion growth algorithm with tissue probability maps
* These methods typically achieve Dice coefficients of 0.7-0.8 on challenging datasets

## Deep Learning Methods:

*  nicMSlesions uses a cascade of convolutional neural networks
* DeepMedic employs 3D CNN architectures with multi-scale processing
* These approaches typically achieve Dice coefficients of 0.75-0.85
* They handle heterogeneous lesion appearances more robustly

#q Acknowledgments

This framework integrates tools developed by the neuroimaging community:

* ANTs: http://stnava.github.io/ANTs/
* FSL: https://fsl.fmrib.ox.ac.uk/fsl/
* FreeSurfer: https://surfer.nmr.mgh.harvard.edu/
* Convert3D: http://www.itksnap.org/pmwiki/pmwiki.php?n=Convert3D
* dcm2niix: https://github.com/rordenlab/dcm2niix
