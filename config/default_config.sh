#!/usr/bin/env bash
#
# default_config.sh - Default configuration for the brain MRI processing pipeline
#
# This file contains default configuration parameters for the pipeline.
# Users can override these parameters by creating a custom configuration file
# and passing it to the pipeline using the -c/--config option.
#

# Moved from environment.sh
# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export DICOM_PRIMARY_PATTERN='Image"*"'   # Filename pattern for your DICOM files, might be .dcm on some scanners, Image- for Siemens
export PIPELINE_SUCCESS=true       # Track overall pipeline success
export PIPELINE_ERROR_COUNT=0      # Count of errors in pipeline

# Parallelization configuration (defaults, can be overridden by config file)
export PARALLEL_JOBS=1             # Number of parallel jobs to use
export MAX_CPU_INTENSIVE_JOBS=1    # Number of jobs for CPU-intensive operations
export PARALLEL_TIMEOUT=0          # Timeout for parallel operations (0 = no timeout)
export PARALLEL_HALT_MODE="soon"   # How to handle failed parallel jobs

export EXTRACT_DIR="../extracted"
export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
mkdir -p "$EXTRACT_DIR"

# Set ANTs Path relative to the script location
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Ensure ANTS_PATH is properly expanded
export ANTS_PATH="${ANTS_PATH}"
# Replace tilde with $HOME if present
export ANTS_PATH="${ANTS_PATH/#\~/$HOME}"
export ANTS_BIN="${ANTS_PATH}/bin"
# Log ANTs paths for debugging
log_message "ANTs paths: ANTS_PATH=$ANTS_PATH, ANTS_BIN=$ANTS_BIN"
# Flag to toggle ANTs SyN vs FLIRT linear registration
export USE_ANTS_SYN="${USE_ANTS_SYN:-false}"
log_message "USE_ANTS_SYN=$USE_ANTS_SYN"

export CORES="$(cpuinfo  | grep -i count | sed 's/.* //')"
export ANTS_THREADS=$CORES  # Use most but not all cores

# Add ANTs to PATH if it exists
if [ -d "$ANTS_BIN" ]; then
  export PATH="$PATH:${ANTS_BIN}"
  log_formatted "INFO" "Added ANTs bin directory to PATH: $ANTS_BIN"
  # Set ANTs/ITK threading variables for proper parallelization
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$ANTS_THREADS"
  export OMP_NUM_THREADS="$ANTS_THREADS"
  export ANTS_RANDOM_SEED=1234
  log_formatted "INFO" "Set parallel processing variables: ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$ANTS_THREADS, OMP_NUM_THREADS=$ANTS_THREADS"
else
  log_formatted "ERROR" "ANTs bin directory not found: $ANTS_BIN"
fi

# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="${HOME}/DICOM"        # DICOM input directory
# ANTs configuration
export ANTS_BIN="${ANTS_PATH}/bin"  # Directory containing ANTs binaries
export PATH="$PATH:${ANTS_BIN}"
export LOG_DIR="${RESULTS_DIR}/logs"
export RESULTS_DIR="../mri_results"
# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
export PROCESSING_DATATYPE="float"  # internal float
export OUTPUT_DATATYPE="int"        # final int16

# Atlas and template configuration
export DEFAULT_TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-1mm}"

# Joint fusion specific parameters
export JOINT_FUSION_ALPHA="${JOINT_FUSION_ALPHA:-0.1}"      # Label smoothing
export JOINT_FUSION_BETA="${JOINT_FUSION_BETA:-2.0}"        # Spatial regularization
export JOINT_FUSION_PATCH_RADIUS="${JOINT_FUSION_PATCH_RADIUS:-2}"
export JOINT_FUSION_SEARCH_RADIUS="${JOINT_FUSION_SEARCH_RADIUS:-3}"

# ANTs registration parameters (existing)
export REG_TRANSFORM_TYPE="${REG_TRANSFORM_TYPE:-2}"  # SyN registration
# Quality settings (LOW, MEDIUM, HIGH)
export MAX_CPU_INTENSIVE_JOBS=1
# N4 Bias Field Correction presets: "iterations,convergence_threshold,spline_distance_mm,shrink_factor"
# Spline distance: larger values = coarser fit = faster; smaller values = finer fit = slower
export N4_PRESET_VERY_LOW="20x20x20,0.0001,1x1x3,2"
export N4_PRESET_LOW="35x35x35,0.00025,2x2x3,2"
export N4_PRESET_MEDIUM="70x70x70,0.0001,2x2x3,2"
export N4_PRESET_HIGH="100x100x100,0.00005,2x2x3,2"
export N4_PRESET_ULTRA="250x250x250x3,0.00001,2x2x3,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # Use more conservative settings for FLAIR

