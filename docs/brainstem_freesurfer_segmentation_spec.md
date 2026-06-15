# Spec: FreeSurfer brainstem substructures for BrainStemX (replace Talairach)

> **Status: IMPLEMENTED** in `src/modules/brainstem_freesurfer.sh` (Iglesias 2015 `segmentBS`/`brainstemSsLabels` → midbrain/pons/medulla/SCP), wired through `src/modules/segmentation.sh` and the per-region GMM in `src/modules/analysis.sh`, merged via PR #119 ("Replace Talairach brainstem subdivisions with FreeSurfer substructures"). Talairach has been **removed entirely** from the brainstem-subdivision path. The remaining sections below are the original design spec, retained for rationale/provenance; a few details differ from the as-built code and are flagged inline:
> - **Config default:** the spec proposed `BRAINSTEM_SEGMENTATION_METHOD=fusion` as the default; the merged code defaults to **`freesurfer`** (substructures) with **`atlas`** (Harvard-Oxford gross mask only; alias `harvard_oxford`) as the fallback — there is no `fusion` mode.
> - **HO extent:** the Harvard-Oxford gross Brain-Stem extent is tightened to `maxprob-thr25` (`HO_SUB_MAXPROB_THR`).
> - **Agreement gate config:** `FS_BS_AGREEMENT_DICE_MIN` and `FS_BS_AGREEMENT_LEAKAGE_MAX` (plus `FS_RECON_ALL_FLAG`, `FS_BS_LABEL_*`) live in `config/default_config.sh`.

Status: DRAFT (original design). Owner: David. Scope: `src/modules/segmentation.sh` / `hierarchical_joint_fusion.sh`, `src/modules/analysis.sh` (per-region GMM), `config/default_config.sh`, a new `src/modules/brainstem_freesurfer.sh`. Sibling approach to the document_processor `subject_space_localization_spec.md §3h` — this is the **deterministic-pipeline** counterpart.

## 1. Goal & grounding

BrainStemX is a brainstem/pons hyperintensity pipeline, so the brainstem parcellation is the *core*, not a side-pass — and it currently leans on **Talairach** for the brainstem subdivision (via `execute_hierarchical_joint_fusion` = Harvard-Oxford + Talairach + Juelich, plus `talairach_subdivisions`). Talairach is the weakest link: single-subject (one 1988 post-mortem brain), reaching MNI via an approximate transform whose offsets are *largest inferiorly/posteriorly* — worst exactly in the brainstem you care about. And HO alone can't replace it: HO has a single `Brain-Stem` label, no pons/midbrain/medulla.

This spec replaces Talairach's brainstem-subdivision role with **FreeSurfer brainstem substructures** (Iglesias 2015 — Bayesian segmentation into midbrain / pons / medulla / SCP), keeps Harvard-Oxford, and uses an **FS↔HO agreement cross-check** as a QC/confidence gate. The payoff is concrete and downstream: the FS parcels become the regions for the **per-region GMM** (`analysis.sh`), so a pontine hyperintensity is z-scored against *pons-specific* normal statistics instead of whole-brainstem or Talairach-subdivision stats.

It fits the deterministic ethos: FS-BS is a deterministic Bayesian segmentation (given fixed inputs + pinned FS version), unlike registration which needs a seed.

**The honesty ceiling is the same as the document_processor spec:** trust to the **parcel level** (pons/midbrain/medulla/SCP); the inter-parcel boundary is FS-asserted/uncorroborated; **dorsal vs ventral pons is never emitted** — no atlas or off-the-shelf segmentation supports it (geometric estimation was crude; a custom ML model is the future frontier, out of scope here).

## 2. Current state

- **Brainstem segmentation:** `segmentation.sh` → `execute_hierarchical_joint_fusion` (`hierarchical_joint_fusion.sh`) fusing **HO + Talairach + Juelich** (`JOINT_FUSION_*` params in `default_config.sh`); `talairach_subdivisions/` is the brainstem subdivision artifact. Subject-space (atlases warped into the subject via the registration stage; validated by `segmentation_validate_atlas_in_subject_space.sh`).
- **Per-region analysis:** `analysis.sh` → `find_all_atlas_regions` → `apply_per_region_gmm_analysis` (`ATLAS_GMM`) z-scores hyperintensity per atlas region; `GMM_MIN_VOXELS=20` gates GMM vs the `THRESHOLD_WM_SD_MULTIPLIER` fallback. Pons mask looked up from `segmentation/detailed_brainstem/…`.
- **FreeSurfer:** binaries present (`environment.sh` checks `mri_convert`/`freeview`), but **recon-all is not currently run** — the pipeline uses ANTs/FSL. FS-BS needs recon-all outputs.

