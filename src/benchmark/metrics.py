"""Lesion-detection metrics (voxel-wise, lesion-wise, volumetric, surface,
calibration) following the conventions of the WMH Segmentation Challenge
(Kuijf 2019) and the MS lesion challenges (ISBI 2015, MSSEG 2016)."""

from __future__ import annotations

from typing import Dict, Optional

import numpy as np
from scipy import ndimage

CONN26 = np.ones((3, 3, 3), dtype=bool)


def _bin(a) -> np.ndarray:
    return np.asarray(a) > 0.5


def dice(pred, gt) -> float:
    p, g = _bin(pred), _bin(gt)
    s = p.sum() + g.sum()
    return 1.0 if s == 0 else float(2.0 * np.logical_and(p, g).sum() / s)


def jaccard(pred, gt) -> float:
    p, g = _bin(pred), _bin(gt)
    u = np.logical_or(p, g).sum()
    return 1.0 if u == 0 else float(np.logical_and(p, g).sum() / u)


def voxel_rates(pred, gt) -> Dict[str, float]:
    p, g = _bin(pred), _bin(gt)
    tp = float(np.logical_and(p, g).sum()); fp = float(np.logical_and(p, ~g).sum())
    fn = float(np.logical_and(~p, g).sum()); tn = float(np.logical_and(~p, ~g).sum())
    return {
        "sensitivity": tp / (tp + fn) if tp + fn else float("nan"),
        "precision": tp / (tp + fp) if tp + fp else float("nan"),
        "specificity": tn / (tn + fp) if tn + fp else float("nan"),
        "tp_voxels": tp, "fp_voxels": fp, "fn_voxels": fn,
    }


def lesion_wise(pred, gt, min_overlap_frac: float = 0.0) -> Dict[str, float]:
    """Connected-component (26-conn) lesion counting. A GT lesion counts as
    detected when the prediction overlaps it by > min_overlap_frac of its
    volume (0 = any voxel, the WMH-challenge convention); a predicted
    component with no GT overlap is a false-positive lesion."""
    p, g = _bin(pred), _bin(gt)
    gl, ng = ndimage.label(g, structure=CONN26)
    pl, npred = ndimage.label(p, structure=CONN26)
    detected = 0
    for i in range(1, ng + 1):
        comp = gl == i
        ov = np.logical_and(comp, p).sum()
        if ov > min_overlap_frac * comp.sum() and ov > 0:
            detected += 1
    fp_lesions = 0
    for j in range(1, npred + 1):
        comp = pl == j
        if not np.logical_and(comp, g).any():
            fp_lesions += 1
    tpr = detected / ng if ng else float("nan")
    ppv = (npred - fp_lesions) / npred if npred else float("nan")
    if ng and npred:
        f1 = (2 * tpr * ppv / (tpr + ppv)) if (tpr + ppv) > 0 else 0.0
    elif ng:                      # lesions exist, nothing predicted
        f1 = 0.0
    else:                         # no lesions: perfect only if nothing predicted
        f1 = 1.0 if npred == 0 else 0.0
    return {"gt_lesions": float(ng), "pred_lesions": float(npred), "detected_lesions": float(detected),
            "fp_lesions": float(fp_lesions), "lesion_tpr": tpr, "lesion_ppv": ppv, "lesion_f1": f1}


def volumes(pred, gt, voxel_mm3: float) -> Dict[str, float]:
    p, g = _bin(pred), _bin(gt)
    vp, vg = float(p.sum() * voxel_mm3), float(g.sum() * voxel_mm3)
    avd = abs(vp - vg) / vg * 100.0 if vg > 0 else float("nan")
    return {"pred_volume_mm3": vp, "gt_volume_mm3": vg, "avd_percent": avd}


def hausdorff95(pred, gt, spacing) -> float:
    """95th-percentile symmetric surface distance (mm); nan when either is empty."""
    p, g = _bin(pred), _bin(gt)
    if not p.any() or not g.any():
        return float("nan")

    def surface(m):
        er = ndimage.binary_erosion(m, structure=ndimage.generate_binary_structure(3, 1))
        return np.logical_and(m, ~er)

    sp, sg = surface(p), surface(g)
    dg = ndimage.distance_transform_edt(~sg, sampling=spacing)
    dp = ndimage.distance_transform_edt(~sp, sampling=spacing)
    d1 = dg[sp]; d2 = dp[sg]
    if d1.size == 0 or d2.size == 0:
        return float("nan")
    return float(max(np.percentile(d1, 95), np.percentile(d2, 95)))


