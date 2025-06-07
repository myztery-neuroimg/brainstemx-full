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
export SRC_DIR="${HOME}/DICOM"          # DICOM input directory
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
export OUTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
export QUALITY_PRESET="HIGH"
export MAX_CPU_INTENSIVE_JOBS=1

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
#export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="200x200x200x50,0.0000001,1000,2"
export N4_PRESET_MEDIUM="500x500x500x50,0.00000901,2000,2"
export N4_PRESET_FLAIR="$N4_PRESET_MEDIUM"  # override if needed

export PARALLEL_JOBS=0

# DICOM-specific parallel processing (only affects DICOM import)
export DICOM_IMPORT_PARALLEL=12

export QUALITY_PRESET="MEDIUM"
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
export ANTS_THREADS=48                 # Number of threads for ANTs processing
export REG_PRECISION=3                 # Registration precision (higher = more accurate but slower)

# ANTs specific parameters - if not set, ANTs will use defaults
# export METRIC_SAMPLING_STRATEGY="NONE"  # Options: NONE (use all voxels), REGULAR, RANDOM
# export METRIC_SAMPLING_PERCENTAGE=1.0   # Percentage of voxels to sample (when not NONE)

# Hyperintensity detection
export THRESHOLD_WM_SD_MULTIPLIER=1.25 #Standard deviations from local norm
export MIN_HYPERINTENSITY_SIZE=4

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
  log_formatted "WARNING" "FSLDIR not set. Template references may fail."
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
export DISABLE_DEDUPLICATION="true"
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
export DICOM_PRIMARY_PATTERN=Image*  # Primary pattern to try first (matches Siemens MAGNETOM Image-00985 format)

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

# Scan selection options
# Available modes:
#   original - ONLY consider ORIGINAL acquisitions, ignore DERIVED scans
#   highest_resolution - Prioritize scans with highest resolution (default)
#   registration_optimized - Prioritize scans with aspect ratios similar to reference
#   matched_dimensions - Prioritize scans with exact dimensions matching reference
#   interactive - Show available scans and prompt for manual selection
export SCAN_SELECTION_MODE="original"
export T1_SELECTION_MODE="original"    # For T1, always prefer ORIGINAL acquisitions
export FLAIR_SELECTION_MODE="original"  # For FLAIR, always prefer ORIGINAL"  as we want to eliminate noise from the pipeline for brainstem lesions

# Advanced registration options

# Auto-register all modalities to T1 (if false, only FLAIR is registered)
export AUTO_REGISTER_ALL_MODALITIES=false

# Auto-detect resolution and use appropriate template
# When true, the pipeline will select between 1mm and 2mm templates based on input image resolution
export AUTO_DETECT_RESOLUTION=true

# Additional vendor-specific optimizations are applied automatically
# based on the metadata extracted during import (field strength, manufacturer, model)

# ------------------------------------------------------------------------------
# Orientation and Datatype Parameters
# ------------------------------------------------------------------------------

# Orientation correction settings
export ORIENTATION_CORRECTION_ENABLED=false   # Disable automatic orientation correction
export ORIENTATION_VALIDATION_ENABLED=false   # Disable validation
export HALT_ON_ORIENTATION_MISMATCH=true      # Halt pipeline on orientation mismatch (if validation enabled)

# Expected orientation for validation
export EXPECTED_QFORM_X="Left-to-Right"
export EXPECTED_QFORM_Y="Posterior-to-Anterior"
export EXPECTED_QFORM_Z="Inferior-to-Superior"

# Datatype configuration
export PRESERVE_INTENSITY_IMAGES_DATATYPE=true  # Keep intensity images as FLOAT32
export CONVERT_MASKS_TO_UINT8=true  # Convert binary masks to UINT8
