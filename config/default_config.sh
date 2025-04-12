!/usr/bin/env bash
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
export SRC_DIR="${HOME}/workspace/DICOM"          # DICOM input directory
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix
export RESULTS_DIR="../mri_results"
export ANTS_PATH="~/ants"
export PATH="$PATH:${ANTS_PATH}/bin"
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
export REG_METRIC_CROSS_MODALITY="MI"
export REG_METRIC_SAME_MODALITY="CC"
export ANTS_THREADS=24
export REG_PRECISION=1

# Hyperintensity detection
export HRESHOLD_WM_SD_MULTIPLIER=1.5 #Standard devications from local norm
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
  log_formatted "WARNING" "FSLDIR not set. Template references may fail."
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
export EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
export PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
export  REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"

# Batch processing parameters
export  SUBJECT_LIST=""  # Path to subject list file for batch processing

# ------------------------------------------------------------------------------
# DICOM File Pattern Configuration (used by import.sh and qa.sh)
# ------------------------------------------------------------------------------
export DICOM_PRIMARY_PATTERN='Image-[0-9]*'  # Primary pattern to try first (matches Siemens MAGNETOM Image-00985 format)
# Currently not well implemented

export DICOM_ADDITIONAL_PATTERNS="*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"  # Space-separated list of additional patterns to try
# Prioritize sagittal 3D sequences explicitly
# Super hackery, adjust for yourself.. this works with Siemens scanners which primarily scan in sagital orientation for 3D scans I thiink

export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_.*.nii.gz"
export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS.*.nii.gz"
export RESAMPLE_TO_ISOTROPIC=0
export ISOTROPIC_SPACING=1.0