## 3. The change

### 3a. Drop Talairach as the brainstem-subdivision source
Remove Talairach from the brainstem path in `hierarchical_joint_fusion.sh` / retire `talairach_subdivisions` as the subdivision artifact. Keep **HO** (gross `Brain-Stem` extent + supratentorial). **Juelich** is orthogonal (cytoarchitectonic/WM, not a brainstem subdivision) — out of scope for this change; revisit separately.

### 3b. New stage — FreeSurfer brainstem substructures (`brainstem_freesurfer.sh`)
- Run `recon-all` on the chosen structural reference (the pipeline's existing reference T1), then `segmentBS.sh` (`mri_segment_brainstem`) → `brainstemSsLabels.*` → split into **pons / midbrain / medulla / SCP** masks, in **subject space** (no warp — FS segments the subject's own T1, which suits BrainStemX's subject-space paradigm).
- **Deterministic + pinned:** record the FreeSurfer version in provenance; FS-BS is reproducible given fixed T1 + version.
- **Prereqs/cost:** requires `FREESURFER_HOME` + a **FreeSurfer license** (`$FS_LICENSE`) — guard for it and fail with a clear `ERR_*` if absent. recon-all is *hours* (or use `-brainstem-structures` on an existing recon); so this is a **resumable, cached** stage — skip if `brainstemSsLabels` exists for the subject; never recompute.

### 3c. FS↔HO agreement cross-check (the QC gate)
- **Metric = `Dice(FS-brainstem-union, HO-`Brain-Stem`-in-subject-space)` + leakage** (fraction of FS parcels falling outside the HO blob). **Not** tautological pons-in-brainstem containment (anatomically guaranteed). These structures are small, so even modest mislocalization (esp. HO's warp mislanding posteriorly) tanks the union-Dice / shows leakage → a sensitive check. Implement alongside `segmentation_validate_atlas_in_subject_space.sh`.
- **Independent methods:** FS-BS = segmentation on the subject T1 (no registration); HO = warped template. Agreement is genuine corroboration (unlike Talairach+HO, which shared registration error).
- **Gate:** agree (Dice ≥ threshold, low leakage) → trust FS parcels, emit pons/midbrain/medulla/SCP with confidence. Disagree → fall back to HO `Brain-Stem` gross mask, flag low-confidence in the report. Threshold calibrated like the existing brain-mask-Dice QC.

### 3d. Feed FS parcels into the per-region GMM (`analysis.sh`)
- `find_all_atlas_regions` picks up the FS parcels as the brainstem regions; `apply_per_region_gmm_analysis` then z-scores hyperintensity **per parcel** (pons-normal, midbrain-normal…) — tighter and more sensitive than whole-brainstem or Talairach-subdivision stats. This is the deterministic-pipeline payoff.
- **Small-parcel caveat:** SCP (and partial-coverage parcels) may fall below `GMM_MIN_VOXELS=20` → GMM skips and the `THRESHOLD_WM_SD_MULTIPLIER` fallback applies. Ensure that fallback is sane per-parcel; log when a parcel uses fallback.

### 3e. Label semantics
Parcel-level only: **pons / midbrain / medulla / SCP**. The inter-parcel boundary is FS-asserted (uncorroborated). **Dorsal/ventral pons is never produced** — neither FS nor any atlas supports it.

## 4. Deterministic-pipeline integration (BrainStemX conventions)

- **Module:** new `src/modules/brainstem_freesurfer.sh` — `#!/usr/bin/env bash`, `set -e -u -o pipefail`, include guard (`if [ -n "${_BRAINSTEM_FS_LOADED:-}" ]; then return 0; fi`), `source require_env.sh`, `log_message`/`log_formatted`/`log_error` at entry, `ERR_*` constants (e.g. a new `ERR_FREESURFER` or reuse `ERR_PREPROC`), macOS-safe (`safe_fslmaths`, no `timeout`). Python helpers via `uv run` (FS itself is its own binaries).
- **Config (`default_config.sh`, with the `_DEFAULT_CONFIG_LOADED` guard):**
  `export BRAINSTEM_SEGMENTATION_METHOD="${BRAINSTEM_SEGMENTATION_METHOD:-fusion}"` (`fusion` = current, default; `freesurfer` = this approach; `harvard_oxford` = gross-only). Plus `FREESURFER_HOME`/`FS_LICENSE` checks and `FS_BS_AGREEMENT_DICE_MIN` (mirror the existing Dice-QC threshold style).
- **Stage + resumability:** slot as a brainstem-segmentation alternative selectable by `BRAINSTEM_SEGMENTATION_METHOD`; recover all file-path vars from disk on skip (per the pipeline's stage-resumability rule); cache recon-all + `brainstemSsLabels` so re-runs skip the hours-long step.
- **CI/tests:** add a parcel-sanity + agreement-Dice test next to `test_atlas_positioning_*`; keep `bash -n` / shellcheck-error clean.

## 5. Guardrails

1. **Honesty ceiling at the parcel.** Pons/midbrain/medulla/SCP, never finer; boundary FS-asserted; no dorsal/ventral pons.
2. **Agreement-gated.** FS parcels are trusted only when they agree with HO's gross brainstem extent; disagreement → fall back + flag, never silently emit a mislocalized parcel.
3. **Opt-in, default unchanged.** `BRAINSTEM_SEGMENTATION_METHOD=fusion` stays the default; `freesurfer` is opt-in so existing runs are untouched.
4. **Deterministic + version-pinned.** Record FS version; FS-BS reproducible given fixed inputs.
5. **License/abstain.** No FS license / recon-all unavailable → clear error or fall back to HO gross, never a half-segmentation.

## 6. Risks & open items

1. **recon-all cost (hours) — reduced on Apple Silicon, not eliminated.** Two levers: (a) the **native `darwin_arm64` FreeSurfer build** removes the Rosetta-x86 penalty (still CPU-bound surface recon, so "less-slow hours"); (b) **FastSurfer with `--device mps` + `PYTORCH_ENABLE_MPS_FALLBACK=1`** (≥2× CPU; op-gaps like `aten::max_unpool2d` fall to CPU) does the segmentation in minutes — the **same MPS pattern as the Prima spec**, so the Mac Studio MPS setup serves both. **Open verification (gates M1):** FastSurfer's fast aseg gives a single `Brain-Stem` label (HO-equivalent, no subdivision) — the Iglesias pons/midbrain/medulla parcels come from `segmentBS`, so confirm whether FastSurfer outputs satisfy the brainstem module's inputs or whether full (native-ARM) recon-all is still required for it. Either way, cache/resume; consider `-brainstem-structures` on an existing recon to skip a full re-run.
2. **FreeSurfer license** required — environment guard + actionable error.
3. **FS version reproducibility** — different FS versions can shift parcel boundaries; pin + record.
4. **Small-parcel GMM fallback** (SCP) — verify the SD-multiplier fallback is appropriate at small voxel counts.
5. **T1 quality / pathology** — FS-BS is robust but a heavily distorted brainstem (mass, severe atrophy) can mis-segment; the FS↔HO gate catches gross failures, not subtle ones.
6. **Boundary uncorroborated** — downstream consumers must treat pons↔midbrain as approximate; don't build a sub-pontine claim on it.

## 7. Milestones

- **M0 — Apple-Silicon path probe (do first).** On the Mac: confirm the native `darwin_arm64` FreeSurfer build; time FastSurfer `--device mps` (+`PYTORCH_ENABLE_MPS_FALLBACK=1`) on one subject; and settle the open question — do FastSurfer outputs feed `segmentBS`, or is full native-ARM recon-all still needed for the brainstem module? Determines M1's cost path. Check whether a recon already exists for the validation subjects (skip the hours).
- **M1 — FS-BS stage.** `brainstem_freesurfer.sh`: (FastSurfer-MPS and/or native-ARM recon-all, cached) → `segmentBS.sh` → pons/midbrain/medulla/SCP masks in subject space, behind `BRAINSTEM_SEGMENTATION_METHOD=freesurfer`. Accept: parcels produced + cached; license/abstain handled.
- **M2 — Agreement cross-check.** FS-union-vs-HO-blob Dice + leakage → confidence flag in the report; disagreement falls back to HO gross. Accept: agreement reported per subject; a deliberately mis-registered case flags/falls back.
- **M3 — Per-region GMM on FS parcels.** `find_all_atlas_regions`/`apply_per_region_gmm_analysis` consume the FS parcels; per-parcel z-scoring; small-parcel fallback logged. Accept: hyperintensity thresholded per pons/midbrain/medulla; results comparable to (or better-localized than) the Talairach-subdivision baseline on a known case.
- **M4 — Talairach retired + docs/tests.** Drop Talairach from the brainstem path; parcel-sanity + agreement test; `bash -n`/shellcheck clean; maintain the project log per the global rule.

## 8. Out of scope

Dorsal/ventral pons or any sub-parcel granularity (custom-ML frontier); Juelich reassessment; supratentorial labeling changes (HO stays); replacing the registration/GMM machinery itself (only swapping the brainstem-subdivision source and feeding the GMM); cross-study/longitudinal subject space (that's the document_processor spec's concern).
