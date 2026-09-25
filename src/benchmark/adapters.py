"""Detection adapters: turn a Subject into (probability map or None, binary
mask). Every adapter is region-aware so the same benchmark runs on the
brainstem, the white matter or the whole brain.

  threshold    robust-z baseline (median/MAD inside the region, z > k)
  legacy_gmm   the pipeline's legacy per-region engine (region mean/SD z-score
               + gmm_threshold.py adaptive threshold + 95th-percentile floor)
  posterior    the new principled engine (src/modules/lesion_posterior.py)
  precomputed  read masks produced elsewhere (e.g. a full pipeline run)
"""

from __future__ import annotations

import glob
import importlib.util
import os
import sys
from typing import Dict, Optional, Tuple

import nibabel as nib
import numpy as np

from .datasets import Subject

MODULES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "modules")


def _load_module(name: str, filename: str):
    path = os.path.join(MODULES_DIR, filename)
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def otsu_threshold(values: np.ndarray, bins: int = 256) -> float:
    hist, edges = np.histogram(values, bins=bins)
    hist = hist.astype(float)
    centres = (edges[:-1] + edges[1:]) / 2
    w0 = np.cumsum(hist); w1 = hist.sum() - w0
    m0 = np.cumsum(hist * centres) / np.maximum(w0, 1e-9)
    m1 = (np.cumsum((hist * centres)[::-1])[::-1]) / np.maximum(w1, 1e-9)
    var = w0[:-1] * w1[:-1] * (m0[:-1] - m1[1:]) ** 2
    return float(centres[int(np.argmax(var))])


def region_mask(sub: Subject, region: str, flair: np.ndarray) -> np.ndarray:
    """brain | wm | brainstem | auto | <path or glob>. 'auto' = Otsu on FLAIR
    + hole fill (crude brain mask) when no mask file is available."""
    from scipy import ndimage

    if region in sub.masks:
        return np.asanyarray(nib.load(sub.masks[region]).dataobj) > 0.5
    if region not in ("auto", "brain", "wm", "brainstem"):
        hits = sorted(glob.glob(region.format(subject=sub.id))) if "{" in region or "*" in region else ([region] if os.path.isfile(region) else [])
        if hits:
            return np.asanyarray(nib.load(hits[0]).dataobj) > 0.5
        raise FileNotFoundError(f"region mask not found: {region}")
    if "brain" in sub.masks:
        return np.asanyarray(nib.load(sub.masks["brain"]).dataobj) > 0.5
    finite = flair[np.isfinite(flair) & (flair > 0)]
    t = otsu_threshold(finite) if finite.size else 0.0
    m = flair > t
    lab, n = ndimage.label(m)
    if n > 1:
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        m = lab == (int(np.argmax(sizes)) + 1)
    return ndimage.binary_fill_holes(m)


def adapter_threshold(flair: np.ndarray, region: np.ndarray, params: Dict[str, str]):
    k = float(params.get("k", 3.0))
    v = flair[region]
    med = np.median(v); mad = np.median(np.abs(v - med)) * 1.4826 + 1e-9
    z = np.zeros_like(flair, dtype=np.float32); z[region] = (flair[region] - med) / mad
    mask = (z > k) & region
    return None, mask


