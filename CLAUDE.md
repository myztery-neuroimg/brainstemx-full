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
  preprocess.sh          # modality-aware denoising (T1/T2/FLAIR Rician NLM, DWI MP-PCA, SWI/TOF skip) + N4 bias correction (field-strength via -b spline distance; gentler, lesion-aware FLAIR N4)
  dwi_preprocess.sh      # full DWI path: MP-PCA dwidenoise → optional Gibbs unring → bias correct (gated by PROCESS_DWI)
  brain_extraction.sh    # SynthStrip primary (→ANTs→BET fallback) + robustfov FOV-normalization + posterior-fossa QC
  registration.sh        # multi-stage ANTs registration (~600 line register_to_reference())
  segmentation.sh        # Harvard-Oxford gross extent (thr25) + FreeSurfer brainstem substructures; optional multi-atlas warp (Bianciardi/CIT168/AAL3)
  brainstem_freesurfer.sh # FreeSurfer segmentBS substructures (Iglesias 2015): midbrain/pons/medulla/SCP in native space
  multi_atlas.sh         # Bianciardi + CIT168 + AAL3 → subject-space per-region masks (SyN→MNI + GenericLabel)
  brainstem_aanseg.sh    # EXPLORATORY: FreeSurfer AANSegment arousal-network nuclei (≤1mm only; off by default)
  analysis.sh            # hyperintensity detection, cluster analysis
  gmm_threshold.py       # standalone GMM thresholder (called by analysis.sh)
  cross_modal_analysis.sh # MULTI-MODAL: per-cluster corroboration of FLAIR clusters with co-registered SWI/DWI-trace/ADC/T2 (default on, graceful)
  cross_modal_sample.py  # samples co-registered modalities per cluster, emits the cross-modal table + flags (called by cross_modal_analysis.sh)
  fp_filter.sh           # post-detection false-positive suppression (config-gated; complements CSF/PV exclusion)
  wmh_bianca.sh          # optional supervised WMH: FSL BIANCA (needs training data); off by default
  wmh_lst_samseg.sh      # optional WMH: LST-AI + FreeSurfer SAMSEG (pretrained, no training data); off by default
  wmh_synthseg.sh        # optional WMH: contrast-agnostic WMH-SynthSeg (mri_WMHsynthseg); off by default
  wmh_segcsvd.sh         # optional WMH: segcsvdWMH CNN (FLAIR-only); off by default
  wmh_shiva.sh           # optional WMH: SHIVA-WMH small-lesion detector (high sensitivity); off by default
  wmh_mars.sh            # optional WMH: MARS-WMH deep-learning tool (MIAC); off by default
  visualization.sh       # 3D rendering, QC HTML report, + report visualizations (per-method seg overlays, hyperintensity-on-FLAIR, multi-modal montage)
  reporting.sh           # FINAL stage: aggregation/reporting layer — discovers all outputs, builds CSV/TSV+HTML summary tables (reports/tables/) and the top-level report (reports/brainstemx_report.html + .md). Gated/graceful/idempotent.
  reporting_tables.py    # stdlib-only aggregator behind reporting.sh (parses provenance/summaries, renders tables + top-level report; called via uv)
  qa.sh                  # 20+ validation checks
config/default_config.sh # all pipeline defaults (has include guard)
tests/                   # 23 bash test scripts + 2 pytest modules
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
| `BRAINSTEM_SEGMENTATION_METHOD` | `all` (default, parallel) \| `freesurfer` \| `atlas`/`harvard_oxford` \| `multi_atlas`/`bianciardi` |
| `SEG_RUN_HARVARD_OXFORD` / `SEG_RUN_MULTI_ATLAS` / `SEG_RUN_FREESURFER` | per-path toggles for `all` mode (all default on; `SEG_RUN_FREESURFER=false` skips the multi-hour recon-all) |
| `USE_BIANCIARDI` / `USE_CIT168` / `USE_AAL3` | per-atlas enables for `multi_atlas` (AAL3 off by default) |
| `ATLAS_DIR` | atlas root, default `${FSLDIR}/data/atlases` |

