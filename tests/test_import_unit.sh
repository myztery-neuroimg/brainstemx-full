#!/usr/bin/env bash
#
# test_import_unit.sh - Unit tests for src/modules/import.sh
#
# Tests:
#   - import_extract_metadata (DICOM file discovery, fallback metadata)
#   - import_convert_dicom_to_nifti (dcm2niix invocation, fallback paths)
#   - import_validate_nifti_files (valid/empty directories)
#   - import_dicom_data (end-to-end import orchestration)
#   - Function availability after module load
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
init_test_suite "import.sh Unit Tests"
setup_test_environment

# Create mocks for all external tools import.sh may call
create_mock_fslinfo
create_mock_fslstats
create_mock_fslmaths
create_mock_dcm2niix
create_mock_dcmdump

# Source environment.sh first (required by import.sh)
load_environment_module

# Now source import.sh.
# import.sh will try to source dicom_analysis.sh from various paths,
# and may emit warnings - suppress stderr to keep test output clean.
if [[ -f "$PROJECT_ROOT/src/modules/import.sh" ]]; then
    source "$PROJECT_ROOT/src/modules/import.sh" 2>/dev/null || true
    echo "Loaded import.sh"
else
    echo -e "${RED}ERROR: import.sh not found${NC}"
    exit 1
fi

# Also load dicom_analysis.sh if available (some tests check its integration)
if [[ -f "$PROJECT_ROOT/src/modules/dicom_analysis.sh" ]]; then
    source "$PROJECT_ROOT/src/modules/dicom_analysis.sh" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1. Function Availability
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Function Availability"

assert_function_exists "import_dicom_data"              "import_dicom_data defined"
assert_function_exists "import_convert_dicom_to_nifti"  "import_convert_dicom_to_nifti defined"
assert_function_exists "import_extract_metadata"        "import_extract_metadata defined"
assert_function_exists "import_validate_nifti_files"    "import_validate_nifti_files defined"
assert_function_exists "import_process_all_nifti_files_in_dir" "import_process_all_nifti_files_in_dir defined"
assert_function_exists "process_dicom_series"           "process_dicom_series defined"

# ══════════════════════════════════════════════════════════════════════════════
# 4. import_extract_metadata
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. import_extract_metadata"

# 4a: Non-existent DICOM directory creates fallback metadata
export RESULTS_DIR="$TEMP_TEST_DIR/results_meta"
mkdir -p "$RESULTS_DIR"
PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

set +e
import_extract_metadata "$TEMP_TEST_DIR/nonexistent_dicom" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_extract_metadata returns 0 for missing DICOM dir (graceful degradation)"
assert_file_exists "$RESULTS_DIR/metadata/scanner_params.json" \
    "Fallback scanner_params.json created for missing dir"

# Check that fallback JSON has required fields
content=$(cat "$RESULTS_DIR/metadata/scanner_params.json")
assert_contains "$content" "manufacturer" \
    "Fallback metadata contains manufacturer field"
assert_contains "$content" "fieldStrength" \
    "Fallback metadata contains fieldStrength field"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# 4b: Directory with DICOM files (using Image* primary pattern)
export RESULTS_DIR="$TEMP_TEST_DIR/results_meta2"
mkdir -p "$RESULTS_DIR"
mkdir -p "$TEMP_TEST_DIR/dicom_with_files"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_with_files/Image0001" "SIEMENS" "Skyra" "VE11C"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_with_files/Image0002" "SIEMENS" "Skyra" "VE11C"

set +e
import_extract_metadata "$TEMP_TEST_DIR/dicom_with_files" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_extract_metadata returns 0 for dir with DICOM files"
assert_file_exists "$RESULTS_DIR/metadata/scanner_params.json" \
    "scanner_params.json created for dir with DICOM files"

# 4c: Empty directory with no DICOM files
export RESULTS_DIR="$TEMP_TEST_DIR/results_meta3"
mkdir -p "$RESULTS_DIR"
mkdir -p "$TEMP_TEST_DIR/empty_dicom"

set +e
import_extract_metadata "$TEMP_TEST_DIR/empty_dicom" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_extract_metadata returns 0 for empty DICOM dir (uses default metadata)"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 5. import_convert_dicom_to_nifti
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. import_convert_dicom_to_nifti"

# 5a: Successful conversion with mock dcm2niix
export RESULTS_DIR="$TEMP_TEST_DIR/results_conv"
mkdir -p "$RESULTS_DIR/logs"
export LOG_DIR="$RESULTS_DIR/logs"
export LOG_FILE="$LOG_DIR/test.log"
: > "$LOG_FILE"

export DICOM_PRIMARY_PATTERN="Image*"
mkdir -p "$TEMP_TEST_DIR/dicom_conv"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_conv/Image001"

set +e
import_convert_dicom_to_nifti "$TEMP_TEST_DIR/dicom_conv" "$TEMP_TEST_DIR/nifti_out" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_convert_dicom_to_nifti returns 0 with mock dcm2niix"

