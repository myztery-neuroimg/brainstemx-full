# Synthetic Test Data for Brainstem Hyperintensity Detection

Status: design spec / recipe. This document describes how to build a synthetic
brainstem-lesion test set and a perturbation/mutation regression suite for
BrainStem X. The goal is a *controllable ground truth*: lesions whose location,
size, and contrast we set, so that every step of the pipeline's decision-making
(CSF/PV exclusion → per-region GMM thresholding → cluster filtering → DICOM
backtrace) can be validated against a known answer rather than a black-box label.

> **Why this matters / project novelty.** A dedicated *brainstem small-lesion
> simulator* is, as far as we can find, **unclaimed** in the 2024–2026
> literature — all published synthetic-lesion work is supratentorial (WMH in the
> periventricular/deep white matter, MS lesions, stroke). Combined with the
> per-region brainstem GMM thresholding (itself a published gap), this synthetic
> test set is both a validation tool and a contribution in its own right. It is
> also a lack-of-precedent caveat: there is no external brainstem benchmark to
> compare against, so the recipe must build its own ground truth.

Items marked **[preprint]** / **[no released code]** are flagged as such; cite
them with that caveat or omit.

## Two generation tracks

### Track A — label-conditioned (insert known labels, then render)

Start from a label map (a healthy subject's segmentation or an atlas label
volume), insert one or more **known hyperintensity labels** at chosen brainstem
coordinates (e.g. dorsal pons, midbrain tegmentum), then *render* a realistic
FLAIR from the augmented label map and warp it into subject space.

1. **Insert labels.** Add lesion labels to the brainstem region of a clean label
   map (FreeSurfer aseg / SynthSeg output, or an atlas dseg). Lesion shape/size
   is parameterised (small punctate → confluent) so the test set spans the
   regime the pipeline targets.
2. **Render FLAIR from labels.** Use a label-conditioned generator:
   - **brainSPADE3D** — Fernandez/Pinaya et al., *Generating Synthetic Brain MR
     Images with Labels for Lesion Segmentation*, Med Image Anal 2024 (SASHIMI
     2023; arXiv:2311.04552). A 3D semantic-diffusion model that synthesises
     brain MR (incl. lesions) from a label map — the canonical "labels →
     image" route.
   - **SynthSeg / WMH-SynthSeg** — Billot et al., Med Image Anal
     2023;86:102789; Laso et al., IEEE ISBI 2024 (arXiv:2312.05119). The
     domain-randomised SynthSeg *generative model* renders contrast-agnostic
     images from label maps; WMH-SynthSeg adds a WMH label class. Useful as a
     fast, license-clean renderer when full diffusion synthesis is overkill.
   - **Med-DDPM** — Dorjsembe et al., *Conditional Diffusion Models for
     Semantic 3D Brain MRI Synthesis*, IEEE JBHI 2024;28(7):4084-4093 (mask →
     volume conditional DDPM, an alternative renderer).
   - **SynthSR** — Iglesias et al., Sci Adv 2023;9(5):eadd3607 (super-resolution
     / contrast normalisation to make rendered volumes pipeline-realistic).
3. **Warp through ANTs.** Push the rendered FLAIR (and its lesion ground-truth
   mask) through the same SyN transforms the pipeline uses, so the synthetic
   data lives in exactly the spaces the pipeline expects and the ground-truth
   mask backtraces the way real detections do.

### Track B — blend small synthetic lesions into clean 3D-FLAIR

Start from a clean, high-quality 3D-FLAIR and **blend** small synthetic lesions
directly into the brainstem, keeping the surrounding anatomy real.

- **Soft Poisson Blending** of small synthetic lesions — Basaran et al., MICCAI
  SASHIMI 2022 (arXiv:2208.02135). Gradient-domain (Poisson) blending inserts a
  lesion patch with seamless intensity transitions — ideal for *small* brainstem
  lesions where hard pasting produces obvious edges. This is the primary Track B
  method.
- **CarveMix** — Zhang et al., MICCAI 2021 / NeuroImage 2023. Lesion-aware
  cut-and-mix augmentation; copy a carved lesion region (with soft boundaries)
  between volumes. Good for cheaply expanding the lesion-position/shape space.
- **Self-supervised lesion generation** — Huo et al., 2024 (arXiv:2406.14826)
  **[preprint]**. Self-supervised synthesis of lesions for training/augmentation.
- **LesionGAN** (small-lesion exemplar) — Momeni et al., Front Neurosci 2021.
  GAN-based small-lesion synthesis; an exemplar of the small-lesion regime.
- **SynthStroke** — Chalcroft et al., JMLBI 2025 (arXiv:2404.01946). Synthetic
  stroke-lesion generation; relevant as a related infarct/lesion synthesiser
  (still supratentorial — adapt with care).