## Brainstem segmentation method & optional modules

**`BRAINSTEM_SEGMENTATION_METHOD`** (default `all`) selects the brainstem labeling backend:

- `all` (default) — runs every ENABLED path below as **concurrent parallel paths** and analyses the UNION of all masks they produce. The fast paths (HO gross extent + multi-atlas warp, minutes) run alongside the multi-hour FreeSurfer recon-all; each path is independent and non-fatal (a failed/skipped path logs a WARNING, never aborts the others or the pipeline). The MNI→subject SyN warp is computed ONCE up front and reused by both the HO and multi-atlas paths (no race on the shared transform). Per-path toggles `SEG_RUN_HARVARD_OXFORD` / `SEG_RUN_MULTI_ATLAS` / `SEG_RUN_FREESURFER` (all default on) drop individual paths — set `SEG_RUN_FREESURFER=false` to keep the fast HO + multi-atlas paths and skip recon-all. Downstream per-region GMM (`find_all_atlas_regions` → `apply_per_region_gmm_analysis`) discovers the union of FS parcels + multi-atlas nuclei/subdivisions + HO gross mask and tags each region's provenance (`region_provenance.tsv`).
- `freesurfer` — FreeSurfer `segmentBS`/`brainstemSsLabels` substructures (midbrain/pons/medulla/SCP) on the subject's own T1; gated by an FS↔HO agreement (Dice + leakage) check; falls back to the HO gross mask on disagreement or missing FreeSurfer/license.
- `atlas` / `harvard_oxford` — Harvard-Oxford gross brainstem extent only (index 7, `maxprob-thr25`).
- `multi_atlas` / `bianciardi` — additionally warps Bianciardi BrainstemNavigator / CIT168 / AAL3 into subject space (shared SyN→MNI + `GenericLabel`) for nucleus-level masks (`docs/multi_atlas_integration_spec.md`).

The single-method values (`freesurfer`/`multi_atlas`/`bianciardi`/`atlas`/`harvard_oxford`) remain mutually exclusive and behave exactly as before.

**Atlas-on-disk prerequisite** — `atlas`/`multi_atlas`/`bianciardi` need the atlases pre-downloaded under `$FSLDIR/data/atlases` (`ATLAS_DIR`): `Bianciardi/`, `CIT168/`, `AAL3/`, `HarvardOxford/`. The startup `check_atlas_availability` step (`environment.sh`, called from `pipeline.sh`) reports presence/absence per atlas and warns if the selected method needs a missing one; absence is **non-fatal** — the pipeline degrades to the HO gross mask. Override layout via `ATLAS_{BIANCIARDI,CIT168,AAL3,HARVARDOXFORD}_REL`.

**Optional WMH / seg modules (all default-OFF)** — supervised/DL add-ons, each intersected with the brainstem mask: `wmh_bianca.sh` (FSL BIANCA), `wmh_lst_samseg.sh` (LST-AI + SAMSEG), `wmh_synthseg.sh` (WMH-SynthSeg), `wmh_segcsvd.sh` (segcsvdWMH), `wmh_shiva.sh` (SHIVA-WMH), `wmh_mars.sh` (MARS-WMH); plus `brainstem_aanseg.sh` (EXPLORATORY AANSegment, ≤1 mm only) and the post-detection `fp_filter.sh`. None is validated in the brainstem — keep conservative pons QA / human-in-the-loop.

## Multi-modal (SWI / DWI / T2) end-to-end

Beyond the T1/FLAIR backbone, the pipeline brings the **secondary** T2-weighted modalities — SWI magnitude, the DERIVED DWI **trace** + **ADC** (not raw 4D diffusion), and a true T2 — all the way through, **only when they are present** (a T1+FLAIR-only study is byte-identically unchanged):

