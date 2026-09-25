# Handover: branch `feat/tender-noether-r53yyv`

Status of the work on this branch and exactly how to continue it. Read
`CLAUDE.md` first (it is current); this file adds what a new agent or
developer needs beyond it.

## 1. What this branch delivered

All items have unit tests, docs and CI coverage. Everything was built in a
cloud container **without FSL/ANTs/FreeSurfer and without real MRI data**:
every quantitative claim so far comes from the synthetic phantom.

1. **Atlas registry** — `src/modules/atlas_registry.sh`, config block in
   `config/default_config.sh`, spec in `docs/multi_atlas_integration_spec.md`.
   Shipped keys: `jhu`, `xtract` (ship with FSL), `aan`, `lc`, `dr`,
   `nextbrainmni` (downloads). Downstream code iterates
   `MULTI_ATLAS_SOURCE_TAGS`.
2. **NextBrain tool wrapper** — `src/modules/brainstem_nextbrain.sh`.
3. **Visual QC renderer** — `src/modules/viz_render.py` + hooks in
   `src/modules/visualization.sh`; figures under `visualizations/<stage>/`,
   gallery `visualizations/index.html`.
4. **Detection engine** — `src/modules/lesion_posterior.py`
   (`DETECTION_ENGINE=posterior`, default), `docs/detection_engine.md`.
5. **Benchmark scaffolding** — `src/benchmark/`, `scripts/benchmark.py`,
   `docs/benchmarking.md`.
6. Consensus votes per source family; `ANALYSIS_MIN_REGION_VOXELS` +
   `region_skips.tsv`; `set -u` and T2-discovery bug fixes.

## 2. Local setup and the check set

```bash
git checkout feat/tender-noether-r53yyv
uv sync                                  # Python 3.12.8
uv tool install shellcheck-py            # if shellcheck is missing
source ~/.bash_profile                   # FSL / ANTs / FreeSurfer
```
Run the full CI check set in `CLAUDE.md` ("CI / local checks") before and
after every change. It passes today.

## 3. Atlases to obtain (never commit them)

| key | source | put under `$FSLDIR/data/atlases/` | notes |
|---|---|---|---|
| `jhu` | ships with FSL | `JHU/` | `JHU-ICBM-labels-1mm.nii.gz` + `JHU-labels.xml` |
| `xtract` | ships with FSL ≥ 6.0.4 (`fsl-data_atlases_xtract`) | `XTRACT/` | else `USE_XTRACT=false` |
| `aan` | https://datadryad.org/dataset/doi:10.5061/dryad.zw3r228d2 | `AAN/` | after one run, check `segmentation/multi_atlas/aan_MNI_labels.txt` names against `ATLAS_AAN_SUBDIV` prefixes |
| `lc` | https://www.nitrc.org/projects/lc_7t_prob/ (login; CC BY-NC-ND) | `LC/` | ICBM 2009b space → needs the transform below; glob `LC*prob*.nii*` must match one file |
| `dr` | https://zenodo.org/records/10680563 (CC BY) | `DorsalRaphe/` | 2009b space |
| `nextbrainmni` | https://github.com/compneurobilbao/nextbrain-mni-atlas | `NextBrain/` | |
| transform | https://templateflow.s3.amazonaws.com/tpl-MNI152NLin6Asym/tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5 | anywhere | `export MNI_2009C_TO_NLIN6_XFM=…` |
| NextBrain tool | FreeSurfer 8 dev + licence | n/a | run `mri_histo_atlas_segment_fireants` once interactively to fetch its atlas |

First real-data check of the registry: run one subject with
`BRAINSTEM_SEGMENTATION_METHOD=all`, open
`visualizations/segmentation/labels_<key>.png` and `pons_focus.png`; every
contour must sit on the subject's brainstem. A millimetre-scale offset means
`ATLAS_<KEY>_SPACE` is wrong.

## 4. Datasets and the benchmark protocol

`uv run python scripts/benchmark.py datasets` lists sources, access and
citations. ds004199 (OpenNeuro, CC0) is fetched anonymously via
`scripts/benchmark.py fetch`; WMH 2017, ISBI 2015, MSSEG 2016 and Shifts need
registration/agreements — convert them to BIDS
(`sub-X/anat/sub-X_FLAIR.nii.gz`, `_T1w.nii.gz`, GT `sub-X_FLAIR_roi.nii.gz`)
and use `--dataset custom`.

```bash
uv run python scripts/benchmark.py run --dataset ds004199 --root /data/ds004199 --adapter legacy_gmm --region auto --out runs/legacy
uv run python scripts/benchmark.py run --dataset ds004199 --root /data/ds004199 --adapter posterior  --region auto --out runs/post
uv run python scripts/benchmark.py ab --a runs/legacy --b runs/post --out runs/ab
uv run python scripts/benchmark.py compare-known --run runs/post
uv run python scripts/benchmark.py report --run runs/post --ab runs/ab
```
Prefer a per-subject WM mask (`--region '/data/masks/{subject}_wm.nii.gz'`)
over `auto` (Otsu). Then score full pipeline runs with
`--adapter precomputed --param pred_pattern='…/{subject}/results/hyperintensities/*_threshATLAS_GMM_bin.nii.gz'`
for both engines. `src/benchmark/known_benchmarks.json` numbers are
approximate until `verified: true` — check them against the papers.

## 5. Open work, in priority order

1. **Any-region detection** — `DETECTION_REGION_SET=custom` +
   `DETECTION_CUSTOM_MASKS` is done (`analysis.sh::detect_custom_regions`);
   still missing: a `whole_brain` set with registry keys
   for Harvard-Oxford cortical/subcortical labels written to
   `segmentation/detailed_regions/`, a second union output, a WM parent null
   (`LESION_PARENT_NULL`) for small regions, reporting + figures.
2. **Visualisation plan remainder** — renderer subcommands `agree`
   (multi-mask agreement + Dice matrix), `panels` (side-by-side modalities,
   per-cluster montage from `analysis/cross_modal/cross_modal_clusters.csv`),
   `chart` (TSV bars/matrix/tiles for QA and registration dashboards);
   hooks in `cross_modal_analysis.sh` and the `wmh_*.sh` modules.
3. **Real-data engine tuning** — after ds004199 controls and one challenge
   set: `LESION_FDR_Q`, `LESION_MRF_BETA`, `LESION_MIN_CLUSTER_VOXELS`,
   anisotropic MRF weights for thick-slice FLAIR. Decide only via A/B with
   paired CIs; never reintroduce SD multipliers or percentile floors.
4. **Atlas verification leftovers** — AAN LUT names, the LC glob, JHU index 0
   never becoming a mask.

## 6. Gotchas

- Sourced modules never `set -e -u -o pipefail`; optional paths return 0 with
  a WARNING. Python only via `uv run` (legacy `gmm_threshold.py` is still
  called with bare `python3` — switch when touched).
- Tests mock FSL (`tests/test_helpers.sh`); `safe_fslmaths` needs the
  `fslinfo` mock.
- ICBM-2009 atlases are skipped without the TemplateFlow transform by design.
- `tests/test_segmentation*.sh` and the integration tests need real FSL and
  are not in CI; run them locally as the first smoke of the new paths.