# Check that mock dcm2niix created output files
nifti_count=$(find "$TEMP_TEST_DIR/nifti_out" -name "*.nii.gz" 2>/dev/null | wc -l)
assert_not_equals "0" "$nifti_count" \
    "Mock dcm2niix produced NIfTI output files"

# 5b: No dcm2niix available
saved_path="$PATH"
export PATH="/usr/bin:/bin"
mkdir -p "$TEMP_TEST_DIR/dicom_conv2"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_conv2/Image001"

set +e
import_convert_dicom_to_nifti "$TEMP_TEST_DIR/dicom_conv2" "$TEMP_TEST_DIR/nifti_out2" 2>/dev/null
ec=$?
set -e
assert_not_equals "0" "$ec" \
    "import_convert_dicom_to_nifti fails when dcm2niix not available"
export PATH="$saved_path"
# Re-add mocks to PATH
create_mock_dcm2niix
create_mock_fslinfo

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 6. import_validate_nifti_files
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "6. import_validate_nifti_files"

# 6a: Directory with valid NIfTI files
mkdir -p "$TEMP_TEST_DIR/nifti_valid"
create_fake_nifti "$TEMP_TEST_DIR/nifti_valid/t1.nii.gz" 20
create_fake_nifti "$TEMP_TEST_DIR/nifti_valid/flair.nii.gz" 20

set +e
import_validate_nifti_files "$TEMP_TEST_DIR/nifti_valid" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_validate_nifti_files returns 0 for valid NIfTI files"

# 6b: Empty directory (no NIfTI files)
mkdir -p "$TEMP_TEST_DIR/nifti_empty"

set +e
import_validate_nifti_files "$TEMP_TEST_DIR/nifti_empty" 2>/dev/null
ec=$?
set -e
assert_not_equals "0" "$ec" \
    "import_validate_nifti_files returns non-zero for empty dir"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 7. import_dicom_data (end-to-end with mocks)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "7. import_dicom_data (end-to-end)"

export RESULTS_DIR="$TEMP_TEST_DIR/results_e2e"
export LOG_DIR="$RESULTS_DIR/logs"
export LOG_FILE="$LOG_DIR/test.log"
export EXTRACT_DIR="$TEMP_TEST_DIR/e2e_extract"
export DICOM_IMPORT_PARALLEL=1  # Force sequential for test simplicity
export DICOM_PRIMARY_PATTERN="Image*"
mkdir -p "$RESULTS_DIR/logs" "$RESULTS_DIR/metadata"
: > "$LOG_FILE"

# Create a mock DICOM input directory
mkdir -p "$TEMP_TEST_DIR/dicom_e2e"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_e2e/Image001"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_e2e/Image002"

set +e
import_dicom_data "$TEMP_TEST_DIR/dicom_e2e" "$TEMP_TEST_DIR/e2e_output" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_dicom_data returns 0 with mock tools"

# Verify NIfTI files were produced
nifti_count=$(find "$TEMP_TEST_DIR/e2e_output" -name "*.nii.gz" 2>/dev/null | wc -l)
assert_not_equals "0" "$nifti_count" \
    "import_dicom_data produces NIfTI output files"

# Verify metadata was extracted
assert_file_exists "$RESULTS_DIR/metadata/scanner_params.json" \
    "import_dicom_data produces scanner metadata"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 8. import_extract_metadata DICOM file discovery patterns
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "8. DICOM file discovery patterns"

# 8a: *.dcm pattern
export RESULTS_DIR="$TEMP_TEST_DIR/results_dcm_pattern"
mkdir -p "$RESULTS_DIR"
mkdir -p "$TEMP_TEST_DIR/dicom_dcm"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_dcm/scan001.dcm"

set +e
import_extract_metadata "$TEMP_TEST_DIR/dicom_dcm" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_extract_metadata handles *.dcm pattern"
assert_file_exists "$RESULTS_DIR/metadata/scanner_params.json" \
    "Metadata created for *.dcm files"

# 8b: IM_* pattern
export RESULTS_DIR="$TEMP_TEST_DIR/results_im_pattern"
mkdir -p "$RESULTS_DIR"
mkdir -p "$TEMP_TEST_DIR/dicom_im"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_im/IM_0001"

set +e
import_extract_metadata "$TEMP_TEST_DIR/dicom_im" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_extract_metadata handles IM_* pattern"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 9. DICOM_ANALYSIS_LOADED flag
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "9. Module integration flags"

# After sourcing, DICOM_ANALYSIS_LOADED should be set to something
assert_var_set "DICOM_ANALYSIS_LOADED" \
    "DICOM_ANALYSIS_LOADED variable is set after import.sh load"

# extract_scanner_metadata should be available (either real or fallback)
assert_function_exists "extract_scanner_metadata" \
    "extract_scanner_metadata available (real or fallback)"

