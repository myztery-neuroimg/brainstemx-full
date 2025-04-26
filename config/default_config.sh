#!/usr/bin/env bash
#
# default_config.sh - Default configuration for the brain MRI processing pipeline
#
# This file contains default configuration parameters for the pipeline.
# Users can override these parameters by creating a custom configuration file
# and passing it to the pipeline using the -c/--config option.
#

# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="${HOME}/workspace-priv/DiCOM"          # DICOM input directory
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix
export RESULTS_DIR="../mri_results"
# ANTs configuration
export ANTS_PATH="/opt/ants"  # Base ANTs installation directory
export ANTS_BIN="${ANTS_PATH}/bin"  # Directory containing ANTs binaries
export PATH="$PATH:${ANTS_BIN}"
export LOG_DIR="${RESULTS_DIR}/logs"
export RESULTS_DIR="../mri_results"
# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
export PROCESSING_DATATYPE="float"  # internal float
export UTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
export QUALITY_PRESET="HIGH"
export MAX_CPU_INTENSIVE_JOBS=1

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
#export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,500,2"
export N4_PRESET_MEDIUM="100x100x100x50,0.0000001,500,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # override if needed

export PARALLEL_JOBS=0

export QUALITY_PRESET="HIGH"
# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi
# Parse out the fields for general sequences
export N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
export N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
export N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
export N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
export N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
export N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
export N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
export N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
export TEMPLATE_ITERATIONS=1
export TEMPLATE_GRADIENT_STEP=0.05
export TEMPLATE_TRANSFORM_MODEL="SyN"
export TEMPLATE_SIMILARITY_METRIC="CC"
export TEMPLATE_SHRINK_FACTORS="6x4x2x1"
export TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
export TEMPLATE_WEIGHTS="100x50x50x10"

# Registration & motion correction
export REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
export REG_METRIC_CROSS_MODALITY="MI"  # Mutual Information - for cross-modality (T1-FLAIR)
export REG_METRIC_SAME_MODALITY="CC"   # Cross Correlation - for same modality
export ANTS_THREADS=8                 # Number of threads for ANTs processing
export REG_PRECISION=1                 # Registration precision (higher = more accurate but slower)

# ANTs specific parameters - if not set, ANTs will use defaults
# export METRIC_SAMPLING_STRATEGY="NONE"  # Options: NONE (use all voxels), REGULAR, RANDOM
# export METRIC_SAMPLING_PERCENTAGE=1.0   # Percentage of voxels to sample (when not NONE)

# Hyperintensity detection
export THRESHOLD_WM_SD_MULTIPLIER=1.5 #Standard deviations from local norm
export MIN_HYPERINTENSITY_SIZE=2

# Tissue segmentation parameters
export ATROPOS_T1_CLASSES=3
export ATROPOS_FLAIR_CLASSES=2
export ATROPOS_CONVERGENCE="1,0.0"
export ATROPOS_MRF="[0.1,1x1x1]"
export ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
export PADDING_X=5
export PADDING_Y=5
export PADDING_Z=5
export C3D_CROP_THRESHOLD=0.1
export C3D_PADDING_MM=5

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Using default paths for templates."
  export TEMPLATE_DIR="/usr/local/fsl/data/standard"
  # Don't exit - allow pipeline to continue with default paths
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
# Template resolutions - these can be automatically selected based on input resolution
export TEMPLATE_RESOLUTIONS=("1mm" "2mm")
export DEFAULT_TEMPLATE_RES="1mm"

# Templates for different resolutions
export EXTRACTION_TEMPLATE_1MM="MNI152_T1_1mm.nii.gz"
export PROBABILITY_MASK_1MM="MNI152_T1_1mm_brain_mask.nii.gz"
export REGISTRATION_MASK_1MM="MNI152_T1_1mm_brain_mask_dil.nii.gz"

export EXTRACTION_TEMPLATE_2MM="MNI152_T1_2mm.nii.gz"
export PROBABILITY_MASK_2MM="MNI152_T1_2mm_brain_mask.nii.gz"
export REGISTRATION_MASK_2MM="MNI152_T1_2mm_brain_mask_dil.nii.gz"

# Set initial defaults (will be updated based on detected image resolution)
export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"

# Supported modalities for registration to T1
export SUPPORTED_MODALITIES=("FLAIR" "T2" "SWI" "DWI" "TLE")

