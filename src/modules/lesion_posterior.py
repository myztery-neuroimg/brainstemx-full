#!/usr/bin/env python3
"""lesion_posterior.py - principled per-region hyperintensity detection.

Replaces the legacy chain (region-mean z-score -> GMM upper component + k*SD ->
95th-percentile floor -> smoothed re-threshold) with a two-groups
empirical-null model (Efron 2004/2010) on a lesion-uncontaminated robust
reference, FDR-controlled decisions and a mean-field Markov random field.
The engine is region-agnostic: it sees one region mask at a time (brainstem
subdivision, nucleus, tract, whole white matter, custom mask).

Steps (defaults in DEFAULTS):
  1. Gate    R' = R ∩ brain ∩ {p_csf < csf_thr}, minus a 1-voxel partial-volume
             band at the region boundary (only when the region is large enough).
  2. Null    robust location/scale of I on R' (Tukey biweight M-estimator +
             MAD), optional low-order spatial trend fitted by IRLS so a bias
             residue does not masquerade as a lesion; z = (I - mu(x)) / s.
             A parent/reference null can be supplied for tiny regions
             (hierarchical shrinkage) or when the region is mostly abnormal.
  3. Empirical null  N(delta0, sigma0^2) and pi0 from the central quantiles
             of z (Efron's central matching); marginal density f(z) from a
             Lindsey Poisson-spline fit (N >= 3000) or a Gaussian KDE.
             local fdr(z) = min(1, pi0 f0(z)/f(z)), forced non-increasing on
             the right tail; posterior P(lesion|z) = 1 - fdr(z).
  4. Decide  (a) posterior-expected-FDR rule: largest set S ordered by
             posterior with mean(fdr) <= q (adapts to prevalence: a healthy
             region yields S = {}); (b) Benjamini-Hochberg on one-sided
             p-values of the empirical null (tail-area FDR) for comparison.
  5. MRF     mean-field Potts prior (beta, 6-neighbourhood, anisotropic
             weights by voxel size) on the voxel posteriors, then the same
             posterior-FDR rule on the regularised posterior; small clusters
             and clusters with low mean posterior are dropped.
  6. Report  posterior / lfdr / z maps, binary masks, a cluster table and a
             params file with reliability flags (pi0, gated voxel count,
             null source, region-wide shift).

CLI:  lesion_posterior.py --image FLAIR --region MASK --out-prefix P [options]
API:  detect_array(flair, region, extra={"brain":..,"csf":..,"t2":..}, **kw)
Exit: 0 ok (mask may be empty), 1 error. Diagnostics on stderr.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from typing import Dict, Optional, Tuple

import numpy as np
from scipy import ndimage, stats

DEFAULTS = dict(
    q=0.05,                 # FDR level for the primary mask
    csf_thr=0.5,            # gate out voxels with p_csf >= csf_thr
    pv_erode=1,             # boundary PV band (voxels) removed from the null pool (large regions only)
    min_gated=300,          # below this the region's own null is "low confidence" (shrunk to parent if given)
    min_null=30,            # absolute minimum voxels to fit anything
    trend_degree=1,         # 0 | 1 | 2 polynomial spatial trend (only when N >= trend_min_n)
    trend_min_n=3000,
    central_lo=0.05, central_hi=0.75,   # central quantile window for the empirical null
    beta=0.6,               # MRF coupling
    mrf_iters=10,
    min_cluster=3,          # voxels
    cluster_post=0.5,       # drop clusters whose mean posterior is below this
    pi0_floor=0.6,          # pi0 below this => 'high lesion load' flag (null unreliable)
    t2_weight=0.5,          # weight of a co-registered T2 channel (Stouffer combination)
    seed=0,
)


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


# --------------------------------------------------------------------------- #
# robust null
# --------------------------------------------------------------------------- #
def biweight_location(x: np.ndarray, c: float = 6.0, iters: int = 20) -> Tuple[float, float]:
    """Tukey biweight location + MAD-based scale (both lesion-resistant)."""
    m = float(np.median(x))
    mad = float(np.median(np.abs(x - m))) * 1.4826 + 1e-12
    for _ in range(iters):
        u = (x - m) / (c * mad)
        w = (1 - u * u) ** 2
        w[np.abs(u) >= 1] = 0
        if w.sum() <= 0:
            break
        m_new = float(np.sum(w * x) / np.sum(w))
        if abs(m_new - m) < 1e-6 * mad:
            m = m_new
            break
        m = m_new
    mad = float(np.median(np.abs(x - m))) * 1.4826 + 1e-12
    return m, mad


def robust_trend(coords: np.ndarray, y: np.ndarray, degree: int, iters: int = 5):
    """IRLS (biweight) polynomial trend mu(x); returns (predict_fn, frac_downweighted)."""
    cols = [np.ones(len(y))]
    c = (coords - coords.mean(0)) / (coords.std(0) + 1e-9)
    if degree >= 1:
        cols += [c[:, 0], c[:, 1], c[:, 2]]
    if degree >= 2:
        cols += [c[:, 0] ** 2, c[:, 1] ** 2, c[:, 2] ** 2, c[:, 0] * c[:, 1], c[:, 0] * c[:, 2], c[:, 1] * c[:, 2]]
    X = np.column_stack(cols)
    w = np.ones(len(y))
    beta = None
    for _ in range(iters):
        Xw = X * w[:, None]
        beta, *_ = np.linalg.lstsq(Xw.T @ X, Xw.T @ y, rcond=None)
        r = y - X @ beta
        s = np.median(np.abs(r)) * 1.4826 + 1e-9
        u = r / (6.0 * s)
        w = np.where(np.abs(u) < 1, (1 - u * u) ** 2, 0.0)
    mean0, std0 = coords.mean(0), coords.std(0) + 1e-9

    def predict(xyz):
        cc = (xyz - mean0) / std0
        cols2 = [np.ones(len(cc))]
        if degree >= 1:
            cols2 += [cc[:, 0], cc[:, 1], cc[:, 2]]
        if degree >= 2:
            cols2 += [cc[:, 0] ** 2, cc[:, 1] ** 2, cc[:, 2] ** 2, cc[:, 0] * cc[:, 1], cc[:, 0] * cc[:, 2], cc[:, 1] * cc[:, 2]]
        return np.column_stack(cols2) @ beta

    return predict, float((w == 0).mean())


# --------------------------------------------------------------------------- #
# empirical null + local fdr
# --------------------------------------------------------------------------- #
def empirical_null(z: np.ndarray, lo: float, hi: float) -> Tuple[float, float, float]:
    """Efron's central matching: fit log f(z) ~ b0 + b1 z + b2 z^2 on the
    histogram of the central quantile window [q_lo, q_hi] (Poisson-weighted
    least squares). Then sigma0^2 = -1/(2 b2), delta0 = b1 sigma0^2 and
    log pi0 = b0 - log(N dz) + log(sigma0 sqrt(2 pi)) + delta0^2/(2 sigma0^2).
    Falls back to median/MAD with pi0 = 1 when the fit is degenerate."""
    n = z.size
    a, b = np.quantile(z, [lo, hi])
    med = float(np.median(z)); mad = float(np.median(np.abs(z - med))) * 1.4826 + 1e-9
    if n < 200 or b <= a:
        return med, mad, 1.0
    k = int(np.clip(np.sqrt(n) / 2, 15, 60))
    edges = np.linspace(a, b, k + 1)
    counts, _ = np.histogram(z, bins=edges)
    centres = (edges[:-1] + edges[1:]) / 2
    dz = edges[1] - edges[0]
    ok = counts > 0
    if ok.sum() < 6:
        return med, mad, 1.0
    X = np.column_stack([np.ones(ok.sum()), centres[ok], centres[ok] ** 2])
    y = np.log(counts[ok].astype(float))
    w = np.sqrt(counts[ok].astype(float))
    beta, *_ = np.linalg.lstsq(X * w[:, None], y * w, rcond=None)
    b0, b1, b2 = beta
    if b2 >= 0:                       # not concave: fall back
        return med, mad, 1.0
    sigma0 = float(np.sqrt(-1.0 / (2.0 * b2)))
    delta0 = float(b1 * sigma0 * sigma0)
    log_pi0 = b0 - math.log(n * dz) + math.log(sigma0 * math.sqrt(2 * math.pi)) + delta0 * delta0 / (2 * sigma0 * sigma0)
    pi0 = float(min(1.0, math.exp(log_pi0)))
    # guard against absurd fits (e.g. bimodal cores): keep within 3x of MAD scale
    if not (0.33 * mad <= sigma0 <= 3.0 * mad) or abs(delta0 - med) > 3 * mad:
        return med, mad, 1.0
    return delta0, sigma0, max(pi0, 0.05)


def is_bimodal(z: np.ndarray, seed: int = 0, max_n: int = 20000) -> bool:
    """BIC-based bimodality check (sklearn GaussianMixture 1 vs 2 components):
    a region whose intensities split into two well-separated, both-substantial
    modes has no identifiable single null (e.g. >40 % confluent lesion)."""
    try:
        from sklearn.mixture import GaussianMixture
    except Exception:
        return False
    x = z[np.isfinite(z)]
    if x.size < 500:
        return False
    if x.size > max_n:
        x = np.random.default_rng(seed).choice(x, max_n, replace=False)
    X = x.reshape(-1, 1)
    g1 = GaussianMixture(1, random_state=seed).fit(X)
    g2 = GaussianMixture(2, random_state=seed, n_init=2).fit(X)
    if g2.bic(X) >= g1.bic(X) - 10:
        return False
    w = g2.weights_; mu = g2.means_.ravel(); sd = np.sqrt(g2.covariances_.ravel())
    bright = int(np.argmax(mu))
    # a SUBSTANTIAL, well-separated BRIGHT mode (>= 25 % of the region) — a dark
    # partial-volume mode at the region edge is handled by gating, not flagged
    return bool(w[bright] > 0.25 and w.min() > 0.25 and abs(mu[0] - mu[1]) > 3.0 * sd.max())


def marginal_density(z: np.ndarray, grid: np.ndarray) -> np.ndarray:
    """f(z) on grid: Lindsey Poisson-spline for large N, Gaussian KDE otherwise."""
    n = z.size
    if n >= 3000:
        lo, hi = np.quantile(z, [0.001, 0.999])
        k = 120
        edges = np.linspace(lo, hi, k + 1)
        counts, _ = np.histogram(z, bins=edges)
        centres = (edges[:-1] + edges[1:]) / 2
        # natural-cubic-like basis: polynomial in standardised z up to degree 7
        cz = (centres - centres.mean()) / (centres.std() + 1e-9)
        X = np.column_stack([cz ** d for d in range(8)])
        beta = np.zeros(X.shape[1]); beta[0] = math.log(max(counts.mean(), 1e-6))
        for _ in range(50):  # Poisson IRLS
            mu = np.exp(np.clip(X @ beta, -30, 30))
            W = mu
            grad = X.T @ (counts - mu)
            H = (X * W[:, None]).T @ X + 1e-6 * np.eye(X.shape[1])
            step = np.linalg.solve(H, grad)
            beta = beta + step
            if np.abs(step).max() < 1e-6:
                break
        gz = (grid - centres.mean()) / (centres.std() + 1e-9)
        Xg = np.column_stack([gz ** d for d in range(8)])
        dens = np.exp(np.clip(Xg @ beta, -30, 30)) / (n * (edges[1] - edges[0]))
        return np.maximum(dens, 1e-12)
    kde = stats.gaussian_kde(z, bw_method="silverman")
    return np.maximum(kde(grid), 1e-12)


def local_fdr(z: np.ndarray, delta: float, sigma: float, pi0: float):
    """lfdr(z) = min(1, pi0 f0 / f), monotone non-increasing right of delta.
    Returns (lfdr per voxel, grid, lfdr on grid)."""
    grid = np.linspace(min(z.min(), delta - 4 * sigma), max(z.max(), delta + 6 * sigma), 600)
    f = marginal_density(z, grid)
    f0 = stats.norm.pdf(grid, delta, sigma)
    lf = np.minimum(1.0, pi0 * f0 / f)
    right = grid >= delta
    lf[right] = np.minimum.accumulate(lf[right])       # non-increasing on the right tail
    lf[~right] = 1.0                                   # hypo-intense side is never 'lesion' here
    return np.interp(z, grid, lf), grid, lf


def posterior_fdr_mask(post: np.ndarray, q: float) -> np.ndarray:
    """Largest set (ordered by posterior desc) whose mean local fdr <= q."""
    order = np.argsort(-post)
    fdr_sorted = 1.0 - post[order]
    cum = np.cumsum(fdr_sorted) / (np.arange(fdr_sorted.size) + 1)
    ok = cum <= q
    mask = np.zeros(post.size, dtype=bool)
    if ok.any():
        k = int(np.max(np.nonzero(ok)[0])) + 1
        mask[order[:k]] = True
    return mask


def bh_mask(z: np.ndarray, delta: float, sigma: float, q: float) -> np.ndarray:
    p = stats.norm.sf((z - delta) / sigma)
    n = p.size
    order = np.argsort(p)
    thr = q * (np.arange(n) + 1) / n
    ok = p[order] <= thr
    mask = np.zeros(n, dtype=bool)
    if ok.any():
        k = int(np.max(np.nonzero(ok)[0])) + 1
        mask[order[:k]] = True
    return mask


# --------------------------------------------------------------------------- #
# MRF
# --------------------------------------------------------------------------- #
def mean_field_mrf(post_vol: np.ndarray, region: np.ndarray, spacing, beta: float, iters: int) -> np.ndarray:
    """Mean-field Potts smoothing of voxel posteriors inside the region."""
    if beta <= 0 or iters <= 0:
        return post_vol
    eps = 1e-6
    logit0 = np.log(np.clip(post_vol, eps, 1 - eps) / np.clip(1 - post_vol, eps, 1 - eps))
    q = post_vol.copy()
    reg = region.astype(np.float32)
    sp = np.asarray(spacing, dtype=float)
    w = (sp.min() / sp)  # weaker coupling across thick slices
    for _ in range(iters):
        field = np.zeros_like(q)
        for axis in range(3):
            for shift in (1, -1):
                nb = np.roll(q, shift, axis=axis) * np.roll(reg, shift, axis=axis)
                field += w[axis] * (2 * nb - 1) * np.roll(reg, shift, axis=axis)
        q_new = 1.0 / (1.0 + np.exp(-(logit0 + beta * field)))
        q_new[~region] = 0.0
        if np.abs(q_new - q).max() < 1e-4:
            q = q_new
            break
        q = q_new
    return q


# --------------------------------------------------------------------------- #
# engine
# --------------------------------------------------------------------------- #
def detect_array(flair: np.ndarray, region: np.ndarray, extra: Optional[Dict[str, np.ndarray]] = None,
                 spacing=(1.0, 1.0, 1.0), parent_null: Optional[Tuple[float, float]] = None, **kw) -> Dict:
    cfg = dict(DEFAULTS); cfg.update({k: v for k, v in kw.items() if k in DEFAULTS})
    extra = extra or {}
    flair = np.asarray(flair, dtype=np.float32)
    R = np.asarray(region) > 0.5
    flags = []
    # 1. gating
    gate = R & np.isfinite(flair) & (flair != 0)
    if "brain" in extra:
        gate &= np.asarray(extra["brain"]) > 0.5
    if "csf" in extra:
        gate &= np.asarray(extra["csf"], dtype=np.float32) < float(cfg["csf_thr"])
    analysed = gate.copy()
    null_pool = gate.copy()
    if cfg["pv_erode"] > 0 and gate.sum() >= 4 * cfg["min_gated"]:
        er = ndimage.binary_erosion(gate, iterations=int(cfg["pv_erode"]))
        if er.sum() >= cfg["min_gated"]:
            null_pool = er
    n_gated, n_null = int(analysed.sum()), int(null_pool.sum())
    result = {"n_region": int(R.sum()), "n_gated": n_gated, "n_null": n_null, "flags": flags, "engine": "posterior"}
    empty = lambda: {**result, "posterior": np.zeros_like(flair), "lfdr": np.ones_like(flair), "z": np.zeros_like(flair),
                     "mask": np.zeros(flair.shape, bool), "mask_bh": np.zeros(flair.shape, bool), "clusters": [],
                     "null_mean": float("nan"), "null_sd": float("nan"), "delta0": float("nan"), "sigma0": float("nan"), "pi0": 1.0,
                     "threshold_z": float("nan"), "null_source": "none", "n_primary_prefilter": 0, "n_bh": 0, "n_final": 0, "config": cfg}
    if n_gated < cfg["min_null"]:
        flags.append("too_few_voxels")
        return empty()
    # 2. robust null (+ trend)
    idx = np.argwhere(analysed)
    y = flair[analysed].astype(np.float64)
    null_source = "region"
    trend_frac = 0.0
    if n_null >= cfg["trend_min_n"] and cfg["trend_degree"] > 0:
        pool_idx = np.argwhere(null_pool)
        predict, trend_frac = robust_trend(pool_idx.astype(float), flair[null_pool].astype(np.float64), int(cfg["trend_degree"]))
        mu = predict(idx.astype(float))
        resid_pool = flair[null_pool].astype(np.float64) - predict(pool_idx.astype(float))
        loc, scale = biweight_location(resid_pool)
        z_raw = (y - mu - loc) / scale
        null_mean, null_sd = float(loc), float(scale)
        null_source = "region+trend%d" % int(cfg["trend_degree"])
    else:
        loc, scale = biweight_location(flair[null_pool].astype(np.float64))
        null_mean, null_sd = float(loc), float(scale)
        z_raw = (y - loc) / scale
    if n_gated < cfg["min_gated"]:
        flags.append("small_region_low_confidence")
        if parent_null is not None:
            pm, ps = parent_null
            # shrink toward the parent null in proportion to the deficit of voxels
            lam = n_gated / float(cfg["min_gated"])
            null_mean = lam * null_mean + (1 - lam) * pm
            null_sd = lam * null_sd + (1 - lam) * ps
            z_raw = (y - null_mean) / null_sd
            null_source = "shrunk_to_parent(lam=%.2f)" % lam
    # optional T2 channel: Stouffer combination of standardised evidence
    if "t2" in extra and cfg["t2_weight"] > 0:
        t2 = np.asarray(extra["t2"], dtype=np.float32)
        if t2.shape == flair.shape:
            t2v = t2[analysed].astype(np.float64)
            l2, s2 = biweight_location(t2[null_pool].astype(np.float64))
            z2 = (t2v - l2) / s2
            wgt = float(cfg["t2_weight"])
            z_raw = (z_raw + wgt * z2) / math.sqrt(1 + wgt * wgt)
            null_source += "+t2"
    # 3. empirical null + lfdr
    delta0, sigma0, pi0 = empirical_null(z_raw, cfg["central_lo"], cfg["central_hi"])
    if parent_null is not None and abs(null_mean - parent_null[0]) > 2 * max(parent_null[1], 1e-9):
        flags.append("region_wide_shift_vs_parent")
    # High lesion load: either the two-groups fit says so (pi0 low) or a large
    # share of the region sits far in the right tail of its own robust null
    # (bimodal region: central matching falls back to median/MAD, so pi0 alone
    # would miss it).
    frac_outlier = float(np.mean(z_raw > 3.0))
    if pi0 < cfg["pi0_floor"] or frac_outlier > 0.25 or is_bimodal(z_raw, cfg["seed"]):
        flags.append("high_lesion_load_null_unreliable")
    lf, grid, lf_grid = local_fdr(z_raw, delta0, sigma0, pi0)
    post = 1.0 - lf
    # threshold z where lfdr crosses q (for reporting / figures)
    cross = np.nonzero((grid >= delta0) & (lf_grid <= cfg["q"]))[0]
    threshold_z = float(grid[cross[0]]) if cross.size else float("inf")
    # 4. decisions
    prim = posterior_fdr_mask(post, cfg["q"])
    bh = bh_mask(z_raw, delta0, sigma0, cfg["q"])
    # 5. MRF on the posterior volume
    post_vol = np.zeros(flair.shape, dtype=np.float32); post_vol[analysed] = post
    z_vol = np.zeros(flair.shape, dtype=np.float32); z_vol[analysed] = z_raw
    lf_vol = np.ones(flair.shape, dtype=np.float32); lf_vol[analysed] = lf
    post_mrf = mean_field_mrf(post_vol, analysed, spacing, float(cfg["beta"]), int(cfg["mrf_iters"]))
    final = np.zeros(flair.shape, dtype=bool)
    final[analysed] = posterior_fdr_mask(post_mrf[analysed], cfg["q"])
    mask_bh = np.zeros(flair.shape, dtype=bool); mask_bh[analysed] = bh
    # cluster filter
    lab, n = ndimage.label(final, structure=np.ones((3, 3, 3)))
    clusters = []
    keep = np.zeros_like(final)
    for i in range(1, n + 1):
        comp = lab == i
        size = int(comp.sum())
        mp = float(post_mrf[comp].mean()); pz = float(z_vol[comp].max())
        if size >= cfg["min_cluster"] and mp >= cfg["cluster_post"]:
            keep |= comp
            cz = np.argwhere(comp).mean(0)
            clusters.append({"id": len(clusters) + 1, "voxels": size, "mean_posterior": round(mp, 4), "peak_z": round(pz, 3),
                             "centroid_vox": [round(float(c), 1) for c in cz]})
    result.update({
        "posterior": post_mrf.astype(np.float32), "lfdr": lf_vol, "z": z_vol, "mask": keep, "mask_bh": mask_bh, "clusters": clusters,
        "null_mean": null_mean, "null_sd": null_sd, "delta0": float(delta0), "sigma0": float(sigma0), "pi0": float(pi0),
        "threshold_z": threshold_z, "null_source": null_source, "trend_downweighted_frac": trend_frac, "frac_outlier_z3": frac_outlier,
        "n_primary_prefilter": int(prim.sum()), "n_bh": int(bh.sum()), "n_final": int(keep.sum()), "config": cfg,
    })
    return result


def params_text(res: Dict, region_name: str = "") -> str:
    lines = [
        f"ENGINE=posterior", f"REGION={region_name}", f"N_REGION={res['n_region']}", f"N_GATED={res['n_gated']}", f"N_NULL={res['n_null']}",
        f"NULL_MEAN={res['null_mean']:.6f}", f"NULL_SD={res['null_sd']:.6f}", f"DELTA0={res['delta0']:.6f}", f"SIGMA0={res['sigma0']:.6f}",
        f"PI0={res['pi0']:.6f}", f"THRESHOLD={res['threshold_z']:.6f}", f"Q={res.get('config', DEFAULTS)['q']}",
        f"NULL_SOURCE={res['null_source']}", f"N_VOXELS={res['n_gated']}", f"N_FINAL={res.get('n_final', 0)}", f"N_BH={res.get('n_bh', 0)}",
        f"N_CLUSTERS={len(res['clusters'])}", f"FLAGS={','.join(res['flags']) or 'none'}",
    ]
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    import nibabel as nib

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", required=True, help="FLAIR (analysis space)")
    ap.add_argument("--region", required=True, help="binary region mask")
    ap.add_argument("--out-prefix", required=True)
    ap.add_argument("--brain", default=None); ap.add_argument("--csf", default=None, help="CSF probability / exclusion map")
    ap.add_argument("--t2", default=None, help="co-registered T2 (optional second channel)")
    ap.add_argument("--parent-null", default=None, help="'mean,sd' of a parent/reference null for tiny regions")
    ap.add_argument("--region-name", default="")
    for k, v in DEFAULTS.items():
        ap.add_argument(f"--{k.replace('_', '-')}", type=type(v), default=v)
    a = ap.parse_args(argv)
    try:
        img = nib.load(a.image)
        flair = np.asanyarray(img.dataobj).astype(np.float32)
        region = np.asanyarray(nib.load(a.region).dataobj)
        if region.shape != flair.shape:
            raise ValueError(f"region shape {region.shape} != image {flair.shape}")
        extra = {}
        for key, path in (("brain", a.brain), ("csf", a.csf), ("t2", a.t2)):
            if path and os.path.isfile(path):
                arr = np.asanyarray(nib.load(path).dataobj).astype(np.float32)
                if arr.shape == flair.shape:
                    extra[key] = arr
                else:
                    log(f"warning: {key} shape {arr.shape} != image; ignored")
        pn = tuple(float(v) for v in a.parent_null.split(",")) if a.parent_null else None
        kw = {k: getattr(a, k) for k in DEFAULTS}
        res = detect_array(flair, region, extra, spacing=img.header.get_zooms()[:3], parent_null=pn, **kw)
        pre = a.out_prefix
        os.makedirs(os.path.dirname(pre) or ".", exist_ok=True)
        for key, name, dt in (("posterior", "_posterior.nii.gz", np.float32), ("lfdr", "_lfdr.nii.gz", np.float32), ("z", "_z.nii.gz", np.float32),
                              ("mask", "_mask.nii.gz", np.uint8), ("mask_bh", "_mask_bh.nii.gz", np.uint8)):
            nib.save(nib.Nifti1Image(np.asarray(res[key]).astype(dt), img.affine, img.header), pre + name)
        with open(pre + "_params.txt", "w", encoding="utf-8") as fh:
            fh.write(params_text(res, a.region_name))
        with open(pre + "_params.json", "w", encoding="utf-8") as fh:
            json.dump({k: v for k, v in res.items() if k not in ("posterior", "lfdr", "z", "mask", "mask_bh")}, fh, indent=1, default=str)
        with open(pre + "_clusters.tsv", "w", encoding="utf-8") as fh:
            fh.write("id\tvoxels\tmean_posterior\tpeak_z\tcentroid_vox\n")
            for c in res["clusters"]:
                fh.write(f"{c['id']}\t{c['voxels']}\t{c['mean_posterior']}\t{c['peak_z']}\t{','.join(str(v) for v in c['centroid_vox'])}\n")
        print(params_text(res, a.region_name), end="")
        log(f"posterior engine: {res['n_final']} voxels in {len(res['clusters'])} clusters (pi0={res['pi0']:.3f}, flags={res['flags']})")
        return 0
    except Exception as exc:
        log(f"lesion_posterior: {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
