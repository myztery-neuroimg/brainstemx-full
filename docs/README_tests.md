# Test Suite Documentation

This document provides a comprehensive overview of the test suite for the BrainStemX neuroimaging pipeline. The tests validate core functionality, integration points, and edge cases across all pipeline modules.

## Overview

The test suite is organized into functional categories using a custom assertion-based framework. Tests range from fast, mock-based unit tests (requiring no external tools) to integration tests that validate the entire processing workflow with real data.

**Quick start — run all CI-safe tests locally:**
```bash
bash tests/test_environment_unit.sh
bash tests/test_pipeline_control_unit.sh
bash tests/test_import_unit.sh
```

These 232 tests run in seconds with no external dependencies (FSL, ANTs, etc.).

## Test Structure

```
tests/
├── Shared Framework
│   └── test_helpers.sh                  # Assertions, mocks, setup/teardown (see below)
├── Unit Tests (mock-based, no external tools needed)
│   ├── test_environment_unit.sh         # environment.sh — 98 tests
│   ├── test_pipeline_control_unit.sh    # pipeline.sh control flow — 98 tests
│   └── test_import_unit.sh             # import.sh — 36 tests
├── Core Module Tests
│   ├── test_dicom_analysis.sh           # DICOM analysis module comprehensive testing
│   ├── test_segmentation.sh             # Brainstem segmentation functionality
│   └── test_orientation_preservation.sh # Orientation correction methods
├── Integration Tests
│   ├── test_integration.sh              # Centralized path/error handling integration
│   ├── test_dicom_mapping_integration.sh # DICOM cluster mapping integration
│   └── test_reference_space_selection.sh # Critical reference space decision logic
├── Performance Tests
│   ├── test_parallel.sh                 # Parallel processing framework
│   └── test_smart_standardization.sh    # Adaptive resolution standardization
└── Specialized Tests
    ├── test_orientation_fix.sh          # [TO BE DOCUMENTED]
    ├── test_original_detection.sh       # [TO BE DOCUMENTED]
    ├── test_path_resolution.sh          # [TO BE DOCUMENTED]
    ├── test_segmentation_paths.sh       # [TO BE DOCUMENTED]
    ├── test_segmentation_qa.sh          # [TO BE DOCUMENTED]
    ├── run_reference_space_test.sh      # [TO BE DOCUMENTED]
    └── run_segmentation_tests.sh        # [TO BE DOCUMENTED]
```

## Testing Frameworks

The test suite employs several testing patterns:

