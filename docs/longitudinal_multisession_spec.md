# Longitudinal Multi-Session Analysis & Borrowed Anatomical T1 Reference

> Status: design spec for planned (not-yet-merged) behavior. Implemented in the unit order in §8.

## 1. Motivation

BrainStemX is T1-anchored. Three hard dependencies assume a usable T1 exists:

1. The reference-selection step in `src/pipeline.sh` aborts when no T1 is found in a study.
2. FreeSurfer `recon-all` requires a non-contrast, full-head MPRAGE (`fs_resolve_recon_input` in `src/modules/brainstem_freesurfer.sh`).
3. Atlas warps go through a T1->MNI mapping (`src/modules/segmentation.sh`, `src/modules/multi_atlas.sh`).

Everything else (`register_to_reference`, SynthStrip brain extraction, N4 bias correction) is already modality-agnostic.

Two acquisition situations break the T1 assumption cleanly:

- **No T1 present** — a study acquired without any T1-weighted structural (for example, 3D-FLAIR plus SWI/DWI/T2 only). The pipeline aborts.
- **Contrast-enhanced T1 only** — the only available T1 is post-contrast. Post-gadolinium intensities violate recon-all's WM/GM intensity-normalization and surface-placement assumptions and corrupt the reconstruction; the contrast T1 nonetheless remains valuable as enhancement signal.

## 2. Solution overview

- **Layer 1 — Borrowed (external) anatomical T1 reference.** Allow the anatomical T1 to come from a different acquisition of the *same subject*. A non-contrast MPRAGE from any session can anchor recon-all, T1->MNI, atlas warping, and segmentation for a session that lacks a usable T1.
- **Layer 2 — Within-subject longitudinal common space.** Register all of a subject's acquisitions into one common space so anatomy and atlas labels are shared and timepoints are directly comparable.
- **Layer 3 — Longitudinal change analysis.** Compare lesions across timepoints in the common space.

## 3. Layer 1 — External anatomical T1 reference

| Variable | Purpose |
|---|---|
| `ANATOMICAL_REFERENCE_T1` | Path to an external non-contrast T1 to use as the anatomical anchor (default empty = current behavior). |
| `ANATOMICAL_REFERENCE_LABEL` | Free-text provenance label for the borrowed reference (recorded in outputs). |
| `PREFER_EXTERNAL_NONCONTRAST_T1` | When true, prefer an external non-contrast T1 over an in-study contrast-enhanced T1 for recon-all. |

Insertion points:

1. The no-T1 branch in `src/pipeline.sh` — if no in-study T1 exists but `ANATOMICAL_REFERENCE_T1` is set and present, adopt it (provenance = external) instead of aborting.
2. `src/modules/reference_space_selection.sh` — register the external T1 as a T1 candidate, and detect a post-contrast T1 via DICOM/JSON `ContrastBolusAgent` / `ImageType` (contains `CONTRAST`) plus filename heuristics.
3. `fs_resolve_recon_input` — select the non-contrast external T1 for recon-all when the in-study T1 is contrast-enhanced or absent.

The external T1 is the fixed reference; the session's own FLAIR and secondary series register to it through the existing T1-as-fixed path. Outputs record that the anatomical reference is external and its label.

## 4. Layer 2 — Within-subject common space

- Common-space definition: **v1** = the best available non-contrast T1 used directly; **v2 (optional)** = an unbiased within-subject template (`antsMultivariateTemplateConstruction2`, or FreeSurfer longitudinal `-base`).
- Per-session ingestion: run the existing per-study pipeline as the per-session worker (preprocess, brain-extract, and detect on each session's own FLAIR or contrast-T1), then register each session's reference image into the common space.
- recon-all runs once on the common-space T1, so substructures, aseg, and atlas labels are shared across all sessions.
- All session-to-common composed forward and inverse transforms are persisted, reusing the contrast-matched cascade persistence pattern.

## 5. Layer 3 — Longitudinal change analysis

- Resample each session's lesion mask and intensity maps into the common space.
- Metrics: per-region (brainstem substructure and atlas nucleus) lesion volume per timepoint and delta; new / resolved / growing / shrinking lesions via cross-timepoint label overlap; enhancement appearance and disappearance from any contrast-enhanced timepoint; DWI-restriction evolution.
- Outputs: a longitudinal change table (region x timepoint x volume/delta, CSV/TSV + HTML consistent with the reporting layer), new-lesion overlays, and a longitudinal section in the top-level report.

## 6. Registration parameters (same-subject)

- Default rigid (6 DOF) for within-subject same-modality (T1-to-T1) registration, to preserve morphometry.
- Cross-modal (FLAIR or contrast-T1 to T1): rigid initialization plus mutual information, with an optional constrained low-deformation SyN stage (tight regularization) — not full deformable.
- A new flag `WITHIN_SUBJECT_REGISTRATION` (default off) selects these rigid-dominant presets.

## 7. Provenance and QA caveats

- Every output is tagged with anatomical-reference provenance (in-study vs external, plus label).
- Cross-session alignment must be QA'd (overlay / Dice) and is human-in-the-loop.
- Real anatomical change between sessions (atrophy, mass effect) is not captured by rigid registration; large mismatches must be flagged. No method here is brainstem-validated; keep conservative pons QA.
- The pipeline ships the generic capability only. Subject-specific session maps and paths are supplied by the operator via configuration and must never be committed.

## 8. Implementation units

- **A. External anatomical T1 reference** — config, the no-T1 branch, `reference_space_selection.sh`, `fs_resolve_recon_input`, and provenance. Foundation.
- **B. Within-subject registration presets** — `WITHIN_SUBJECT_REGISTRATION` (rigid plus constrained SyN) in `registration.sh`.
- **C. Contrast-enhanced T1 detection** — prefer the non-contrast anchor; keep the contrast T1 as an enhancement modality.
- **D. Longitudinal orchestrator** — `src/longitudinal.sh` (discover sessions from an operator-supplied map, run the per-session pipeline, register all into the common space, recon once). Config: `LONGITUDINAL_MODE`, `LONGITUDINAL_SESSIONS`, `LONGITUDINAL_COMMON_SPACE`.
- **E. Longitudinal change analysis and reporting** — change table, new-lesion overlays, and a report section.

Implemented in unit order A -> (B, C) -> D -> E.