export PARALLEL_JOBS=0

# DICOM-specific parallel processing (only affects DICOM import)
export DICOM_IMPORT_PARALLEL=12

export QUALITY_PRESET="HIGH"


export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$CORES
export OMP_NUM_THREADS=$CORES
export VECLIB_MAXIMUM_THREADS=$CORES
export OPENBLAS_NUM_THREADS=$CORES

if [[ "$CORES" -le 4 ]]; then  
  # VM or container -level optimisations 
  export MACHINE_SPEC="VERY_LOW"
  export QUALITY_PRESET="VERY_LOW"
  export ANTS_MEMORY_LIMIT="4G"
elif [[ "$CORES" -le 8 ]]; then   
  # Larger VM or lower-spec Mac 
  export MACHINE_SPEC="LOW"
  export QUALITY_PRESET="LOW"
  export ANTS_MEMORY_LIMIT="8G"
elif [[ "$CORES" -le 18 ]]; then   
  # MacBook Pro -level optimisations
  export MACHINE_SPEC="MEDIUM"
  export QUALITY_PRESET="MEDIUM"
  # Use all available memory efficiently
  export ANTS_MEMORY_LIMIT="14G"  # Adjust based on actual RAM
  # Optimize for Apple Silicon
else   
  # Mac Studio-level optimizations
  export MACHINE_SPEC="HIGH"
  export QUALITY_PRESET="MEDIUM"
  export ANTS_THREADS=28  # Use most but not all cores
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=28
  export OMP_NUM_THREADS=28
  export ANTS_MEMORY_LIMIT="64G"  # Adjust based on actual RAM
  export VECLIB_MAXIMUM_THREADS=28
  export OPENBLAS_NUM_THREADS=28
fi

echo "QUALITY_PRESET: ${QUALITY_PRESET} ANTS_THREADS:${ANTS_THREADS}" >&2

# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" == "ULTRA" ]; then
    export N4_PARAMS="$N4_PRESET_ULTRA"
    export N4_PRESET_FLAIR="$N4_PRESET_ULTRA"