# Batch processing parameters
export  SUBJECT_LIST=""  # Path to subject list file for batch processing

# ------------------------------------------------------------------------------
# DICOM File Pattern Configuration (used by import.sh and qa.sh)
# ------------------------------------------------------------------------------
# DICOM pattern configuration for different scanner manufacturers
export DICOM_PRIMARY_PATTERN='Image*'  # Primary pattern to try first (matches Siemens MAGNETOM Image-00985 format)

# Space-separated list of additional patterns to try for different vendors:
# - *.dcm: Standard DICOM extension (all vendors)
# - IM_*: Philips format
# - Image*: Siemens format
# - *.[0-9][0-9][0-9][0-9]: Numbered format (GE and others)
# - DICOM*: Generic DICOM prefix
export DICOM_ADDITIONAL_PATTERNS="*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"

# Prioritize sagittal 3D sequences - these patterns match Siemens file naming conventions
# after DICOM to NIfTI conversion with dcm2niix

export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_.*.nii.gz"
export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS.*.nii.gz"
export RESAMPLE_TO_ISOTROPIC=0
export ISOTROPIC_SPACING=1.0

# Advanced registration options

# Auto-register all modalities to T1 (if false, only FLAIR is registered)
export AUTO_REGISTER_ALL_MODALITIES=false

# Auto-detect resolution and use appropriate template
# When true, the pipeline will select between 1mm and 2mm templates based on input image resolution
export AUTO_DETECT_RESOLUTION=true

# Additional vendor-specific optimizations are applied automatically
# based on the metadata extracted during import (field strength, manufacturer, model)

# ------------------------------------------------------------------------------
# Orientation Preservation Configuration
# ------------------------------------------------------------------------------
# These parameters control the orientation preservation during registration
# and the detection/correction of orientation distortions

# Enable or disable orientation preservation in registration
# When enabled, registration will use topology preservation constraints to
# maintain anatomical orientation relationships
export ORIENTATION_PRESERVATION_ENABLED=true

# Topology preservation parameters
# TOPOLOGY_CONSTRAINT_WEIGHT: Controls strength of topology preservation (0-1)
# Higher values enforce stronger orientation preservation but may reduce alignment accuracy
export TOPOLOGY_CONSTRAINT_WEIGHT=0.5

# TOPOLOGY_CONSTRAINT_FIELD: Deformation field constraints in x,y,z dimensions
# Format is "XxYxZ" where each value controls allowed deformation in that dimension
# Use "1x1x1" for equal constraints in all dimensions
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"

# Jacobian regularization parameters
# JACOBIAN_REGULARIZATION_WEIGHT: Weight for regularization (0-1)
# Higher values enforce smoother deformations and better preserve local orientation
export JACOBIAN_REGULARIZATION_WEIGHT=1.0

# REGULARIZATION_GRADIENT_FIELD_WEIGHT: Weight for gradient field orientation matching (0-1)
# Controls how strongly the registration tries to preserve orientation from the original image
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5

# Orientation correction thresholds
# ORIENTATION_CORRECTION_THRESHOLD: Mean angular deviation threshold to trigger correction
# If mean deviation exceeds this value (in radians), correction will be applied
export ORIENTATION_CORRECTION_THRESHOLD=0.3

# ORIENTATION_SCALING_FACTOR: Scaling factor for correction deformation field
# Lower values apply gentler corrections
export ORIENTATION_SCALING_FACTOR=0.05

# ORIENTATION_SMOOTH_SIGMA: Smoothing sigma for correction field (in mm)
# Higher values create smoother correction fields
export ORIENTATION_SMOOTH_SIGMA=1.5

# Quality thresholds for orientation metrics
# These thresholds determine the quality assessment of registration orientation
export ORIENTATION_EXCELLENT_THRESHOLD=0.1   # Mean angular deviation below this is excellent
export ORIENTATION_GOOD_THRESHOLD=0.2        # Mean angular deviation below this is good
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.3  # Mean angular deviation below this is acceptable

# Shearing detection threshold
# SHEARING_DETECTION_THRESHOLD: Threshold for detecting significant shearing in transformations
# Measures deviation from orthogonality (0-1), with lower values being more sensitive
export SHEARING_DETECTION_THRESHOLD=0.05
