#!/bin/bash

# Mock pipeline.sh for testing purposes
# This script simulates the core logic of the main pipeline for validation.

# Exit on error
set -e

# --- Source Environment and Config ---
# Source the main environment functions and variables
# shellcheck source=../src/modules/environment.sh
source "$(dirname "$0")/../src/modules/environment.sh"
# Source the lightweight test configuration
# shellcheck source=../config/test_config.sh
source "$(dirname "$0")/../config/test_config.sh"

# --- Argument Parsing ---
T1_INPUT=""
FLAIR_INPUT=""
export OUTPUT_DIR=$TEST_DIR
# OUTPUT_DIR is now set from test_config.sh, but allow override
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --t1) T1_INPUT="$2"; shift ;;
        --flair) FLAIR_INPUT="$2"; shift ;;
        --output-dir) export RESULTS_DIR="$2"; shift ;; # Override RESULTS_DIR
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Use RESULTS_DIR for output as per config
OUTPUT_DIR="$RESULTS_DIR"
mkdir -p "${OUTPUT_DIR}"
LOG_FILE="${OUTPUT_DIR}/log.txt" # Use the log file from the main test script

# --- Log Key Variables for Validation ---
echo "PIPELINE_REFERENCE_MODALITY=${PIPELINE_REFERENCE_MODALITY}" >> "${LOG_FILE}"
echo "T1_INPUT=${T1_INPUT}" >> "${LOG_FILE}"
echo "FLAIR_INPUT=${FLAIR_INPUT}" >> "${LOG_FILE}"
echo "OUTPUT_DIR=${OUTPUT_DIR}" >> "${LOG_FILE}"

# --- Reference Space Selection Logic ---
if [[ "${PIPELINE_REFERENCE_MODALITY}" == "T1" ]]; then
    REFERENCE_IMAGE="${T1_INPUT}"
    MOVING_IMAGE="${FLAIR_INPUT}"
    REFERENCE_BRAIN_OUTPUT="${OUTPUT_DIR}/T1_brain.nii.gz"
    REGISTRATION_OUTPUT="${OUTPUT_DIR}/FLAIR_to_T1.nii.gz"
    REGISTRATION_LOG_MSG="registering FLAIR to T1"
elif [[ "${PIPELINE_REFERENCE_MODALITY}" == "FLAIR" ]]; then
    REFERENCE_IMAGE="${FLAIR_INPUT}"
    MOVING_IMAGE="${T1_INPUT}"
    REFERENCE_BRAIN_OUTPUT="${OUTPUT_DIR}/FLAIR_brain.nii.gz"
    REGISTRATION_OUTPUT="${OUTPUT_DIR}/T1_to_FLAIR.nii.gz"
    REGISTRATION_LOG_MSG="registering T1 to FLAIR"
else
    echo "Invalid PIPELINE_REFERENCE_MODALITY: ${PIPELINE_REFERENCE_MODALITY}" >> "${LOG_FILE}"
    exit 1
fi

# --- Brain Extraction Simulation ---
log_message "Starting brain extraction on ${REFERENCE_IMAGE}" >> "${LOG_FILE}"
if command -v antsRegistration &> /dev/null; then
    log_message "Using ANTs for brain extraction." >> "${LOG_FILE}"
    # Simulate a template-free ANTs-based extraction
    touch "${REFERENCE_BRAIN_OUTPUT}"
else
    log_message "antsRegistration not found. Falling back to FSL BET." >> "${LOG_FILE}"
    # The mock 'bet' script is on the PATH and will be called
    bet "${REFERENCE_IMAGE}" "${REFERENCE_BRAIN_OUTPUT}"
    # The mock bet script creates ${REFERENCE_BRAIN_OUTPUT}_brain.nii.gz, so we move it
    mv "${REFERENCE_BRAIN_OUTPUT}_brain.nii.gz" "${REFERENCE_BRAIN_OUTPUT}"
fi
log_message "Brain extraction complete. Output: ${REFERENCE_BRAIN_OUTPUT}" >> "${LOG_FILE}"

# --- Registration Simulation ---
log_message "Starting registration: ${REGISTRATION_LOG_MSG}" >> "${LOG_FILE}"
# The mock 'antsRegistration' script is on the PATH and will be called
antsRegistration --dimensionality 3 --output "[${REGISTRATION_OUTPUT},${REGISTRATION_OUTPUT}]" --transform "Rigid[0.1]" --metric "MI[${REFERENCE_IMAGE},${MOVING_IMAGE},1,32]" --convergence 10 --smoothing-sigmas 0 --shrink-factors 1 --verbose 1

log_message "Registration complete. Output: ${REGISTRATION_OUTPUT}" >> "${LOG_FILE}"

# --- Final Analysis Simulation ---
log_message "Running final analysis in ${PIPELINE_REFERENCE_MODALITY} space." >> "${LOG_FILE}"
# Simulate some analysis steps that would happen in the chosen reference space
touch "${OUTPUT_DIR}/segmentation.nii.gz"
touch "${OUTPUT_DIR}/analysis_results.csv"

log_message "Mock pipeline finished successfully." >> "${LOG_FILE}"