def adapter_legacy_gmm(flair: np.ndarray, region: np.ndarray, params: Dict[str, str]):
    """Replicates analysis.sh normalize_flair_brainstem_zscore +
    apply_gaussian_mixture_thresholding (gmm_threshold.py). The bash
    'connectivity weighting' re-threshold is not reproduced (documented)."""
    gmm = _load_module("gmm_threshold", "gmm_threshold.py")
    if gmm is None:
        raise RuntimeError("src/modules/gmm_threshold.py not found")
    from sklearn.mixture import GaussianMixture

    v = flair[region].astype(np.float64)
    mean, sd = v.mean(), v.std()
    if sd <= 0:
        return None, np.zeros_like(region)
    z = (flair - mean) / sd
    zv = z[region]
    cfg = dict(gmm.DEFAULTS)
    for key, val in params.items():
        if key in cfg:
            cfg[key] = type(cfg[key])(val)
    if zv.size < cfg["min_voxels"]:
        thr = cfg["fallback_threshold"]
    else:
        n_comp = min(cfg["max_components"], max(2, zv.size // cfg["voxels_per_component"]))
        try:
            g = GaussianMixture(n_components=n_comp, random_state=42, max_iter=200).fit(zv.reshape(-1, 1))
            thr, *_ = gmm.compute_adaptive_threshold(g.means_.flatten(), np.sqrt(g.covariances_.flatten()), g.weights_, n_comp, cfg)
            thr = max(thr, float(np.percentile(zv, cfg["floor_percentile"])))
        except ValueError:
            thr = float(np.percentile(zv, cfg["fallback_percentile"]))
    return None, (z > thr) & region


def adapter_posterior(flair: np.ndarray, region: np.ndarray, params: Dict[str, str], extra: Optional[Dict[str, np.ndarray]] = None):
    mod = _load_module("lesion_posterior", "lesion_posterior.py")
    if mod is None or not hasattr(mod, "detect_array"):
        raise RuntimeError("posterior engine not available (src/modules/lesion_posterior.py with detect_array)")
    kw = {}
    for key, val in params.items():
        try:
            kw[key] = float(val) if "." in val or val.replace("-", "").isdigit() else val
        except Exception:
            kw[key] = val
    res = mod.detect_array(flair, region, extra=extra or {}, **kw)
    return res["posterior"], res["mask"]


def adapter_precomputed(sub: Subject, params: Dict[str, str], flair_img):
    pat = params.get("pred_pattern")
    if not pat:
        raise RuntimeError("precomputed adapter needs --param pred_pattern=<glob with {subject}>")
    hits = sorted(glob.glob(pat.format(subject=sub.id)))
    if not hits:
        return None, None
    img = nib.load(hits[0])
    mask = np.asanyarray(img.dataobj) > 0.5
    if mask.shape != flair_img.shape[:3]:
        from nibabel.processing import resample_from_to

        mask = np.asanyarray(resample_from_to(img, (flair_img.shape[:3], flair_img.affine), order=0).dataobj) > 0.5
    prob = None
    ppat = params.get("prob_pattern")
    if ppat:
        ph = sorted(glob.glob(ppat.format(subject=sub.id)))
        if ph:
            prob = np.asanyarray(nib.load(ph[0]).dataobj).astype(np.float32)
    return prob, mask


ADAPTERS = ("threshold", "legacy_gmm", "posterior", "precomputed")


def predict(adapter: str, sub: Subject, region: str, params: Dict[str, str]) -> Tuple[Optional[np.ndarray], Optional[np.ndarray], np.ndarray, nib.Nifti1Image]:
    """Returns (prob, mask, region_mask, flair_img). mask None => adapter had no prediction."""
    flair_img = nib.load(sub.flair)
    flair = np.asanyarray(flair_img.dataobj).astype(np.float32)
    reg = region_mask(sub, region, flair)
    if adapter == "precomputed":
        prob, mask = adapter_precomputed(sub, params, flair_img)
        return prob, mask, reg, flair_img
    if adapter == "threshold":
        prob, mask = adapter_threshold(flair, reg, params)
    elif adapter == "legacy_gmm":
        prob, mask = adapter_legacy_gmm(flair, reg, params)
    elif adapter == "posterior":
        extra = {}
        if sub.t1 and os.path.isfile(sub.t1):
            t1 = np.asanyarray(nib.load(sub.t1).dataobj).astype(np.float32)
            if t1.shape == flair.shape:
                extra["t1"] = t1
        prob, mask = adapter_posterior(flair, reg, params, extra)
    else:
        raise SystemExit(f"unknown adapter {adapter}; choose from {ADAPTERS}")
    return prob, mask, reg, flair_img
