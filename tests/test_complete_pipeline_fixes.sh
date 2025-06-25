#!/bin/bash

# Test script for complete pipeline fixes (Phase 3)
# Validates Phase 1 (MNI-free brain extraction) and Phase 2 (unified reference space management)

# Exit on error
set -e

# --- Test Setup ---

# Create a temporary directory for test data and outputs
export TEST_DIR=$(mktemp -d)
echo "Running tests in ${TEST_DIR}"

# Explicitly define LOG_DIR within the temporary directory
export LOG_DIR="${TEST_DIR}/logs"
mkdir -p $LOG_DIR
export LOGS=$LOG_DIR
# Mock data and scripts will be created here
MOCK_DATA_DIR="${TEST_DIR}/mock_data"
MOCK_SCRIPTS_DIR="${TEST_DIR}/mock_scripts"

# Add mock scripts to path
export PATH="${MOCK_SCRIPTS_DIR}:${PATH}"

# Source environment and test configuration.
# This order is important. TEST_DIR must be exported before sourcing the config.
# shellcheck source=../src/modules/environment.sh
source "$(dirname "$0")/../src/modules/environment.sh"
# shellcheck source=../config/test_config.sh
source "$(dirname "$0")/../config/test_config.sh"
export LOG_DIR="$LOGS"
# Create the log directory now that the config has been sourced

# --- Mock Functions and Data Setup ---

setup_mock_data() {
    echo "Setting up mock data..."
    mkdir -p "${MOCK_DATA_DIR}"
    # RESULTS_DIR is created by the test_config.sh, but ensure it exists
    mkdir -p "${RESULTS_DIR}"

    # Create dummy NIfTI files
    touch "${MOCK_DATA_DIR}/T1.nii.gz"
    touch "${MOCK_DATA_DIR}/FLAIR.nii.gz"
}

setup_mock_scripts() {
    echo "Setting up mock scripts..."
    mkdir -p "${MOCK_SCRIPTS_DIR}"

    # Mock ANTs
    cat > "${MOCK_SCRIPTS_DIR}/antsRegistration" <<'EOF'
#!/bin/bash
echo "antsRegistration called with: $@" >> "${TEST_DIR}/log.txt"
# Create a dummy output file
touch "$3"
EOF
    chmod +x "${MOCK_SCRIPTS_DIR}/antsRegistration"

    # Mock FSL BET
    cat > "${MOCK_SCRIPTS_DIR}/bet" <<'EOF'
#!/bin/bash
echo "bet called with: $@" >> "${TEST_DIR}/log.txt"
# Create a dummy output file
touch "$2_brain.nii.gz"
EOF
    chmod +x "${MOCK_SCRIPTS_DIR}/bet"

    # Mock other FSL tools
    for tool in fslmaths flirt; do
        cat > "${MOCK_SCRIPTS_DIR}/${tool}" <<EOF
#!/bin/bash
echo "${tool} called with: \$@" >> "\${TEST_DIR}/log.txt"
touch "\${!#}" # touch the last argument (usually output file)
EOF
        chmod +x "${MOCK_SCRIPTS_DIR}/${tool}"
    done
}

# --- Assertion Helpers ---

assert_file_exists() {
    if [ ! -f "$1" ]; then
        echo "Assertion failed: File $1 does not exist."
        exit 1
    fi
    echo "Assertion passed: File $1 exists."
}

assert_log_contains() {
    if ! grep -q "$1" "${TEST_DIR}/log.txt"; then
        echo "Assertion failed: Log does not contain '$1'."
        echo "Log content:"
        cat "${TEST_DIR}/log.txt"
        exit 1
    fi
    echo "Assertion passed: Log contains '$1'."
}

# --- Test Scenarios ---

test_scenario_A_t1_reference() {
    echo "--- Running Scenario A: T1 as reference ---"
    # Reset log
    > "${TEST_DIR}/log.txt"

    # Run the pipeline
    local scenario_output_dir="${RESULTS_DIR}/scenario_A"
    mkdir -p "$scenario_output_dir"
    PIPELINE_REFERENCE_MODALITY="T1" \
    bash "$(dirname "$0")/mock_pipeline.sh" \
        --t1 "${MOCK_DATA_DIR}/T1.nii.gz" \
        --flair "${MOCK_DATA_DIR}/FLAIR.nii.gz" \
        --output-dir "$scenario_output_dir"

    # Validations
    assert_log_contains "PIPELINE_REFERENCE_MODALITY=T1"
    assert_log_contains "registering FLAIR to T1"
    assert_file_exists "${scenario_output_dir}/T1_brain.nii.gz"
    assert_file_exists "${scenario_output_dir}/FLAIR_to_T1.nii.gz"
    echo "--- Scenario A Passed ---"
}

test_scenario_B_flair_reference() {
    echo "--- Running Scenario B: FLAIR as reference ---"
    # Reset log
    > "${TEST_DIR}/log.txt"

    # Run the pipeline
    local scenario_output_dir="${RESULTS_DIR}/scenario_B"
    mkdir -p "$scenario_output_dir"
    PIPELINE_REFERENCE_MODALITY="FLAIR" \
    bash "$(dirname "$0")/mock_pipeline.sh" \
        --t1 "${MOCK_DATA_DIR}/T1.nii.gz" \
        --flair "${MOCK_DATA_DIR}/FLAIR.nii.gz" \
        --output-dir "$scenario_output_dir"

    # Validations
    assert_log_contains "PIPELINE_REFERENCE_MODALITY=FLAIR"
    assert_log_contains "registering T1 to FLAIR"
    assert_file_exists "${scenario_output_dir}/FLAIR_brain.nii.gz"
    assert_file_exists "${scenario_output_dir}/T1_to_FLAIR.nii.gz"
    echo "--- Scenario B Passed ---"
}

test_scenario_C_bet_fallback() {
    echo "--- Running Scenario C: Brain extraction fallback to FSL BET ---"
    # Reset log
    > "${TEST_DIR}/log.txt"

    # Remove ANTs from path to simulate it being unavailable
    rm "${MOCK_SCRIPTS_DIR}/antsRegistration"

    # Run the pipeline
    local scenario_output_dir="${RESULTS_DIR}/scenario_C"
    mkdir -p "$scenario_output_dir"
    PIPELINE_REFERENCE_MODALITY="T1" \
    bash "$(dirname "$0")/mock_pipeline.sh" \
        --t1 "${MOCK_DATA_DIR}/T1.nii.gz" \
        --flair "${MOCK_DATA_DIR}/FLAIR.nii.gz" \
        --output-dir "$scenario_output_dir"

    # Validations
    assert_log_contains "antsRegistration not found. Falling back to FSL BET."
    assert_log_contains "bet called with"
    assert_file_exists "${scenario_output_dir}/T1_brain.nii.gz"
    echo "--- Scenario C Passed ---"

    # Restore mock script for other tests
    setup_mock_scripts
}


# --- Main Test Runner ---

main() {
    setup_mock_data
    setup_mock_scripts

    # Run tests
    test_scenario_A_t1_reference
    test_scenario_B_flair_reference
    test_scenario_C_bet_fallback

    echo "All tests passed successfully!"
}

# --- Cleanup ---

cleanup() {
    echo "Cleaning up test directory: ${TEST_DIR}"
    rm -rf "${TEST_DIR}"
}

# Run main function and cleanup on exit
trap cleanup EXIT
main

fi
