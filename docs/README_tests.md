# Test Suite Documentation

This document provides a comprehensive overview of the test suite for the BrainStemX neuroimaging pipeline. The tests validate core functionality, integration points, and edge cases across all pipeline modules.

## Overview

The test suite is organized into functional categories and uses multiple testing frameworks to ensure comprehensive coverage of the pipeline's capabilities. Tests range from unit tests for individual modules to integration tests that validate the entire processing workflow.

## Test Structure

```
tests/
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

1. **Assertion-based Testing**: Custom assert functions (`assert_equals`, `assert_file_exists`, etc.)
2. **Mock Environment Testing**: Isolated test environments with controlled dependencies
3. **Integration Testing**: Real-world workflow validation with actual data
4. **Performance Benchmarking**: Timing and efficiency measurements
5. **Error Handling Validation**: Expected failure scenarios and graceful degradation

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

### Individual Tests
```bash
# Run specific test
./tests/test_dicom_analysis.sh

# Run with specific parameters  
./tests/test_reference_space_selection.sh --dataset-3dflair /path/to/dicom --expected-3dflair FLAIR
```

### Test Categories
```bash
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

## Contributing to Tests

When adding new tests:

1. **Follow Naming Convention**: `test_<module_name>.sh` or `test_<functionality>.sh`
2. **Use Standard Framework**: Implement `assert_*` functions for consistency
3. **Include Documentation**: Add comprehensive header comments
4. **Test Edge Cases**: Include invalid inputs, missing dependencies, etc.
5. **Cleanup**: Ensure proper cleanup of temporary files/directories
6. **Update Documentation**: Add entry to this README with full specification

## Test Status Summary

| Test File | Status | Coverage | Dependencies |
|-----------|---------|----------|--------------|
| test_dicom_analysis.sh | ✅ Complete | Comprehensive | dcmdump (mocked) |
| test_segmentation.sh | ✅ Complete | Core functionality | FSL |
| test_integration.sh | ✅ Complete | Path/error handling | None |
| test_reference_space_selection.sh | ✅ Complete | Critical decision logic | FSL, dcm2niix, Real DICOM |
| test_orientation_preservation.sh | ✅ Complete | Orientation methods | FSL, Real images |
| test_parallel.sh | ⚠️ Partial | Parallel framework | GNU parallel, FSL |
| test_smart_standardization.sh | ⚠️ Partial | Standardization | FSL |
| test_dicom_mapping_integration.sh | ⚠️ Partial | Basic integration | None |
| test_orientation_fix.sh | 📋 Pending | TBD | TBD |
| test_original_detection.sh | 📋 Pending | TBD | TBD |
| test_path_resolution.sh | 📋 Pending | TBD | TBD |
| test_segmentation_paths.sh | 📋 Pending | TBD | TBD |
| test_segmentation_qa.sh | 📋 Pending | TBD | TBD |
| run_reference_space_test.sh | 📋 Pending | TBD | TBD |
| run_segmentation_tests.sh | 📋 Pending | TBD | TBD |

**Legend**: ✅ Complete | ⚠️ Partial | 📋 Pending Documentation