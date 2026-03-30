# CLAUDE.md - BrainStemX-Full

Bash-based 8-stage resumable neuroimaging pipeline for T2/FLAIR hyperintensity analysis in brainstem/pons. Integrates T1/T2/FLAIR/SWI/DWI with GMM-based anomaly detection.

## Commands

```bash
uv sync                                    # install deps (Python 3.12.8 — not 3.13)
source ~/.bash_profile && src/pipeline.sh -i ../DiCOM -o ../mri_results -s patient001
src/pipeline.sh --help                     # full CLI reference
src/pipeline.sh -t registration [...]      # resume from any stage (1–8)

# Tests
for test in tests/test_*.sh; do bash "$test"; done
uv run pytest tests/ -v
```

## CI / local checks (must pass before pushing)

```bash
# Bash syntax
find . -name '*.sh' -not -path './.git/*' | sort | xargs -I{} bash -n {}

# ShellCheck (error-level)
find . -name '*.sh' -not -path './.git/*' | sort | xargs shellcheck --severity=error

# Unit test suites
bash tests/test_environment_unit.sh
bash tests/test_pipeline_control_unit.sh
bash tests/test_import_unit.sh

# Smoke test
bash src/pipeline.sh --help | grep -q "Usage:"
```

## Project structure

```
src/pipeline.sh          # main orchestrator — run_pipeline() is ~1000 lines
src/modules/             # 35+ modules, each sourced by pipeline.sh
  environment.sh         # logging, error codes, path utils, dependency checks
  require_env.sh         # lightweight include guard — source instead of environment.sh in modules
  import.sh              # DICOM → NIfTI via dcm2niix
  preprocess.sh          # Rician denoising, N4 bias correction
  brain_extraction.sh    # BET / ANTs brain extraction
  registration.sh        # multi-stage ANTs registration (~600 line register_to_reference())
  segmentation.sh        # Harvard-Oxford + Talairach atlas
  analysis.sh            # hyperintensity detection, cluster analysis
  gmm_threshold.py       # standalone GMM thresholder (called by analysis.sh)
  visualization.sh       # 3D rendering, HTML reports
  qa.sh                  # 20+ validation checks
config/default_config.sh # all pipeline defaults (has include guard)
tests/                   # 22 bash test scripts + 1 pytest module
```

## Code style

**Bash**
- Shebang: `#!/usr/bin/env bash`
- `set -e -u -o pipefail` at top of every script
- Exported vars: `UPPER_CASE` — local vars: `lower_case` — functions: `snake_case`
- Logging: always call `log_message` / `log_formatted` / `log_error` at function entry
- Array expansions: `"${arr[@]}"` to iterate, `${#arr[@]}` for length

**Python** — 3.12.8 required (3.13 breaks several deps). `uv run`, pylint, isort, PEP 8.

## Key patterns

**Include guards** — every module and config file must have one:
```bash
if [ -n "${_MODULE_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_MODULE_LOADED=1
```
`config/default_config.sh` uses `_DEFAULT_CONFIG_LOADED`; `environment.sh` uses `_ENVIRONMENT_LOADED`.

**Module guard** — source `require_env.sh` at the top of standalone modules instead of `environment.sh` directly; it's a fast no-op when the environment is already loaded.

**Error codes** — use constants from `environment.sh` (`ERR_DATA_MISSING`, `ERR_PREPROC`, `ERR_REGISTRATION`, etc.), not raw numbers.

**Config loading** — `main()` loads config via `$CONFIG_FILE` (respects `-c` flag). Do not call `load_config` again inside `run_pipeline()`.

**Stage resumability** — `PIPELINE_REFERENCE_MODALITY` defaults to `T1` at the top of `run_pipeline()`; step 2 overrides it. Each skip-block must recover all file-path variables from disk before downstream stages use them.

## Key config variables

| Variable | Purpose |
|---|---|
| `PARALLEL_JOBS` | subject-level parallelisation (0 = auto) |
| `MAX_CPU_INTENSIVE_JOBS` | ANTs thread cap |
| `USE_ANTS_SYN` | `true` = ANTs SyN, `false` = FLIRT |
| `SCAN_SELECTION_MODE` | `registration_optimized` \| `highest_resolution` \| `interactive` |
| `THRESHOLD_WM_SD_MULTIPLIER` | authoritative fallback threshold (GMM inherits this) |
| `GMM_*` (11 vars) | GMM per-region thresholding — see `config/default_config.sh` |

## Runtime notes

- ANTs is memory-intensive — 16+ GB RAM recommended
- NIfTI files can exceed 1 GB
- macOS: use `safe_fslmaths` wrapper instead of `fslmaths` directly
- Logs: `$RESULTS_DIR/logs/`
- Python: always invoke via `uv run`, never bare `python`/`python3`
- Environment: `source ~/.bash_profile` before running the pipeline
