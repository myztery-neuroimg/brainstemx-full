#!/bin/bash
# Comprehensive fix for extracted_DICOM2 patterns

source config/default_config.sh
source config/dicom2_config.sh
# ===== OVERRIDE ALL HARDCODED PATTERNS =====

# Pipeline-level patterns (used in Step 2)
export T1_PRIORITY_PATTERN="*T1*.nii.gz"
export FLAIR_PRIORITY_PATTERN="*FLAIR*.nii.gz"

# Parallel config patterns (if used)
export T1_PRIORITY_PATTERN_PARALLEL=".*T1.*"
export FLAIR_PRIORITY_PATTERN_PARALLEL=".*FLAIR.*"

# Reference space selection patterns
export T1_SEARCH_PATTERNS=("*T1*.nii.gz" "*MPR*.nii.gz")
export FLAIR_SEARCH_PATTERNS=("*FLAIR*.nii.gz" "*T2*.nii.gz")

# Step 6 analysis patterns (used in pipeline.sh line ~800)
export ANALYSIS_T1_PATTERN="*T1*.nii.gz"
export ANALYSIS_FLAIR_PATTERN="*FLAIR*.nii.gz"

# ===== MANUAL FILE SPECIFICATION (MOST RELIABLE) =====
# Based on your file analysis, specify the exact best files:

# Best T1: T1W_3D_TFE_sag_KM_1001.nii.gz (0.5mm isotropic, 360×512×512)
export MANUAL_T1_FILE="../extracted_DICOM2/T1W_3D_TFE_sag_KM_1001.nii.gz"

# Only FLAIR: FLAIR_longTR_tra_401.nii.gz (0.53×0.53×5.5mm, 432×432×27)
export MANUAL_FLAIR_FILE="../extracted_DICOM2/FLAIR_longTR_tra_401.nii.gz"

# ===== SELECTION MODE CONFIGURATION =====
# Use T1 as reference space (better resolution and isotropic)
export PIPELINE_REFERENCE_MODALITY="T1"
export REFERENCE_SPACE_SELECTION_MODE="t1_priority"

# Selection modes for individual scans
export T1_SELECTION_MODE="highest_resolution"
export FLAIR_SELECTION_MODE="highest_resolution"
export SCAN_SELECTION_MODE="highest_resolution"

# ===== PROCESSING OPTIMIZATIONS =====
export QUALITY_PRESET="MEDIUM"
export DEFAULT_TEMPLATE_RES="1mm"  # Match your T1's high resolution

# Hyperintensity detection tuned for subtle lesions
export THRESHOLD_WM_SD_MULTIPLIER=1.5
export MIN_HYPERINTENSITY_SIZE=3

# ===== PATTERN OVERRIDE FUNCTIONS =====
# Override the hardcoded find commands in the pipeline

# Function to replace hardcoded T1 search
find_t1_files() {
    local search_dir="$1"
    if [ -n "$MANUAL_T1_FILE" ] && [ -f "$MANUAL_T1_FILE" ]; then
        echo "$MANUAL_T1_FILE"
    else
        find "$search_dir" -name "*T1*.nii.gz" ! -name "*Mask*" ! -name "*mask*" ! -name "*brain*" | sort
    fi
}

# Function to replace hardcoded FLAIR search  
find_flair_files() {
    local search_dir="$1"
    if [ -n "$MANUAL_FLAIR_FILE" ] && [ -f "$MANUAL_FLAIR_FILE" ]; then
        echo "$MANUAL_FLAIR_FILE"
    else
        find "$search_dir" -name "*FLAIR*.nii.gz" ! -name "*Mask*" ! -name "*mask*" ! -name "*brain*" | sort
    fi
}

# Export functions
export -f find_t1_files
export -f find_flair_files

# ===== DEBUGGING =====
export PIPELINE_VERBOSITY="verbose"

echo "DICOM2 comprehensive fix loaded:"
echo "  T1 pattern: $T1_PRIORITY_PATTERN"
echo "  FLAIR pattern: $FLAIR_PRIORITY_PATTERN"
echo "  Manual T1: $MANUAL_T1_FILE"
echo "  Manual FLAIR: $MANUAL_FLAIR_FILE"
echo "  Reference modality: $PIPELINE_REFERENCE_MODALITY"
