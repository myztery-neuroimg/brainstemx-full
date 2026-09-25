# Lesion detection engine (`DETECTION_ENGINE=posterior`)

`src/modules/lesion_posterior.py` replaces the legacy per-region chain
(region-mean z-score → 2–3-component GMM upper component + k·SD →
95th-percentile floor → smoothed re-threshold) with a statistically explicit
model. It is region-agnostic (any binary mask), exposes calibrated per-voxel
probabilities, and flags nothing on a healthy region. The legacy chain stays
selectable (`DETECTION_ENGINE=legacy`) for A/B comparison
(`docs/benchmarking.md`).

## Why the legacy chain had to go

| step | legacy | problem |
|---|---|---|
| reference | region's own mean/SD | lesion voxels inflate the SD and shift the mean, so true lesions get *smaller* z the larger they are |
| decision | upper-GMM mean + k·SD, k chosen by component weight | k is a tuning constant, not an error rate; unstable on small regions |
| floor | ≥ 95th percentile of the region | ~5 % of *every* region is always a candidate, including healthy ones |
| spatial | Gaussian-smoothed candidate × z, re-thresholded with region stats | no probabilistic meaning; adds and removes voxels arbitrarily |

Phantom A/B (`scripts/benchmark.py`, 8 lesion + 4 control phantoms,
region-scoped scoring):

| region | engine | Dice | lesion F1 | lesion TPR | FP lesions | control FP volume |
|---|---|---|---|---|---|---|
| brainstem | legacy | 0.01 | 0.38 | 0.38 | 0 | 25 mm³ |
| brainstem | posterior | **0.85** | **1.00** | **1.00** | 0 | **0** |
| white matter | legacy | 0.00 | 0.00 | 0.00 | 0 | 614 mm³ |
| white matter | posterior | **0.89** | **1.00** | **1.00** | 0 | **0** |

(paired Wilcoxon p = 0.008 for Dice and volume error in both regions; the
phantom is a simplified model — see the caveats below.)

## Algorithm

1. **Gate.** R′ = R ∩ brain ∩ {p_CSF < `csf_thr`}; for regions large enough a
   1-voxel boundary band is removed from the *null pool* (partial volume),
   never from the analysed voxels.
2. **Robust, lesion-uncontaminated null.** Tukey biweight location + MAD scale
   on the null pool; for regions ≥ 3000 voxels a low-order spatial trend
   (`LESION_TREND_DEGREE`, IRLS biweight) removes residual bias so a smooth
   intensity gradient is not mistaken for a lesion. z = (I − μ(x)) / s. Small
   regions (< `LESION_MIN_GATED_VOXELS`) are flagged `small_region_low_confidence`
   and can be shrunk toward a parent/reference null (`LESION_PARENT_NULL`).
   An optional co-registered T2 (`LESION_T2_IMAGE`) is combined by a weighted
   Stouffer rule.
3. **Empirical null (Efron two-groups model).** log f(z) is fitted as a
   quadratic on the histogram of the central quantile window (central
   matching) giving N(δ₀, σ₀²) and the null proportion π₀. The marginal f(z)
   comes from a Lindsey Poisson-polynomial fit (N ≥ 3000) or a Gaussian KDE.
   local fdr(z) = min(1, π₀ f₀(z) / f(z)), forced non-increasing on the right
   tail; **posterior P(lesion | z) = 1 − fdr(z)**.
4. **Decision without multipliers.** Primary mask = the largest set of voxels,
   ordered by posterior, whose mean local fdr ≤ q (`LESION_FDR_Q`, 0.05): the
   posterior-expected-FDR rule, which adapts to prevalence (healthy region ⇒
   empty set). A Benjamini–Hochberg tail-area mask on one-sided p-values of
   the empirical null is written alongside for comparison.
5. **Spatial prior.** Mean-field Potts MRF (`LESION_MRF_BETA`, 6-neighbourhood,
   weaker across thick slices) on the voxel posteriors, then the same FDR
   rule on the regularised posterior; clusters smaller than
   `LESION_MIN_CLUSTER_VOXELS` or with mean posterior < `LESION_CLUSTER_POSTERIOR`
   are dropped.
6. **Reliability flags.** `high_lesion_load_null_unreliable` when π₀ is low,
   > 25 % of the region sits beyond z = 3, or a BIC test finds a substantial
   well-separated bright mode (confluent disease: no within-region null is
   identifiable — a cross-subject reference is needed);
   `region_wide_shift_vs_parent`; `too_few_voxels`.

## Outputs per region

`<prefix>_posterior.nii.gz`, `_lfdr.nii.gz`, `_z.nii.gz`, `_mask.nii.gz`
(primary), `_mask_bh.nii.gz`, `_clusters.tsv`, `_params.txt` (key=value:
`NULL_MEAN`, `NULL_SD`, `DELTA0`, `SIGMA0`, `PI0`, `THRESHOLD` (z where fdr
crosses q), `N_FINAL`, `FLAGS`, …) and `_params.json`.

## Pipeline integration

`analysis.sh::apply_gaussian_mixture_thresholding` dispatches on
`DETECTION_ENGINE` (default `posterior`): the engine runs on the region
z-score image (a linear rescale; it re-standardises robustly), writes the
mask under the legacy output name plus the posterior/lfdr maps next to it, and
the params file with the keys the report and figures read
(`viz_detection_stage_figures` draws the null component and the applied
threshold). `apply_connectivity_weighting` passes the engine mask through
(it is already MRF-regularised). Union across regions, source-family
consensus, provenance, reporting and cross-modal corroboration are unchanged.
If `uv`/python is unavailable or the engine fails for a region, the legacy
chain runs for that region with a WARNING.

## Caveats

- The phantom is simple (Gaussian-ish tissue, spherical lesions); real FLAIR
  has flow artefacts, partial volume and 2D thick slices. Run the ds004199
  controls (false-positive burden) and the challenge datasets before quoting
  numbers.
- Tiny nuclei (tens of voxels) cannot support their own null; they are
  flagged and should be read through their subdivision or a parent null.
- Confluent disease (> ~40 % of a region) breaks any within-region null.

## References

Efron B. *Large-scale inference.* Cambridge UP 2010 (empirical null, local
fdr); Efron B. Size, power and false discovery rates. Ann Stat 2007.
Benjamini Y, Hochberg Y. JRSS-B 1995. Müller P, Parmigiani G, et al.
Optimal sample size for multiple testing: the case of gene expression
microarrays. JASA 2004 (posterior expected FDR). Celeux G, Forbes F,
Peyrard N. EM procedures using mean field-like approximations for Markov
model-based image segmentation. Pattern Recognit 2003. Van Leemput K, et al.
Automated segmentation of multiple sclerosis lesions by model outlier
detection. IEEE TMI 2001. Schmidt P, et al. NeuroImage 2012 (LST-LGA).
Cerri S, et al. A contrast-adaptive method for simultaneous whole-brain and
lesion segmentation in multiple sclerosis. NeuroImage 2021 (SAMSEG).