- **Import** keeps every dcm2niix series in `EXTRACT_DIR` (no modality filtering). `scan_selection.sh::discover_secondary_modality_specs` selects the best SWI/DWI-trace/ADC/T2 scan (filters out the T2-SPACE-FLAIR and the DWI-vs-ADC cross-contamination).
- **Registration** routes secondaries through the **contrast-matched cascade** (`registration.sh::register_contrast_matched_cascade`, T1←FLAIR←{T2,DWI,ADC,SWI}, composed forward+inverse transforms persisted) into the common analysis space. Enabled by `CONTRAST_MATCHED_REGISTRATION=true` + `AUTO_REGISTER_ALL_MODALITIES=true` (both default on; the cascade is a no-op when no secondary is present). `CONTRAST_ANCHOR_MAP` anchors the whole T2-family {T2,DWI,ADC,SWI} on FLAIR.
- **Cross-modal corroboration** (`cross_modal_analysis.sh`, default on, self-gated) samples the co-registered secondaries inside every PRIMARY FLAIR cluster and flags **DWI restriction** (trace↑ + ADC↓ → acute/ischemic), **SWI hypointensity** (→ hemorrhage/microbleed), **T2 hyperintensity** (→ corroborates FLAIR). It is corroboration ON TOP of the primary detection — it never re-detects or alters the lesion mask. Outputs the per-cluster table + summary under `analysis/cross_modal/`. Config: the `CROSS_MODAL_*` block (`MULTIMODAL_SECONDARY_MODALITIES`, per-modality z thresholds) in `config/default_config.sh`.

## Output layer (canonical tree + summary tables + top-level report)

The FINAL pipeline stage (Step 8.5, `reporting.sh::generate_summary_report`, after analysis/QA/viz) is the aggregation/reporting layer over every merged capability. It DISCOVERS outputs wherever modules wrote them (it does not require every module to use fixed paths) and emits:

- **Summary tables** under `reports/tables/`, each as **CSV/TSV + HTML** (and a `manifest.json`): `hyperintensity_per_region` (region × source: cluster count, volume, mean/peak z — from per-region GMM `region_provenance.tsv` + a `region_stats.tsv` sidecar the bash layer computes via `fslstats`), `wmh_tool_volumes` (one row per enabled tool, total + brainstem-restricted volume + clusters from each `<tool>_wmh_summary.txt`), `segmentation_volumes` (HO gross / FS substructures / multi-atlas nuclei / SynthSeg-aseg / subregions), `cross_modal` (passthrough of `analysis/cross_modal/cross_modal_clusters.csv`), `freesurfer_morphometry` (aseg volumes + eTIV from `freesurfer/harvest/stats/aseg.stats`), and a `run_manifest` (which seg paths / WMH tools / modalities / tables actually ran).
- **Report visualizations** under `visualizations/` (`visualization.sh::generate_report_visualizations`): per-method segmentation overlays on T1, hyperintensity clusters on FLAIR, and a multi-modal montage (lesion mask on FLAIR/DWI/SWI/T2). Honours `SKIP_VISUALIZATION`.
- **Top-level report** `reports/brainstemx_report.html` (+ `.md` fallback): a one-stop dashboard embedding all populated tables, the run manifest, and the discovered visualizations.

Heavy parsing/rendering is in the stdlib-only `reporting_tables.py` (run via `uv`); the bash layer owns only the FSL-dependent parts (mask discovery + `fslstats` volume sidecars). Everything is **gated/graceful** (a minimal T1+FLAIR run still produces a valid smaller report; absent sections render as "No data") and **idempotent**. Governed by `REPORTING_ENABLED` (default `true`). Canonical tree + table schemas: `docs/output_structure.md`.

## Runtime notes

- ANTs is memory-intensive — 16+ GB RAM recommended
- NIfTI files can exceed 1 GB
- macOS: use `safe_fslmaths` wrapper instead of `fslmaths` directly
- Logs: `$RESULTS_DIR/logs/`
- Python: always invoke via `uv run`, never bare `python`/`python3`
- Environment: `source ~/.bash_profile` before running the pipeline
- Multi-atlas labeling (`BRAINSTEM_SEGMENTATION_METHOD=multi_atlas`/`bianciardi`)
  requires the Bianciardi/CIT168/AAL3 atlases on disk under `$FSLDIR/data/atlases`
  — see `docs/multi_atlas_integration_spec.md`. Caches build under `*/derived/`.
