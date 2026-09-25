# Benchmarking and A/B verification

`src/benchmark/` + `scripts/benchmark.py` provide reproducible, ground-truth
evaluation of the lesion detection: public datasets with expert masks, a
synthetic phantom with *known* lesions (including brainstem lesions and
lesion-free controls), a metric suite following the WMH-challenge / MS-challenge
conventions, pluggable detection adapters (legacy engine, new engine, or any
pre-computed masks), paired A/B statistics and a report. Nothing is vendored:
open datasets are fetched from their public source at run time, registration-
gated datasets are referenced with instructions and licence.

```bash
uv run python scripts/benchmark.py datasets                       # registry + access + citations
uv run python scripts/benchmark.py phantom --out /tmp/phantom      # synthetic BIDS set with GT
uv run python scripts/benchmark.py fetch --dataset ds004199 --root /data/ds004199 --subjects sub-00006 sub-00005
uv run python scripts/benchmark.py run --dataset phantom --root /tmp/phantom --adapter legacy_gmm --region brainstem --out runs/legacy
uv run python scripts/benchmark.py run --dataset phantom --root /tmp/phantom --adapter posterior  --region brainstem --out runs/posterior
uv run python scripts/benchmark.py ab --a runs/legacy --b runs/posterior --out runs/ab
uv run python scripts/benchmark.py compare-known --run runs/posterior --reference wmh2017
uv run python scripts/benchmark.py report --run runs/posterior --ab runs/ab
```

## Datasets (`src/benchmark/datasets.py`)

| key | access | ground truth | notes |
|---|---|---|---|
| `phantom` | generated | inserted spheres (`*_FLAIR_roi.nii.gz`) | WM + brainstem lesions, bias field, Rician noise, controls |
| `ds004199` | open (anonymous S3 / openneuro-py) | FCD FLAIR ROI (85 patients) + 85 controls | CC0; `docs/ds004199_validation_dataset.md`; controls = false-positive burden |
| `custom` | local BIDS | `*_FLAIR_roi.nii.gz` (configurable `--gt-suffix`) | any converted dataset |
| `wmh2017` | data-use agreement | manual WMH masks | Kuijf 2019; convert to BIDS → `custom` |
| `isbi2015` | registration | two raters | Carass 2017 |
| `msseg2016` | registration (Shanoir) | 7-expert consensus | Commowick 2018 |
| `shifts_ms` | open (project page) | expert masks | Malinin 2022 |

BIDS layout expected by the parser: `sub-*/anat/sub-*_FLAIR.nii.gz`, optional
`_T1w.nii.gz`, GT `_FLAIR_roi.nii.gz` (absent ⇒ control), optional
`_desc-{brain,wm,brainstem}_mask.nii.gz` region masks.

## Adapters (`src/benchmark/adapters.py`)

| adapter | what it evaluates |
|---|---|
| `threshold` | robust-z baseline (median/MAD in the region, `k` SD) |
| `legacy_gmm` | the pipeline's legacy engine: region mean/SD z-score + `gmm_threshold.py` adaptive threshold + 95th-percentile floor (the bash connectivity re-threshold is not reproduced) |
| `posterior` | the principled engine (`src/modules/lesion_posterior.py`, `DETECTION_ENGINE=posterior`) — probability map + mask |
| `precomputed` | masks from a full pipeline run or any tool (`--param pred_pattern='runs/{subject}/hyperintensities/*_threshATLAS_GMM_bin.nii.gz'`) |

`--region brain|wm|brainstem|auto|<glob>` selects the analysis region (mask
files from the dataset, or an Otsu brain mask for `auto`).

## Metrics (`src/benchmark/metrics.py`)

Voxel Dice / Jaccard / sensitivity / precision; lesion-wise TPR / PPV / F1
(26-connected components, any-voxel overlap = WMH-challenge rule, configurable);
absolute volume difference (%); 95th-percentile surface distance (mm); Brier
score + expected calibration error for probability maps; on controls the
false-positive volume and lesion count. Aggregates carry bootstrap 95% CIs;
A/B comparisons are paired per subject (mean difference, bootstrap CI,
Wilcoxon signed-rank, fraction of subjects improved).

## Published reference numbers

`src/benchmark/known_benchmarks.json` lists headline results of the cited
challenges (WMH 2017, ISBI 2015, MSSEG 2016, LST, Shifts). They are
**approximate** (`verified: false`) until checked against the source tables and
protocols differ between challenges — use them for orientation, not as a
pass/fail bar. No brainstem-specific public benchmark exists; the phantom and
the ds004199 controls are the brainstem-relevant checks.

## Current phantom A/B (legacy GMM vs posterior engine)

8 lesion + 4 control phantoms, region-scoped scoring (`scripts/benchmark.py run … --region brainstem|wm`):

| region | engine | Dice | lesion F1 | lesion TPR | control FP volume |
|---|---|---|---|---|---|
| brainstem | legacy | 0.01 | 0.38 | 0.38 | 25 mm³ |
| brainstem | posterior | 0.85 | 1.00 | 1.00 | 0 |
| white matter | legacy | 0.00 | 0.00 | 0.00 | 614 mm³ |
| white matter | posterior | 0.89 | 1.00 | 1.00 | 0 |

## Tests

`tests/test_benchmark.py` (pytest, no FSL): phantom generation, metric
correctness on constructed cases, adapters, runner, A/B, reference comparison,
report and the CLI.
