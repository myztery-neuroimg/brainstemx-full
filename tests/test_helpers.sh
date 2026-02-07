#!/usr/bin/env bash
#
# test_helpers.sh - Shared test utilities for BrainStemX unit tests
#
# Provides:
#   - Assertion functions (assert_equals, assert_not_equals, assert_file_exists, etc.)
#   - Test environment setup/teardown with isolated temp dirs
#   - Mock command creation for external tools (fslinfo, dcm2niix, etc.)
#   - Test result tracking and summary reporting
#
# Usage:
#   source tests/test_helpers.sh
#   init_test_suite "My Test Suite"
#   setup_test_environment
#   ... run tests ...
#   print_test_summary
#   cleanup_test_environment
#

# Prevent double-sourcing
[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

# ------------------------------------------------------------------------------
# Test Framework State
# ------------------------------------------------------------------------------
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()
SUITE_NAME=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test directories
TEMP_TEST_DIR=""
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Original PATH saved for restoration
_ORIGINAL_PATH="$PATH"

# ------------------------------------------------------------------------------
# Suite Lifecycle
# ------------------------------------------------------------------------------

init_test_suite() {
    SUITE_NAME="${1:-Unit Tests}"
    TEST_COUNT=0
    PASS_COUNT=0
    FAIL_COUNT=0
    FAILED_TESTS=()

    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  ${SUITE_NAME}${NC}"
    echo -e "${BLUE}======================================${NC}"
}

setup_test_environment() {
    TEMP_TEST_DIR=$(mktemp -d -t brainstemx_test_XXXXXX)
    export TEMP_TEST_DIR

    # Set up isolated directories so sourced modules don't pollute real paths
    export LOG_DIR="$TEMP_TEST_DIR/logs"
    export RESULTS_DIR="$TEMP_TEST_DIR/results"
    export LOG_FILE="$LOG_DIR/test.log"
    export EXTRACT_DIR="$TEMP_TEST_DIR/extracted"

    mkdir -p "$LOG_DIR" "$RESULTS_DIR" "$EXTRACT_DIR"

    echo "Test environment: $TEMP_TEST_DIR"
}

cleanup_test_environment() {
    # Restore original PATH
    export PATH="$_ORIGINAL_PATH"

    if [[ -n "$TEMP_TEST_DIR" ]] && [[ -d "$TEMP_TEST_DIR" ]]; then
        rm -rf "$TEMP_TEST_DIR"
    fi
}

# ------------------------------------------------------------------------------
# Assertion Functions
# ------------------------------------------------------------------------------

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$expected" = "$actual" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_not_equals() {
    local not_expected="$1"
    local actual="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$not_expected" != "$actual" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Should not equal: '$not_expected'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    String: '$haystack'"
        echo "    Does not contain: '$needle'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    String: '$haystack'"
        echo "    Should not contain: '$needle'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="$2"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    File does not exist: '$file'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local message="$2"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ ! -f "$file" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    File should not exist: '$file'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local message="$2"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ -d "$dir" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Directory does not exist: '$dir'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_function_exists() {
    local func="$1"
    local message="$2"

    TEST_COUNT=$((TEST_COUNT + 1))
    if declare -f "$func" > /dev/null 2>&1; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Function not defined: '$func'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_exit_code() {
    local expected_code="$1"
    local actual_code="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$expected_code" -eq "$actual_code" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Expected exit code: $expected_code"
        echo "    Actual exit code:   $actual_code"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_var_set() {
    local var_name="$1"
    local message="$2"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ -n "${!var_name:-}" ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Variable is unset or empty: $var_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

assert_matches() {
    local pattern="$1"
    local actual="$2"
    local message="$3"

    TEST_COUNT=$((TEST_COUNT + 1))
    if [[ "$actual" =~ $pattern ]]; then
        echo -e "${GREEN}  PASS${NC}: $message"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "${RED}  FAIL${NC}: $message"
        echo "    Pattern: '$pattern'"
        echo "    Actual:  '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$message")
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Test grouping
# ------------------------------------------------------------------------------

begin_test_group() {
    local group_name="$1"
    echo ""
    echo -e "${BLUE}--- $group_name ---${NC}"
}

# ------------------------------------------------------------------------------
# Mock Creation Utilities
# ------------------------------------------------------------------------------

# Create a mock executable script that echoes its arguments and exits 0
create_mock_command() {
    local name="$1"
    local exit_code="${2:-0}"
    local output="${3:-}"
    local mock_dir="$TEMP_TEST_DIR/mock_bin"

    mkdir -p "$mock_dir"

    cat > "$mock_dir/$name" << MOCK_EOF
#!/usr/bin/env bash
# Mock for $name
${output:+echo "$output"}
exit $exit_code
MOCK_EOF
    chmod +x "$mock_dir/$name"

    # Prepend mock_bin to PATH if not already there
    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a mock fslinfo that returns plausible NIfTI info
create_mock_fslinfo() {
    local mock_dir="$TEMP_TEST_DIR/mock_bin"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/fslinfo" << 'MOCK_EOF'
#!/usr/bin/env bash
if [[ ! -f "$1" ]]; then
    echo "Cannot open volume $1 for reading!" >&2
    exit 1
fi
echo "data_type	FLOAT32"
echo "dim1		256"
echo "dim2		256"
echo "dim3		176"
echo "dim4		1"
echo "datatype	16"
echo "pixdim1		1.000000"
echo "pixdim2		1.000000"
echo "pixdim3		1.000000"
echo "pixdim4		1.000000"
echo "cal_max		0.000000"
echo "cal_min		0.000000"
echo "file_type	NIFTI-1+"
exit 0
MOCK_EOF
    chmod +x "$mock_dir/fslinfo"

    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a mock fslstats
create_mock_fslstats() {
    local mock_dir="$TEMP_TEST_DIR/mock_bin"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/fslstats" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "100.0 200.0 150.0 25.0"
exit 0
MOCK_EOF
    chmod +x "$mock_dir/fslstats"

    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a mock fslmaths that just copies input to output
create_mock_fslmaths() {
    local mock_dir="$TEMP_TEST_DIR/mock_bin"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/fslmaths" << 'MOCK_EOF'
#!/usr/bin/env bash
# Find the last .nii.gz argument as output, first as input
input=""
output=""
for arg in "$@"; do
    if [[ "$arg" == *.nii.gz ]] && [[ "$arg" != -* ]]; then
        if [[ -z "$input" ]]; then
            input="$arg"
        fi
        output="$arg"
    fi
done
if [[ -n "$output" ]] && [[ -n "$input" ]] && [[ "$input" != "$output" ]]; then
    cp "$input" "$output" 2>/dev/null || touch "$output"
elif [[ -n "$output" ]]; then
    touch "$output"
fi
exit 0
MOCK_EOF
    chmod +x "$mock_dir/fslmaths"

    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a mock dcm2niix that produces fake .nii.gz files
create_mock_dcm2niix() {
    local mock_dir="$TEMP_TEST_DIR/mock_bin"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/dcm2niix" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock dcm2niix - parse args to find output dir, create fake NIfTI files
output_dir=""
show_help=false
show_version=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)  output_dir="$2"; shift 2 ;;
        -h)  show_help=true; shift ;;
        -v)  show_version=true; shift ;;
        -*)  shift ;; # skip other flags
        *)
            # Last positional arg is the input dir
            if [[ $# -eq 1 ]]; then
                input_dir="$1"
            fi
            shift
            ;;
    esac
done
if $show_help; then
    echo "dcm2niix mock v1.0"
    exit 0
fi
if $show_version; then
    echo "dcm2niix version v1.0.20240101 mock"
    exit 0
fi
if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    # Create fake NIfTI output files
    dd if=/dev/zero of="$output_dir/T1_1.nii.gz" bs=1024 count=20 2>/dev/null
    dd if=/dev/zero of="$output_dir/FLAIR_2.nii.gz" bs=1024 count=20 2>/dev/null
    echo "Convert 2 files"
fi
exit 0
MOCK_EOF
    chmod +x "$mock_dir/dcm2niix"

    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a mock dcmdump
create_mock_dcmdump() {
    local mock_dir="$TEMP_TEST_DIR/mock_bin"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/dcmdump" << 'MOCK_EOF'
#!/usr/bin/env bash
if [[ $# -eq 0 ]] || [[ ! -f "$1" ]]; then
    echo "dcmdump: cannot open file" >&2
    exit 1
fi
cat "$1"
exit 0
MOCK_EOF
    chmod +x "$mock_dir/dcmdump"

    if [[ "$PATH" != "$mock_dir:"* ]]; then
        export PATH="$mock_dir:$PATH"
    fi
}

# Create a fake NIfTI file (just zeroes, large enough to pass size checks)
create_fake_nifti() {
    local path="$1"
    local size_kb="${2:-20}"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$size_kb" 2>/dev/null
}

# Create a mock DICOM file with standard header fields
create_mock_dicom_file() {
    local filename="$1"
    local manufacturer="${2:-SIEMENS}"
    local model="${3:-TestModel}"
    local software="${4:-TestSoftware}"

    mkdir -p "$(dirname "$filename")"
    cat > "$filename" << DICOM_EOF
(0008,0070) LO [${manufacturer}]    # Manufacturer
(0008,1090) LO [${model}]           # ManufacturerModelName
(0018,1020) LO [${software}]        # SoftwareVersions
(0020,000D) UI [1.2.3.4.5.6.7.8.9]  # StudyInstanceUID
(0020,000E) UI [1.2.3.4.5.6.7.8.10] # SeriesInstanceUID
(0020,0010) SH [TEST001]             # StudyID
(0020,0011) IS [1]                   # SeriesNumber
(0008,0060) CS [MR]                  # Modality
(0008,103E) LO [Test Series]         # SeriesDescription
(0020,0013) IS [1]                   # InstanceNumber
DICOM_EOF
}

# ------------------------------------------------------------------------------
# Module Loading Helpers
# ------------------------------------------------------------------------------

# Source environment.sh with error suppression for missing external tools.
# Sets up a minimal working environment for unit tests.
load_environment_module() {
    if [[ -f "$PROJECT_ROOT/src/modules/environment.sh" ]]; then
        source "$PROJECT_ROOT/src/modules/environment.sh" 2>/dev/null || true
        return 0
    else
        echo -e "${RED}ERROR: environment.sh not found${NC}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

print_test_summary() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  Test Results: ${SUITE_NAME}${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "  Total:  ${BLUE}$TEST_COUNT${NC}"
    echo -e "  Passed: ${GREEN}$PASS_COUNT${NC}"
    echo -e "  Failed: ${RED}$FAIL_COUNT${NC}"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "${RED}Failed tests:${NC}"
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}x${NC} $t"
        done
    fi

    local rate=0
    [[ $TEST_COUNT -gt 0 ]] && rate=$((PASS_COUNT * 100 / TEST_COUNT))
    echo ""
    echo -e "  Success rate: ${rate}%"

    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}All tests passed.${NC}"
    else
        echo -e "${YELLOW}Some tests failed.${NC}"
    fi

    [[ $FAIL_COUNT -eq 0 ]]
}
