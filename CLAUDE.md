# CLAUDE.md - BrainStemX-Full

## Project Overview

BrainStemX-Full is an advanced neuroimaging research pipeline for analyzing T2/FLAIR hyperintensity clusters in brainstem and pons regions. It's a bash-based 8-stage resumable pipeline integrating multi-modal MRI analysis (T1/T2/FLAIR/SWI/DWI) with zero-shot anomaly detection.

**Version:** 0.1.1
**License:** MIT

## Quick Reference

### Build/Run Commands
```bash
# Install dependencies (Python 3.12.8 required - not 3.13)
uv sync

# Run pipeline (source bash_profile for environment setup)
source ~/.bash_profile && src/pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id

# Show help
src/pipeline.sh --help

# Run tests
./tests/test_integration.sh
./tests/test_dicom_analysis.sh
for test in tests/test_*.sh; do bash "$test"; done
```

### Pipeline Usage

```bash
src/pipeline.sh [options]
```

**Input/Output Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input DIR` | Input directory with DICOM files | `../DiCOM` |
| `-o, --output DIR` | Output directory for results | `../mri_results` |
| `-s, --subject ID` | Subject identifier | derived from input dir |
| `-c, --config FILE` | Configuration file | `config/default_config.sh` |

**Processing Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-q, --quality LEVEL` | Quality preset: LOW, MEDIUM, HIGH | MEDIUM |
| `-p, --pipeline TYPE` | Pipeline type: BASIC, FULL, CUSTOM | FULL |
| `-t, --start-stage STAGE` | Resume from specific stage | import |
| `--compare-import-options` | Compare dcm2niix import strategies and exit | - |
| `-f, --filter PATTERN` | Filter files by regex for import comparison | - |

**Verbosity Options:**
| Option | Description |
|--------|-------------|
| `--quiet` | Minimal output (errors and completion only) |
| `--verbose` | Detailed output with technical parameters |
| `--debug` | Full output including all ANTs technical details |
| `-h, --help` | Show help message |

### Pipeline Stages (`--start-stage`)

The 8-stage pipeline is resumable. Use `-t STAGE` to start from any stage:

| Stage | Aliases | Description |
|-------|---------|-------------|
| 1 | `import`, `dicom`, `1` | Import and convert DICOM data |
| 2 | `preprocess`, `preprocessing`, `pre`, `2` | Rician denoising + N4 bias correction |
| 3 | `brain_extraction`, `brain`, `extract`, `3` | Brain extraction, standardization, cropping |
| 4 | `registration`, `register`, `reg`, `4` | Align images to standard space |
| 5 | `segmentation`, `segment`, `seg`, `5` | Extract brainstem and pons regions |
| 6 | `analysis`, `analyze`, `6` | Detect and analyze hyperintensities |
| 7 | `visualization`, `visualize`, `vis`, `7` | Generate visualizations and reports |
| 8 | `tracking`, `track`, `progress`, `8` | Track pipeline progress |

### Usage Examples

```bash
# Full pipeline run
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001

# High quality processing
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001 -q HIGH

# Resume from registration stage
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001 -t registration

# Resume from stage 5 (segmentation) with verbose output
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001 -t 5 --verbose

# Compare DICOM import strategies
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM --compare-import-options

# Batch processing
source ~/.bash_profile && src/pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output --subject-list subjects.txt
```

### External Dependencies Required
- ANTs (Advanced Normalization Tools)
- FSL (FMRIB Software Library)
- dcm2niix
- Convert3D (c3d)
- GNU Parallel

## Project Structure

```
src/
├── pipeline.sh              # Main 8-stage pipeline orchestrator
└── modules/                 # 35+ modular components
    ├── environment.sh       # Environment setup, logging, dependency checks
    ├── import.sh            # DICOM import with dcm2niix
    ├── preprocess.sh        # Denoising & orientation standardization
    ├── brain_extraction.sh  # 3D isotropic sequence detection
    ├── registration.sh      # Multi-stage ANTs registration
    ├── segmentation.sh      # Harvard-Oxford & Talairach atlas segmentation
    ├── analysis.sh          # Hyperintensity detection & cluster analysis
    ├── visualization.sh     # 3D rendering & HTML reporting
    └── qa.sh                # Quality assurance (20+ validation checks)

config/
├── default_config.sh        # Pipeline default configuration
└── test_config.sh           # Test-specific config

tests/                       # 23 test scripts with assertion framework
docs/                        # Technical documentation
```

## Code Style

### Bash
- Shebang: `#!/usr/bin/env bash`
- Error handling: `set -e -u -o pipefail` at script start
- Functions: `snake_case`
- Variables: `UPPER_CASE` for exported, `lower_case` for local
- Logging via centralized functions: `log_message`, `log_formatted`, `log_error`, `log_diagnostic`

### Python
- Python 3.12.8 (critical - many deps unavailable on 3.13)
- Tools: pylint, isort
- Follow PEP 8

## Key Patterns

1. **Module Loading:** Scripts source modules with `source src/modules/environment.sh`
2. **Error Handling:** Validate inputs before processing, use defined error code constants
3. **Logging First:** All functions start with logging
4. **Graceful Degradation:** Fallback methods when primary processing fails
5. **Checkpointed Pipeline:** Can resume from any of 8 stages via `-t STAGE`

## Testing

Custom assertion-based framework:
- `assert_equals()`, `assert_file_exists()`, `assert_exit_code()`
- Tests use isolated temp directories
- Key tests: `test_integration.sh`, `test_dicom_analysis.sh`, `test_segmentation.sh`

## Configuration

Primary config: `config/default_config.sh`

Key environment variables:
- `PARALLEL_JOBS` - Subject parallelization
- `MAX_CPU_INTENSIVE_JOBS` - ANTs jobs limit
- `SCAN_SELECTION_MODE` - registration_optimized | original | highest_resolution
- `USE_ANTS_SYN` - ANTs vs FLIRT for registration

## Important Notes

- Python 3.12.8 is required (not 3.13)
- ANTs operations are memory-intensive (16+ GB RAM recommended)
- NIfTI files can exceed 1GB
- macOS-specific workarounds exist (e.g., `safe_fslmaths`)
- Check `$RESULTS_DIR/logs/` for detailed diagnostics