1. **Assertion-based Testing**: Custom assert functions (`assert_equals`, `assert_file_exists`, etc.) — see [test_helpers.sh](#test_helperssh---shared-test-library)
2. **Mock Environment Testing**: Isolated test environments with mock commands injected via PATH
3. **Integration Testing**: Real-world workflow validation with actual data
4. **Performance Benchmarking**: Timing and efficiency measurements
5. **Error Handling Validation**: Expected failure scenarios and graceful degradation

## test_helpers.sh — Shared Test Library

**Location**: `tests/test_helpers.sh`

A shared library sourced by all unit test files. Provides a consistent framework for writing and running tests without any external dependencies.

**Include guard**: Has `_TEST_HELPERS_LOADED` guard to prevent double-sourcing.

### Suite Lifecycle

```bash
source tests/test_helpers.sh
init_test_suite "My Test Suite"       # Reset counters, print header
setup_test_environment                # Create isolated temp dir, set LOG_DIR/RESULTS_DIR/etc.
# ... run tests ...
print_test_summary                    # Print pass/fail counts, return non-zero if failures
cleanup_test_environment              # Remove temp dir, restore PATH
```

`setup_test_environment` creates a temporary directory (`$TEMP_TEST_DIR`) and sets `LOG_DIR`, `RESULTS_DIR`, `LOG_FILE`, and `EXTRACT_DIR` to subdirectories within it, so tests never touch real pipeline paths.

### Assertion Functions

| Function | Signature | What it checks |
|----------|-----------|----------------|
| `assert_equals` | `expected actual message` | `expected == actual` |
| `assert_not_equals` | `not_expected actual message` | `not_expected != actual` |
| `assert_contains` | `haystack needle message` | `needle` is a substring of `haystack` |
| `assert_not_contains` | `haystack needle message` | `needle` is NOT in `haystack` |
| `assert_file_exists` | `path message` | `-f path` |
| `assert_file_not_exists` | `path message` | `! -f path` |
| `assert_dir_exists` | `path message` | `-d path` |
| `assert_function_exists` | `name message` | `declare -f name` succeeds |
| `assert_exit_code` | `expected actual message` | exit codes match (numeric) |
| `assert_var_set` | `var_name message` | variable is set and non-empty |
| `assert_matches` | `pattern actual message` | `actual =~ pattern` (regex) |

Each assertion increments `TEST_COUNT`, prints `PASS`/`FAIL`, and records failures for the summary.

### Mock Command Creators

These create executable scripts in `$TEMP_TEST_DIR/mock_bin/` and prepend that directory to `$PATH`, so the module under test uses the mock instead of the real tool.

| Function | Creates mock for | Behavior |
|----------|-----------------|----------|
| `create_mock_command` | Any command | Configurable exit code and output |
| `create_mock_fslinfo` | `fslinfo` | Returns plausible NIfTI header (256x256x176, 1mm iso) |
| `create_mock_fslstats` | `fslstats` | Returns `100.0 200.0 150.0 25.0` |
| `create_mock_fslmaths` | `fslmaths` | Copies input to output (or `touch`) |
| `create_mock_dcm2niix` | `dcm2niix` | Parses `-o` flag, creates fake `.nii.gz` files |
| `create_mock_dcmdump` | `dcmdump` | Cats the input file (expects mock DICOM content) |

### Data Helpers

| Function | Purpose |
|----------|---------|
| `create_fake_nifti path [size_kb]` | Creates a zero-filled file that passes basic size checks |
| `create_mock_dicom_file path [manufacturer] [model] [software]` | Creates a text file with standard DICOM tag format |
| `load_environment_module` | Sources `src/modules/environment.sh` with stderr suppressed |

---

## Unit Tests (Mock-Based)

These tests run entirely with mocked external tools — no FSL, ANTs, dcm2niix, or real data needed. They are fast (~2-3 seconds each) and run in CI.

### test_environment_unit.sh

**Tests Module**: `src/modules/environment.sh`
**Test Count**: 98

**Test Groups**:
1. **Logging Functions** — `log_message`, `log_formatted`, `log_error`, `log_diagnostic`: timestamp format, LOG_FILE writes, stderr fallback, severity levels, color codes
2. **Error Code Constants** — All 14 error codes (ERR_DEPENDENCY, ERR_FILE_NOT_FOUND, ERR_PIPELINE, etc.) are non-zero, unique, and integer-valued
3. **Validation Functions** — `validate_file`: existing/missing/empty files, unreadable (non-root only); `validate_nifti`: fslinfo integration, corrupt file detection, missing file handling, size checks (with platform note — see known issues); `validate_directory`: existing/missing/auto-create
4. **Path/Directory Utilities** — `get_module_dir`, `create_module_dir`, `get_output_path`: correct path construction, directory creation, naming conventions
5. **create_directories** — Creates all 14 expected pipeline subdirectories
6. **check_command** — Returns 0/1 for available/missing commands
7. **initialize_log_directory / initialize_environment** — Sets LOG_DIR and LOG_FILE, creates directories
8. **validate_module_execution** — Module self-validation
9. **Function Availability** — 24 functions verified to exist after module load
10. **Default Variables** — `RESULTS_DIR`, `LOG_DIR`, `LOG_FILE`, `SRC_DIR` are set

**Usage**:
```bash
bash tests/test_environment_unit.sh
```

### test_pipeline_control_unit.sh

**Tests Module**: `src/pipeline.sh` (control flow functions)
**Test Count**: 98

> **Design note**: Since `pipeline.sh` calls `main $@` at the bottom, it cannot be safely sourced. Key functions (`get_stage_number`, `parse_arguments`, `load_config`, `validate_step`) are copied into the test file for isolated testing.

**Test Groups**:
1. **get_stage_number** — All 8 canonical stage names (`import`→1 through `tracking`→8), all aliases (`dicom`, `pre`, `preprocessing`, `brain`, `extract`, `reg`, `register`, `seg`, `segment`, `analyze`, `vis`, `visualize`, `track`, `progress`), numeric strings `"1"`-`"8"`, invalid inputs (empty, `"0"`, `"9"`, `"IMPORT"` uppercase, `"foobar"`, `"10"`, spaces)
2. **parse_arguments** — Default values (`SRC_DIR`, `RESULTS_DIR`, `QUALITY_PRESET`, `PIPELINE_TYPE`, `VERBOSITY`), short flags (`-i`, `-o`, `-s`, `-q`, `-p`, `-t`), long flags (`--input`, `--output`, `--subject`, `--quality`, `--start-stage`), verbosity modes (`--quiet`, `--verbose`, `--debug`), `--compare-import-options`, `-f` filter, invalid stage rejection, unknown option rejection, subject ID derivation from input path, combined flags
3. **load_config** — Sources valid config file, fails on missing file
4. **validate_step** — Documents the always-returns-0 bug (unreachable code after `return 0`)
5. **Pipeline invocation** — `pipeline.sh --help` runs without error, produces `Usage:` and `Pipeline Stages:`
6. **Stage number round-trip consistency** — All alias→number mappings agree with canonical names

**Usage**:
```bash
bash tests/test_pipeline_control_unit.sh
```

### test_import_unit.sh

**Tests Module**: `src/modules/import.sh`
**Test Count**: 36

**Test Groups**:
1. **Function Availability** — 8 functions verified: `import_dicom_data`, `import_convert_dicom_to_nifti`, `import_extract_metadata`, `import_validate_nifti_files`, `import_validate_dicom_files_new_2`, `import_deduplicate_identical_files`, `import_compare_strategies`, `process_dicom_series`
2. **import_deduplicate_identical_files** — Verifies disabled-by-design behavior (returns 0 immediately, files untouched)
3. **import_validate_dicom_files_new_2** — Verifies disabled-by-design behavior
4. **import_extract_metadata** — Missing directory fallback, directory with `Image*` files, empty directory, `*.dcm` pattern, `IM_*` pattern
5. **import_convert_dicom_to_nifti** — Mock dcm2niix success, missing dcm2niix failure, error recovery
6. **import_validate_nifti_files** — Valid `.nii.gz` files pass, empty directory detected, corrupt/small files detected
7. **import_dicom_data** — End-to-end orchestration with mocked tools
8. **Module integration** — `IMPORT_MODULE_LOADED` flag, parallel vs sequential path selection

**Usage**:
```bash
bash tests/test_import_unit.sh
```

---

## Core Module Tests

### test_dicom_analysis.sh

**Purpose**: Comprehensive validation of the DICOM analysis module functionality

**Tests Module**: [`src/modules/dicom_analysis.sh`](src/modules/dicom_analysis.sh)

**Test Categories**:
1. **Environment Dependencies** - Validates required logging functions and environment variables
2. **Function Availability** - Checks all exported functions are accessible
3. **Input Validation** - Tests with invalid files, special characters, empty files
4. **DICOM Tool Detection** - Validates dcmdump availability and fallback behavior
5. **Manufacturer Detection** - Tests Siemens, Philips, GE, and unknown vendor detection
6. **Conversion Recommendations** - Validates manufacturer-specific dcm2niix flags
7. **Empty Fields Check** - Tests DICOM field validation functionality
8. **Metadata Extraction** - Tests Siemens-specific metadata extraction
9. **Scanner Metadata** - Tests multi-vendor scanner parameter extraction
10. **Error Handling Patterns** - Validates proper exit codes on failures
11. **Integration Tests** - Full workflow validation
12. **Edge Cases** - Long paths, Unicode filenames, concurrent execution
13. **Pattern Robustness** - Special characters in DICOM fields, malformed data
14. **Directory Operations** - Output directory creation and permissions
15. **Tool Compatibility** - Multiple DICOM tool support (dcmdump, gdcmdump, etc.)

**Expected Results**:
- All functions load without errors
- Proper manufacturer detection (SIEMENS, PHILIPS, GE, UNKNOWN)
- Correct conversion recommendations per vendor
- Graceful handling of missing/invalid files
- Successful metadata extraction for supported vendors

**Special Implementation Notes**:
- Uses mock DICOM files for testing (simulated dcmdump output)
- Creates isolated test environment with temporary directories
- Tests both success and failure scenarios
- Includes performance testing with large files (1000+ DICOM fields)
- Validates concurrent execution safety

**Usage**:
```bash
./tests/test_dicom_analysis.sh
```

### test_segmentation.sh

**Purpose**: Unit tests for brainstem segmentation functionality using Juelich atlas

**Tests Modules**: 
- [`src/modules/segmentation.sh`](src/modules/segmentation.sh)
- [`src/modules/juelich_segmentation.sh`](src/modules/juelich_segmentation.sh)

**Test Categories**:
1. **Module Loading** - Validates segmentation modules load correctly
2. **Function Availability** - Checks core segmentation functions exist
3. **Dependencies** - Tests FSL command availability and atlas presence
4. **Basic Functionality** - Input validation and error handling
5. **Output Directory Creation** - Proper directory structure creation
6. **Integration** - Full segmentation workflow testing

**Expected Results**:
- All segmentation functions available (`extract_brainstem_standardspace`, `extract_brainstem_talairach`, etc.)
- Proper handling of missing FSL tools
- Graceful fallback when atlases unavailable
- Correct output directory structure creation

**Special Implementation Notes**:
- Creates synthetic 3D test images (10x10x10 voxels)
- Uses FSL if available, otherwise creates dummy files
- Tests both Juelich atlas and fallback mechanisms
- Validates integration with main pipeline

**Usage**:
```bash
./tests/test_segmentation.sh
```

### test_orientation_preservation.sh

**Purpose**: Tests three orientation preservation methods and generates comparative analysis

**Tests Module**: [`src/modules/orientation_correction.sh`](src/modules/orientation_correction.sh)

**Test Categories**:
1. **Method Comparison** - Tests standard, topology-preserving, and anatomical warping
2. **Performance Analysis** - Compares methods for registration accuracy
3. **Visualization Generation** - Creates FSLeyes scripts for result comparison

**Expected Results**:
- Successful execution of all three orientation methods
- Generation of comparative report with best-performing method
- Creation of visualization scripts for manual inspection

**Special Implementation Notes**:
- Requires real T1 and other modality images as input
- Forces orientation preservation mode for testing
- Generates FSLeyes visualization scripts
- Returns best-performing method recommendation

**Usage**:
```bash
./tests/test_orientation_preservation.sh <t1_image> <other_modality> <output_dir>
```

## Integration Tests

### test_integration.sh

**Purpose**: Tests centralized path handling and error handling functionality

**Tests Module**: [`src/modules/environment.sh`](src/modules/environment.sh)

**Test Categories**:
1. **Directory Creation** - Tests `create_module_dir()` functionality
2. **Path Generation** - Validates `get_output_path()` correctness
3. **File Validation** - Tests `validate_file()` with various scenarios
4. **Directory Validation** - Tests `validate_directory()` with creation option
5. **Error Status Management** - Validates pipeline error tracking

**Expected Results**:
- Successful creation of module directories
- Correct path generation following pipeline conventions
- Proper file/directory validation behavior
- Appropriate error handling and status tracking

**Special Implementation Notes**:
- Creates isolated test environment
- Tests both success and expected failure scenarios
- Validates error counting and status management
- Uses lightweight file operations for testing

**Usage**:
```bash
./tests/test_integration.sh
```

### test_reference_space_selection.sh

**Purpose**: THE CRITICAL TEST for foundational reference space selection that affects the entire pipeline

**Tests Module**: [`src/scan_selection.sh`](src/scan_selection.sh) (integration point)

**Test Categories**:
1. **DICOM Discovery** - Tests DICOM file detection and conversion
2. **Sequence Analysis** - Validates T1/FLAIR sequence identification  
3. **Quality Assessment** - Tests image quality metrics calculation
4. **Decision Logic** - Validates reference space selection algorithm
5. **Validation** - Tests decision rationale and correctness

**Expected Results**:
- High-resolution 3D FLAIR dataset should choose FLAIR reference
- Clinical grade T1-MPR dataset should fallback to T1 reference
- Proper sequence identification and quality assessment
- Detailed decision rationale and validation

**Special Implementation Notes**:
- Tests with real DICOM data from `../DICOM` (high-res) and `../DICOM2` (clinical)
- Implements placeholder decision logic for testing framework
- Generates comprehensive test reports with decision rationale
- Converts to absolute paths to avoid resolution issues

**Usage**:
```bash
./tests/test_reference_space_selection.sh [--interactive] [options]
```

### test_dicom_mapping_integration.sh

**Purpose**: Validates DICOM cluster mapping module integration

**Tests Module**: [`src/modules/dicom_cluster_mapping.sh`](src/modules/dicom_cluster_mapping.sh)

**Test Categories**:
1. **Module Loading** - Tests module can be sourced without errors
2. **Function Availability** - Validates key functions are exported
3. **Integration** - Tests compatibility with existing pipeline

**Expected Results**:
- Successful module loading without syntax errors
- All required functions available for cluster mapping
- Proper integration with existing pipeline modules

**Special Implementation Notes**:
- Tests module loading dependencies
- Validates function exports
- Basic integration validation

**Usage**:
```bash
./tests/test_dicom_mapping_integration.sh
```

## Performance Tests

### test_parallel.sh

**Purpose**: Tests parallel processing framework functionality

**Tests Module**: [`src/modules/preprocess.sh`](src/modules/preprocess.sh) (parallel processing components)

**Test Categories**:
1. **Parallel Configuration** - Tests parallel config loading
2. **Test Data Creation** - Generates synthetic NIfTI volumes for processing
3. **Sequential vs Parallel** - Compares execution times
4. **Resource Management** - Validates proper job control

**Expected Results**:
- Successful parallel configuration loading
- Faster execution with parallel processing vs sequential
- Proper resource management and job control

**Special Implementation Notes**:
- Creates synthetic 3D volumes (64x64x64) with random data
- Uses `fslcreatehd` for proper NIfTI header creation
- Measures and compares execution times
- Tests GNU parallel availability and configuration

**Usage**:
```bash
./tests/test_parallel.sh
```

### test_smart_standardization.sh

**Purpose**: Tests adaptive resolution standardization functionality

**Tests Module**: [`src/modules/preprocess.sh`](src/modules/preprocess.sh) (standardization components)

**Test Categories**:
1. **Resolution Scenarios** - Tests T1>FLAIR and FLAIR>T1 resolution cases
2. **Orientation Detection** - Validates orientation matrix analysis
3. **Early Validation** - Tests input validation and error handling

**Expected Results**:
- Correct handling of different resolution scenarios
- Proper orientation detection and preservation
- Appropriate standardization decisions based on image quality

**Special Implementation Notes**:
- Creates mock NIfTI files with controlled dimensions and voxel sizes
- Uses FSL tools for header manipulation and validation
- Tests orientation matrix comparison functionality

**Usage**:
```bash
./tests/test_smart_standardization.sh
```

## Specialized Tests (To Be Documented)

The following tests require detailed analysis and documentation:

- **test_orientation_fix.sh** - Orientation correction validation
- **test_original_detection.sh** - Original image detection algorithms  
- **test_path_resolution.sh** - Path resolution and validation
- **test_segmentation_paths.sh** - Segmentation-specific path handling
- **test_segmentation_qa.sh** - Segmentation quality assurance
- **run_reference_space_test.sh** - Reference space test runner
- **run_segmentation_tests.sh** - Segmentation test suite runner

## Running Tests

### Unit Tests (no external tools needed)
```bash
# Run all 3 mock-based unit test suites (232 tests, ~5 seconds)
bash tests/test_environment_unit.sh
bash tests/test_pipeline_control_unit.sh
bash tests/test_import_unit.sh
```

### Individual Tests
```bash
# Run specific test
./tests/test_dicom_analysis.sh

# Run with specific parameters
./tests/test_reference_space_selection.sh --dataset-3dflair /path/to/dicom --expected-3dflair FLAIR
```

### Test Categories
```bash
# Run all unit tests (CI-safe, mock-based)
for test in tests/test_*_unit.sh; do bash "$test"; done

# Run all integration tests
for test in tests/test_integration*.sh; do "$test"; done

# Run all segmentation tests
for test in tests/test_segmentation*.sh tests/run_segmentation*.sh; do "$test"; done
```

### Full Test Suite
```bash
# Run all tests (when available)
for test in tests/test_*.sh; do
    echo "Running $test..."
    "$test" || echo "FAILED: $test"
done
```

## Test Dependencies

### Required Software
- **FSL** - Neuroimaging analysis tools (fslinfo, fslmaths, flirt, etc.)
- **dcm2niix** - DICOM to NIfTI conversion
- **GNU parallel** - Parallel processing framework (for performance tests)
- **bc** - Basic calculator for numerical comparisons

### Optional Software  
- **FSLeyes** - Visualization (for orientation preservation test)
- **dcmdump/gdcmdump** - DICOM inspection tools

### Environment Variables
- `FSLDIR` - FSL installation directory
- `RESULTS_DIR` - Pipeline results directory
- `LOG_DIR` - Logging directory

## Test Data Requirements

### Real Data Tests
- **test_reference_space_selection.sh**: Requires real DICOM datasets
  - `../DICOM` - High-resolution 3D FLAIR dataset
  - `../DICOM2` - Clinical grade T1-MPR dataset

### Synthetic Data Tests
- Most tests create their own synthetic data
- Mock DICOM files generated for DICOM analysis tests
- Synthetic NIfTI volumes created for processing tests

## Writing New Tests

When adding new tests:

1. **Source the shared library**: `source tests/test_helpers.sh` — gives you assertions, mocks, and lifecycle management
2. **Follow naming convention**: `test_<module_name>.sh` for module tests, `test_<module>_unit.sh` for mock-based unit tests
3. **Use the lifecycle**: `init_test_suite` → `setup_test_environment` → tests → `print_test_summary` → `cleanup_test_environment`
4. **Mock external tools**: Use `create_mock_fslinfo`, `create_mock_dcm2niix`, etc. rather than requiring real installs
5. **Test edge cases**: Invalid inputs, missing dependencies, empty directories, permission errors
6. **Update this document**: Add an entry to the test status table and describe test groups

**Minimal example**:
```bash
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "my_module.sh Unit Tests"
setup_test_environment
create_mock_fslinfo
load_environment_module

# Source module under test
source "$PROJECT_ROOT/src/modules/my_module.sh" 2>/dev/null || true

begin_test_group "1. Basic Tests"
assert_function_exists "my_function" "my_function is defined"
result=$(my_function "input" 2>/dev/null)
assert_contains "$result" "expected" "my_function produces expected output"

print_test_summary
cleanup_test_environment
```

**If adding a CI-safe test** (no external tools): add it to the `unit-tests` job in `.github/workflows/validate-scripts.yml`.

## Test Status Summary

| Test File | Tests | Status | Dependencies | CI? |
|-----------|-------|--------|-------------|-----|
| test_helpers.sh | — | ✅ Library | None | — |
| test_environment_unit.sh | 98 | ✅ Complete | None (mocked) | Yes |
| test_pipeline_control_unit.sh | 98 | ✅ Complete | None (mocked) | Yes |
| test_import_unit.sh | 36 | ✅ Complete | None (mocked) | Yes |
| test_dicom_analysis.sh | ~80 | ✅ Complete | dcmdump (mocked) | No |
| test_segmentation.sh | ~20 | ✅ Complete | FSL | No |
| test_integration.sh | ~15 | ✅ Complete | None | No |
| test_reference_space_selection.sh | ~30 | ✅ Complete | FSL, dcm2niix, Real DICOM | No |
| test_orientation_preservation.sh | ~10 | ✅ Complete | FSL, Real images | No |
| test_parallel.sh | ~8 | ⚠️ Partial | GNU parallel, FSL | No |
| test_smart_standardization.sh | ~6 | ⚠️ Partial | FSL | No |
| test_dicom_mapping_integration.sh | ~5 | ⚠️ Partial | None | No |
| test_orientation_fix.sh | | 📋 Pending | TBD | TBD |
| test_original_detection.sh | | 📋 Pending | TBD | TBD |
| test_path_resolution.sh | | 📋 Pending | TBD | TBD |
| test_segmentation_paths.sh | | 📋 Pending | TBD | TBD |
| test_segmentation_qa.sh | | 📋 Pending | TBD | TBD |
| run_reference_space_test.sh | | 📋 Pending | TBD | TBD |
| run_segmentation_tests.sh | | 📋 Pending | TBD | TBD |

**Legend**: ✅ Complete | ⚠️ Partial | 📋 Pending Documentation | **CI?** = runs in GitHub Actions without external tools

---

## Continuous Integration

Two GitHub Actions workflows validate the codebase:

### Always-on: Validate Scripts

**File**: `.github/workflows/validate-scripts.yml`
**Triggers**: Push to `main`, pull requests to `main`

Runs 3 parallel jobs on `ubuntu-latest`:

#### Job 1: Bash Syntax Check (`syntax-check`)

Runs `bash -n` on every `.sh` file in the repository. Catches parse errors, unclosed quotes, and invalid syntax. No dependencies needed.

```bash
# Equivalent local command:
find . -name '*.sh' -not -path './.git/*' | while read f; do bash -n "$f"; done
```

**Blocking**: Yes — fails the workflow if any file has a syntax error.

#### Job 2: Unit Tests (`unit-tests`)

Runs the 3 mock-based unit test suites (232 tests total):
- `tests/test_environment_unit.sh` — 98 tests
- `tests/test_pipeline_control_unit.sh` — 98 tests
- `tests/test_import_unit.sh` — 36 tests

No external tools required. Tests use mocked `fslinfo`, `fslstats`, `fslmaths`, `dcm2niix`, and `dcmdump` via PATH injection.

**Blocking**: Yes — fails the workflow if any test suite exits non-zero.

#### Job 3: Pipeline Smoke Test (`pipeline-smoke-test`)

Verifies the pipeline loads correctly and fails gracefully when external tools are unavailable. Two steps:

**Step 1**: `pipeline.sh --help` — confirms the help text renders without error and includes expected sections (`Usage:`, `Pipeline Stages:`).

**Step 2**: Full pipeline invocation with `FSLDIR=/tmp/fake_fsl` and `ANTS_PATH=/tmp/fake_ants`. Verifies 9 assertions:

| Assertion | What it proves |
|-----------|---------------|
| `Environment module loaded` | `environment.sh` sourced successfully |
| `Import module loaded` | `import.sh` sourced successfully |
| `Registration module loaded` | `registration.sh` + dependencies sourced |
| `Segmentation module loaded` | `segmentation.sh` + joint fusion sourced |
| `Analysis module loaded` | `analysis.sh` sourced successfully |
| `Visualization module loaded` | `visualization.sh` sourced successfully |
| `Arguments parsed:` | `parse_arguments` completed |
| `Comprehensive Pipeline Dependency Check` | Pipeline reached the dependency check phase |
| `dependencies are missing` | Failed for the RIGHT reason (missing tools, not a crash) |

**Blocking**: Yes — fails the workflow if any assertion is missing from the output.

### On-demand: ShellCheck

**File**: `.github/workflows/shellcheck-on-demand.yml`
**Trigger**: Comment `/shellcheck` on any pull request

Runs [ShellCheck](https://www.shellcheck.net/) at `--severity=error` level on all `.sh` files. Uses `.shellcheckrc` at the repo root for persistent exclusions.

**How to use**: Post a comment containing `/shellcheck` on any PR. The workflow checks out the PR's merge commit and runs shellcheck against it.

**Excluded rules** (via `.shellcheckrc`):
| Rule | Reason |
|------|--------|
| SC1090 | Can't follow non-constant source (dynamic `source` paths) |
| SC1091 | Not following sourced file (same) |
| SC2034 | Variable appears unused (cross-module exports) |
| SC2155 | Declare and assign separately (pervasive pattern) |

### Workflow setup

Both workflows activate automatically when their YAML files are present in `.github/workflows/`. No additional setup is needed.