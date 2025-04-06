#!/usr/bin/env bash
source config/default_config.sh
source modules/environment.sh

# Fixed inputs
export t1_file="../extracted/T1_MPRAGE_SAG_13j.nii.gz"
export flair_file="../extracted/T2_SPACE_FLAIR_Sag_CS_1041p.nii.gz"
#export SUBJECT_ID="subject1"
export RESULTS_DIR="../mri_results"
export LOG_DIR="${RESULTS_DIR}/logs"

mkdir -p "$LOG_DIR"

# Resume from preprocessing forward
source modules/preprocess.sh
source modules/registration.sh
source modules/segmentation.sh
source modules/analysis.sh
source modules/visualization.sh
