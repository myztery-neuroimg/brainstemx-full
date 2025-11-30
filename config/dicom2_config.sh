#!/bin/bash
# Configuration for extracted_DICOM2 files

source "config/default_config.sh" #add this to get default configs first

# Set patterns that match your actual files
export T1_PRIORITY_PATTERN="*T1*.nii.gz"
export FLAIR_PRIORITY_PATTERN="*FLAIR*.nii.gz"

# Enable interactive selection for BOTH levels
export REFERENCE_SPACE_SELECTION_MODE="interactive"
export T1_SELECTION_MODE="interactive"
export FLAIR_SELECTION_MODE="interactive"

# Other optimizations for your data
export QUALITY_PRESET="MEDIUM"
export DEFAULT_TEMPLATE_RES="1mm"  # T1W_3D_TFE_sag_KM_1001 is 0.5mm isotropic
export THRESHOLD_WM_SD_MULTIPLIER=1.5

# Use T1 as reference (since you have excellent isotropic T1)
export PIPELINE_REFERENCE_MODALITY="T1"

# Enable broader search patterns
export SCAN_SELECTION_MODE="interactive"
export EXTRACT_DIR="../extracted_DICOM2"
