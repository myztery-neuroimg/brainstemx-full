# Reference Space Selection Test Framework

## Overview

This test framework validates the adaptive reference space selection logic that determines whether to use T1-MPRAGE or T2-SPACE-FLAIR as the reference space for the entire neuroimaging pipeline.

## Test Philosophy

The reference space selection is **the foundational decision** that affects:
- Registration accuracy and quality
- Segmentation precision  
- Anatomical structure visibility
- Pathology detection sensitivity
- All downstream analyses

## Test Datasets

### 3D FLAIR Dataset (`../DICOM`)
- **Type**: High-resolution research-grade 3D SPACE-FLAIR
- **Expected Selection**: FLAIR
- **Rationale**: Superior resolution and 3D isotropic characteristics should favor FLAIR selection
- **Validation**: Tests that high-quality FLAIR is properly detected and selected

### Clinical MPR Dataset (`../DICOM2`)  
- **Type**: Clinical-grade T1-MPRAGE with standard FLAIR
- **Expected Selection**: T1
- **Rationale**: Standard clinical FLAIR quality should trigger fallback to T1 structural gold standard
- **Validation**: Tests that quality-based fallback logic works correctly

## Test Scripts

### Quick Integration Test
```bash
./tests/run_reference_space_test.sh
```
- Simple integration test using real DICOM data
- Validates both datasets and generates summary report
- Results saved to `$RESULTS_DIR/tests/reference_space_selection/`

### Comprehensive Test Suite
```bash
./tests/test_reference_space_selection.sh
```
- Full test framework with detailed validation
- Supports interactive mode and custom dataset paths
- Comprehensive reporting and analysis

## Test Configuration

### Environment Variables
All test outputs use the configured `RESULTS_DIR` from environment:
```bash
# Test outputs go to:
$RESULTS_DIR/tests/reference_space_selection/
```

### Dataset Paths
```bash
DATASET_3DFLAIR_DIR="../DICOM"           # High-resolution 3D FLAIR dataset  
DATASET_CLINICAL_MPR_DIR="../DICOM2"     # Clinical grade T1-MPR dataset
```

## Expected Outcomes

### Success Criteria
- ✅ 3D FLAIR dataset selects FLAIR (high-resolution advantage)
- ✅ Clinical MPR dataset selects T1 (quality fallback)
- ✅ Decision rationales are clinically appropriate
- ✅ ORIGINAL vs DERIVED classification is 100% accurate

### Test Results
Results are categorized as:
- **PASSED**: Both datasets produce expected selections
- **PARTIAL**: One dataset produces expected selection
- **FAILED**: Neither dataset produces expected selection

## Prerequisites

### Required Tools
- `dcm2niix` - DICOM to NIfTI conversion
- `fslinfo` - Image analysis and validation
- `bc` - Mathematical calculations

### Required Data
- `../DICOM` - Directory containing high-resolution research DICOM files
- `../DICOM2` - Directory containing clinical-grade DICOM files

## Usage Examples

### Basic Test Run
```bash
# Run with default settings
./tests/run_reference_space_test.sh

# View help
./tests/run_reference_space_test.sh --help
```

### Advanced Testing
```bash
# Interactive comprehensive test
./tests/test_reference_space_selection.sh --interactive

# Custom dataset paths
./tests/test_reference_space_selection.sh \
  --dataset-3dflair /path/to/research/dicom \
  --dataset-clinical-mpr /path/to/clinical/dicom \
  --expected-3dflair FLAIR \
  --expected-clinical-mpr T1
```

## Test Output Structure

```
$RESULTS_DIR/tests/reference_space_selection/
├── session_YYYYMMDD_HHMMSS/
│   ├── 3dflair_dataset/
│   │   ├── extracted/              # Converted NIfTI files
│   │   ├── selection_results.txt   # Decision analysis
│   │   └── conversion.log          # DICOM conversion log
│   ├── clinical_mpr_dataset/
│   │   ├── extracted/
│   │   ├── selection_results.txt
│   │   └── conversion.log
│   └── test_summary.txt            # Overall test results
```

## Integration into Pipeline

Once validated, the reference space selection logic can be integrated into the main pipeline by:

1. **Configuration**: Set `REFERENCE_SPACE_SELECTION_MODE="adaptive"`
2. **Pipeline Integration**: Update main workflow to call `select_optimal_reference_space()`
3. **Registration Updates**: Modify registration functions to use selected reference space
4. **Validation**: Run end-to-end tests to ensure proper integration

## Troubleshooting

### Common Issues

**No DICOM files found**
- Verify dataset directories exist and contain DICOM files
- Check DICOM file patterns (`.dcm`, `Image*`, etc.)

**Conversion failures**
- Ensure `dcm2niix` is properly installed
- Check DICOM file integrity and format

**Unexpected selections**
- Review decision rationales in `selection_results.txt`
- Validate image quality metrics and resolution analysis
- Check ORIGINAL vs DERIVED classification logic

**FSL errors**
- Ensure FSL is properly installed and configured
- Verify `FSLDIR` environment variable is set
- Check that converted NIfTI files are valid

## Research Standards

This test framework follows research-grade standards:
- All outputs use configured `RESULTS_DIR` paths
- No data persistence within project directory
- Professional terminology and documentation
- Comprehensive validation and reporting
- Reproducible test procedures

## Contact

For questions about the reference space selection logic or test framework, refer to the main pipeline documentation or the adaptive reference space selection implementation plan.