# ══════════════════════════════════════════════════════════════════════════════
# 10. import_convert_dicom_to_nifti error recovery paths
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "10. Conversion error recovery"

# Create a dcm2niix mock that fails on first invocation
fail_mock_dir="$TEMP_TEST_DIR/mock_fail"
mkdir -p "$fail_mock_dir"
cat > "$fail_mock_dir/dcm2niix" << 'FAILMOCK'
#!/usr/bin/env bash
# This mock fails so the recovery path gets exercised
output_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_dir="$2"; shift 2 ;;
        -h) echo "dcm2niix mock"; exit 0 ;;
        -v) echo "v1.0.0 mock"; exit 0 ;;
        *)  shift ;;
    esac
done
# Create some output despite "failing" status
if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    dd if=/dev/zero of="$output_dir/recovered_1.nii.gz" bs=1024 count=20 2>/dev/null
fi
exit 1
FAILMOCK
chmod +x "$fail_mock_dir/dcm2niix"
export PATH="$fail_mock_dir:$PATH"

export RESULTS_DIR="$TEMP_TEST_DIR/results_recovery"
export LOG_DIR="$RESULTS_DIR/logs"
export LOG_FILE="$LOG_DIR/test.log"
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
export DICOM_PRIMARY_PATTERN="Image*"
mkdir -p "$TEMP_TEST_DIR/dicom_fail"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_fail/Image001"

# The function should attempt recovery and may produce output despite initial failure
set +e
import_convert_dicom_to_nifti "$TEMP_TEST_DIR/dicom_fail" "$TEMP_TEST_DIR/nifti_fail_out" 2>/dev/null
ec=$?
set -e

# Even if recovery doesn't fully succeed, it should not crash
crash_test="true"
[[ $ec -eq 0 ]] || [[ $ec -eq 1 ]] || [[ $ec -eq 31 ]] && crash_test="true" || crash_test="false"
assert_equals "true" "$crash_test" \
    "import_convert_dicom_to_nifti handles dcm2niix failure gracefully"

# Restore working mock
create_mock_dcm2niix

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 11. import_validate_nifti_files with mock fslinfo that fails
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "11. NIfTI validation with corrupt file detection"

# Create a dir with one good and one "corrupt" NIfTI file
mkdir -p "$TEMP_TEST_DIR/nifti_mixed"
create_fake_nifti "$TEMP_TEST_DIR/nifti_mixed/good.nii.gz" 20

# Create a mock fslinfo that fails for files containing "bad" in the name
mixed_mock_dir="$TEMP_TEST_DIR/mock_mixed"
mkdir -p "$mixed_mock_dir"
cat > "$mixed_mock_dir/fslinfo" << 'MIXEDMOCK'
#!/usr/bin/env bash
if [[ "$1" == *"bad"* ]]; then
    echo "Cannot open volume" >&2
    exit 1
fi
echo "data_type	FLOAT32"
echo "dim1		256"
echo "dim2		256"
echo "dim3		176"
echo "dim4		1"
exit 0
MIXEDMOCK
chmod +x "$mixed_mock_dir/fslinfo"
export PATH="$mixed_mock_dir:$PATH"

create_fake_nifti "$TEMP_TEST_DIR/nifti_mixed/bad_corrupt.nii.gz" 20

set +e
import_validate_nifti_files "$TEMP_TEST_DIR/nifti_mixed" 2>/dev/null
ec=$?
set -e
assert_not_equals "0" "$ec" \
    "import_validate_nifti_files detects corrupt NIfTI files"

# Restore standard mock
create_mock_fslinfo

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# 12. Parallel processing path (DICOM_IMPORT_PARALLEL > 1)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "12. Parallel vs sequential import path selection"

# With DICOM_IMPORT_PARALLEL=1, should use sequential
export DICOM_IMPORT_PARALLEL=1
export RESULTS_DIR="$TEMP_TEST_DIR/results_seq"
export LOG_DIR="$RESULTS_DIR/logs"
export LOG_FILE="$LOG_DIR/test.log"
mkdir -p "$LOG_DIR" "$RESULTS_DIR/metadata"
: > "$LOG_FILE"
export DICOM_PRIMARY_PATTERN="Image*"

mkdir -p "$TEMP_TEST_DIR/dicom_seq"
create_mock_dicom_file "$TEMP_TEST_DIR/dicom_seq/Image001"

set +e
import_dicom_data "$TEMP_TEST_DIR/dicom_seq" "$TEMP_TEST_DIR/seq_output" 2>/dev/null
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "import_dicom_data works in sequential mode (DICOM_IMPORT_PARALLEL=1)"

PIPELINE_SUCCESS=true; PIPELINE_ERROR_COUNT=0

# ══════════════════════════════════════════════════════════════════════════════
# Cleanup & Summary
# ══════════════════════════════════════════════════════════════════════════════
cleanup_test_environment
print_test_summary