elif [ "$QUALITY_PRESET" == "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
    export N4_PRESET_FLAIR="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" == "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
    export N4_PRESET_FLAIR="$N4_PRESET_MEDIUM"
elif [ "$QUALITY_PRESET" == "LOW" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
    export N4_PRESET_FLAIR="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_VERY_LOW"
    export N4_PRESET_FLAIR="$N4_PRESET_VERY_LOW"
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
export TEMPLATE_ITERATIONS=3
export TEMPLATE_GRADIENT_STEP=0.05
export TEMPLATE_TRANSFORM_MODEL="SyN"
export TEMPLATE_SIMILARITY_METRIC="CC"
export TEMPLATE_SHRINK_FACTORS="6x4x2x1"
export TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
export TEMPLATE_WEIGHTS="100x100x100x10"

# Registration & motion correction
export REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
export REG_METRIC_CROSS_MODALITY="MI"  # Mutual Information - for cross-modality (T1-FLAIR)
export REG_METRIC_SAME_MODALITY="CC"   # Cross Correlation - for same modality
export REG_PRECISION=3                 # Registration precision (higher = more accurate but slower)

# ANTs specific parameters - if not set, ANTs will use defaults
# export METRIC_SAMPLING_STRATEGY="NONE"  # Options: NONE (use all voxels), REGULAR, RANDOM
# export METRIC_SAMPLING_PERCENTAGE=1.0   # Percentage of voxels to sample (when not NONE)

# Hyperintensity detection
export THRESHOLD_WM_SD_MULTIPLIER=1.2  #Standard deviations from local norm
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
  log_formatted "ERROR" "FSLDIR not set. Template references may fail."
  exit 1
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
export DISABLE_DEDUPLICATION="false"

# Set initial defaults (will be updated based on detected image resolution)
export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"

# Supported modalities for registration to T1
export SUPPORTED_MODALITIES=("FLAIR" "SWI" "DWI" "TLE" "COR")

# Batch processing parameters
export  SUBJECT_LIST=""  # Path to subject list file for batch processing

# ------------------------------------------------------------------------------
# DICOM File Pattern Configuration (used by import.sh and qa.sh)
# ------------------------------------------------------------------------------
# DICOM pattern configuration for different scanner manufacturers
export DICOM_PRIMARY_PATTERN=I*  # Primary pattern to try first (matches Siemens MAGNETOM Image-00985 format)

# Space-separated list of additional patterns to try for different vendors:
# - *.dcm: Standard DICOM extension (all vendors)
# - IM_*: Philips format
# - Image*: Siemens format
# - *.[0-9][0-9][0-9][0-9]: Numbered format (GE and others)
# - DICOM*: Generic DICOM prefix
export DICOM_ADDITIONAL_PATTERNS="*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"

# Prioritize sagittal 3D sequences - these patterns match Siemens file naming conventions
# after DICOM to NIfTI conversion with dcm2niix

export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_12.nii.gz" #hack
export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS_17.nii.gz" #hack
export RESAMPLE_TO_ISOTROPIC=false
#export ISOTROPIC_SPACING=1.0
#unset ISOTROPIC_SPACING

# Scan selection options
# Available modes:
#   original - ONLY consider ORIGINAL acquisitions, ignore DERIVED scans
#   highest_resolution - Prioritize scans with highest resolution (default)
#   registration_optimized - Prioritize scans with aspect ratios similar to reference
#   matched_dimensions - Prioritize scans with exact dimensions matching reference
#   interactive - Show available scans and prompt for manual selection
export SCAN_SELECTION_MODE="interactive"
export T1_SELECTION_MODE="interactive"    # For T1, always prefer matched_dimensions
export FLAIR_SELECTION_MODE="interactive"  # For FLAIR generally prefer ORIGINAL  as we want to eliminate noise from the post-processing of the scanner software for brainstem lesions. Howeverthat post-processing does add valuable resolution, so try different options

# Advanced registration options

# Auto-register all modalities to T1 (if false, only FLAIR is registered)
export AUTO_REGISTER_ALL_MODALITIES=true

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
export orientation_preservation=false
export HALT_ON_ORIENTATION_MISMATCH=false      # Halt pipeline on orientation mismatch (if validation enabled)

# Expected orientation for validation
export EXPECTED_QFORM_X="Left-to-Right"
export EXPECTED_QFORM_Y="Posterior-to-Anterior"
export EXPECTED_QFORM_Z="Inferior-to-Superior"

# Datatype configuration
export PRESERVE_INTENSITY_IMAGES_DATATYPE=true  # Keep intensity images as FLOAT32
export CONVERT_MASKS_TO_UINT8=true  # Convert binary masks to UINT8

#export ORIGINAL_ACQUISITION_WEIGHT=1000
export USE_ANTS_SYN=true

# Parse out FLAIR-specific fields
N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Registration & motion correction
export REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
export REG_METRIC_CROSS_MODALITY="MI"
export REG_METRIC_SAME_MODALITY="CC"
export REG_PRECISION=1

# White matter guided registration parameters
export WM_GUIDED_DEFAULT=true  # Default to use white matter guided registration
export WM_INIT_TRANSFORM_PREFIX="_wm_init"  # Prefix for WM-guided initialization transforms
export WM_MASK_SUFFIX="_wm_mask.nii.gz"  # Suffix for white matter mask files
export WM_THRESHOLD_VAL=3  # Threshold value for white matter segmentation (class 3 in Atropos)

# Orientation distortion correction parameters
# Main toggle
export ORIENTATION_PRESERVATION_ENABLED=true

# Topology preservation parameters
export TOPOLOGY_CONSTRAINT_WEIGHT=0.5
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"

# Jacobian regularization parameters
export JACOBIAN_REGULARIZATION_WEIGHT=1.0
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5

# Correction thresholds
export ORIENTATION_CORRECTION_THRESHOLD=0.3
export ORIENTATION_SCALING_FACTOR=0.05
export ORIENTATION_SMOOTH_SIGMA=1.5

# Quality assessment thresholds
export ORIENTATION_EXCELLENT_THRESHOLD=0.1
export ORIENTATION_GOOD_THRESHOLD=0.2
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.3
export SHEARING_DETECTION_THRESHOLD=0.05

# Hyperintensity detection
export MIN_HYPERINTENSITY_SIZE=6

# Tissue segmentation parameters
export ATROPOS_T1_CLASSES=3
export ATROPOS_FLAIR_CLASSES=4
export ATROPOS_CONVERGENCE="5,0.0"
export ATROPOS_MRF="[0.1,1x1x1]"
export ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
export PADDING_X=5
export PADDING_Y=5
export PADDING_Z=5
export C3D_CROP_THRESHOLD=0.1
export C3D_PADDING_MM=5