Track B keeps real CSF pulsation, partial-volume, and acquisition texture around
the lesion, which Track A's fully-rendered images do not — so the two tracks are
complementary (B = realistic surround, controlled lesion; A = fully controlled
anatomy + lesion).

## Mutation / perturbation regression suite (TorchIO + MONAI)

Beyond inserting lesions, we mutate *clean* and *lesioned* inputs to test the
pipeline's robustness and, crucially, its **false-positive behaviour** under the
artifacts that plague the posterior fossa. Implemented with **TorchIO** and
**MONAI** transforms:

- **TorchIO** — Pérez-García et al., Comput Methods Programs Biomed
  2021;208:106236.
- **MONAI** — Cardoso et al., 2022 (arXiv:2211.02701).

Key perturbations and what they probe:

| Transform | Models | Tests |
|---|---|---|
| `RandomGhosting` | CSF-pulsation / flow ghosting | the dominant brainstem FP source — does CSF/PV exclusion + FP filter hold up? |
| `RandomMotion` | head motion | cluster stability under blur/duplication |
| `RandomBiasField` | residual B1 inhomogeneity | does FLAIR N4 / z-scoring stay lesion-faithful? |
| `RandomGibbs` (Gibbs ringing) | truncation ringing near sharp CSF/tissue edges | edge artifacts mistaken for lesions |
| `RandomNoise` / `RandomBlur` (resolution) | SNR / thick-slice clinical data | sensitivity at low SNR and 2D thick-slice |

The regression test asserts that (a) inserted lesions are still detected after
perturbation (sensitivity), and (b) **no new clusters** appear from
ghosting/ringing alone on lesion-free inputs (specificity / FP control). The
`RandomGhosting`-as-CSF-pulsation case directly exercises the dominant
infratentorial failure mode.

## Physics-faithful artifacts (optional, higher fidelity)

For artifacts that augmentation transforms only approximate, simulate from spin
physics / acquisition:

- **KomaMRI.jl** — Castillo-Passi et al., MRM 2023;90(1):329-342. A GPU Bloch
  simulator: generate physically-faithful MRI (incl. flow/motion/off-resonance
  artifacts) from a digital phantom + pulse sequence.
- **BigBrain-MR** — Sainz Martinez et al., NeuroImage 2023 (DOI
  10.1016/j.neuroimage.2023.120074). High-resolution multi-contrast digital
  phantom derived from BigBrain — a realistic substrate to drive KomaMRI.
- **BrainWeb** — Cocosco/Collins/Evans, McGill (1997–2006). The classic digital
  brain phantom with controllable noise/inhomogeneity; a cheap baseline.

These let CSF-pulsation, Gibbs ringing, and motion be simulated from the
acquisition rather than pasted on, which matters for the brainstem where the
4th-ventricle/basal-cistern CSF flow drives most false positives.

## Metamorphic testing (non-medical reference)

- **SegRMT** — Mzoughi et al., 2025 (arXiv:2504.02335) **[preprint;
  non-medical]**. Metamorphic testing of segmentation models: define
  metamorphic relations (e.g. "a contrast-preserving transform should not change
  the segmentation") and assert them. A useful *pattern* to adopt for the
  perturbation suite above, even though the paper's domain is not medical.

## Out of scope / flagged (do not rely on these here)

Cited only to record that they were considered; preprint / unreleased /
unverified — **omit or flag explicitly**:

- MSRepaint (arXiv:2510.02063) **[preprint]**
- THOMASINA **[preprint]**
- SuperSynth **[wiki-only, no paper]**
- Brain-SAM **[preprint]**
- wmh_seg (arXiv:2402.12701) **[preprint]**
- cVAE-normative **[bioRxiv]**
- EJR-2025 CSF-flow ROI score **[publisher 403, unverified]**
- TUMSyn **[no paired labels]**

## Summary

- **Track A** (brainSPADE3D / SynthSeg / WMH-SynthSeg / Med-DDPM, + SynthSR,
  warped through ANTs) gives fully-controlled anatomy with inserted labels.
- **Track B** (Soft Poisson Blending, CarveMix) inserts small synthetic lesions
  into real clean 3D-FLAIR, preserving realistic surround.
- A **TorchIO + MONAI** mutation suite (`RandomGhosting`=CSF-pulsation,
  `RandomMotion`/`RandomBiasField`/`RandomGibbs`/noise) is the regression
  harness; **KomaMRI.jl + BigBrain-MR / BrainWeb** add physics-faithful
  artifacts where higher fidelity is needed; **SegRMT** supplies the metamorphic
  testing pattern.
- The **brainstem small-lesion simulator is unclaimed** in current literature =
  project novelty *and* a no-external-benchmark caveat.
