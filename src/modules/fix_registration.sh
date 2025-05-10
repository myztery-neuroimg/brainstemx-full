#!/usr/bin/env bash

# fix_registration.sh - Direct ANTs SyN registration to bypass white matter segmentation issues
# 
# This script implements a direct ANTs SyN registration between T1 and FLAIR images
# without requiring white matter segmentation, avoiding the "Not enough classes detected 
# to init KMeans" error.

# Source the environment module to get the execute_ants_command function
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/src/modules/environment.sh"

# Create output directory
mkdir -p ../mri_results/validation/space/t1_flair/

# Run direct ANTs SyN registration without white matter guidance
echo "Running direct ANTs SyN registration..."
execute_ants_command "direct_syn" "Direct T1-to-FLAIR ANTs SyN registration without WM guidance" \
  antsRegistrationSyN.sh \
  -d 3 \
  -f ../mri_results/standardized/T1_MPRAGE_SAG_12a_n4_brain_std.nii.gz \
  -m ../mri_results/standardized/T2_SPACE_FLAIR_Sag_CS_17a_n4_brain_std.nii.gz \
  -o ../mri_results/validation/space/t1_flair/direct_syn_ \
  -t s \
  -n 12 \
  -p f \
  -x MI

# Check if registration was successful
if [ -f "../mri_results/validation/space/t1_flair/direct_syn_Warped.nii.gz" ]; then
    echo "Registration completed successfully"
    echo "Output file: ../mri_results/validation/space/t1_flair/direct_syn_Warped.nii.gz"
else
    echo "Registration failed - output file not found"
    echo "Check logs for error messages"
    exit 1
fi