def calibration(prob, gt, mask=None, n_bins: int = 10) -> Dict[str, float]:
    """Brier score + expected calibration error of a probability map."""
    pr = np.asarray(prob, dtype=np.float64)
    g = _bin(gt).astype(np.float64)
    sel = np.isfinite(pr) if mask is None else (np.isfinite(pr) & _bin(mask))
    pr, g = pr[sel], g[sel]
    if pr.size == 0:
        return {"brier": float("nan"), "ece": float("nan")}
    brier = float(np.mean((pr - g) ** 2))
    edges = np.linspace(0, 1, n_bins + 1)
    ece = 0.0
    for a, b in zip(edges[:-1], edges[1:]):
        m = (pr >= a) & (pr < b) if b < 1 else (pr >= a) & (pr <= b)
        if m.any():
            ece += m.mean() * abs(pr[m].mean() - g[m].mean())
    return {"brier": brier, "ece": float(ece)}


def evaluate(pred, gt: Optional[np.ndarray], spacing, prob=None, eval_mask=None) -> Dict[str, float]:
    """All metrics for one subject. With gt=None (control subject) only the
    false-positive burden is reported."""
    voxel_mm3 = float(np.prod(spacing))
    p = _bin(pred)
    if eval_mask is not None:
        p = p & _bin(eval_mask)
    out: Dict[str, float] = {}
    if gt is None:
        pl, npred = ndimage.label(p, structure=CONN26)
        out.update({"control": 1.0, "fp_volume_mm3": float(p.sum() * voxel_mm3), "fp_lesions": float(npred)})
        return out
    g = _bin(gt)
    if eval_mask is not None:
        g = g & _bin(eval_mask)
    out["control"] = 0.0
    out["dice"] = dice(p, g)
    out["jaccard"] = jaccard(p, g)
    out.update(voxel_rates(p, g))
    out.update(lesion_wise(p, g))
    out.update(volumes(p, g, voxel_mm3))
    out["hd95_mm"] = hausdorff95(p, g, spacing)
    if prob is not None:
        out.update(calibration(prob, g, eval_mask))
    return out


def aggregate(rows, keys=None, n_boot: int = 1000, seed: int = 0) -> Dict[str, Dict[str, float]]:
    """Mean / median / bootstrap 95% CI per metric across subjects (nan-aware)."""
    rng = np.random.default_rng(seed)
    if not rows:
        return {}
    keys = keys or sorted({k for r in rows for k in r if isinstance(r[k], (int, float))})
    agg = {}
    for k in keys:
        v = np.array([r[k] for r in rows if k in r and np.isfinite(r[k])], dtype=float)
        if v.size == 0:
            continue
        boots = np.array([rng.choice(v, v.size, replace=True).mean() for _ in range(n_boot)]) if v.size > 1 else v
        agg[k] = {"n": int(v.size), "mean": float(v.mean()), "median": float(np.median(v)),
                  "ci95_lo": float(np.percentile(boots, 2.5)), "ci95_hi": float(np.percentile(boots, 97.5))}
    return agg


def paired_compare(rows_a, rows_b, key: str, n_boot: int = 2000, seed: int = 0) -> Dict[str, float]:
    """Paired A/B statistics for one metric over matched subjects: mean
    difference (B - A) with bootstrap CI, Wilcoxon signed-rank p (n>=5),
    and the fraction of subjects where B improves."""
    a = {r["subject"]: r[key] for r in rows_a if key in r and np.isfinite(r[key])}
    b = {r["subject"]: r[key] for r in rows_b if key in r and np.isfinite(r[key])}
    common = sorted(set(a) & set(b))
    if not common:
        return {"n": 0}
    d = np.array([b[s] - a[s] for s in common], dtype=float)
    rng = np.random.default_rng(seed)
    boots = np.array([rng.choice(d, d.size, replace=True).mean() for _ in range(n_boot)]) if d.size > 1 else d
    out = {"n": int(d.size), "mean_diff": float(d.mean()), "ci95_lo": float(np.percentile(boots, 2.5)),
           "ci95_hi": float(np.percentile(boots, 97.5)), "frac_b_better": float((d > 0).mean())}
    if d.size >= 5 and np.any(d != 0):
        try:
            from scipy.stats import wilcoxon

            out["wilcoxon_p"] = float(wilcoxon(d).pvalue)
        except Exception:
            out["wilcoxon_p"] = float("nan")
    return out
