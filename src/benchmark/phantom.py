"""Synthetic FLAIR/T1 phantoms with known lesions (controllable ground truth).

The phantom is deliberately simple (ellipsoidal brain, WM core, CSF ventricle,
a 'brainstem' cylinder, smooth multiplicative bias field, Rician noise) but it
exercises everything the benchmark and the detection engine need: a normal
tissue distribution, partial-volume edges, small and large hyperintense
lesions with configurable contrast, control subjects with NO lesions (false
positive behaviour), and a region mask. Deterministic per seed.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

import nibabel as nib
import numpy as np


@dataclass
class PhantomSpec:
    shape: Tuple[int, int, int] = (64, 72, 56)
    voxel_mm: float = 1.0
    n_lesions: int = 4
    lesion_radius_range: Tuple[float, float] = (1.5, 4.5)
    lesion_contrast: float = 0.45          # fractional FLAIR increase over WM
    lesion_t1_contrast: float = -0.12
    noise_sigma: float = 0.04              # relative to WM intensity
    bias_amplitude: float = 0.15           # peak-to-peak multiplicative bias
    brainstem_lesions: int = 1             # of n_lesions, how many go in the brainstem cylinder
    seed: int = 0
    tissue_flair: Dict[str, float] = field(default_factory=lambda: {"csf": 0.15, "gm": 0.85, "wm": 0.70, "bs": 0.72})
    tissue_t1: Dict[str, float] = field(default_factory=lambda: {"csf": 0.15, "gm": 0.55, "wm": 0.95, "bs": 0.90})


def _ellipsoid(shape, centre, radii):
    zz, yy, xx = np.mgrid[0:shape[0], 0:shape[1], 0:shape[2]]
    return (((zz - centre[0]) / radii[0]) ** 2 + ((yy - centre[1]) / radii[1]) ** 2 + ((xx - centre[2]) / radii[2]) ** 2) <= 1.0


def build_labels(spec: PhantomSpec) -> np.ndarray:
    """0 background, 1 CSF, 2 GM, 3 WM, 4 brainstem."""
    s = spec.shape
    c = (s[0] / 2, s[1] / 2, s[2] / 2)
    lab = np.zeros(s, dtype=np.uint8)
    brain = _ellipsoid(s, c, (s[0] * 0.42, s[1] * 0.44, s[2] * 0.42))
    wm = _ellipsoid(s, c, (s[0] * 0.30, s[1] * 0.33, s[2] * 0.30))
    vent = _ellipsoid(s, (c[0], c[1], c[2] + 2), (s[0] * 0.06, s[1] * 0.12, s[2] * 0.05))
    lab[brain] = 2
    lab[wm] = 3
    lab[vent] = 1
    # brainstem: vertical cylinder below the centre, inside the brain envelope
    zz, yy, xx = np.mgrid[0:s[0], 0:s[1], 0:s[2]]
    cyl = (((yy - (c[1] - s[1] * 0.02)) ** 2 + (xx - c[2]) ** 2) <= (s[1] * 0.07) ** 2) & (zz >= c[0] + s[0] * 0.18) & (zz <= c[0] + s[0] * 0.42)
    lab[cyl & (brain | (zz > c[0]))] = 4
    return lab


def bias_field(shape, amplitude: float, rng: np.random.Generator) -> np.ndarray:
    zz, yy, xx = [np.linspace(-1, 1, n) for n in shape]
    Z, Y, X = np.meshgrid(zz, yy, xx, indexing="ij")
    coeffs = rng.uniform(-1, 1, 6)
    f = coeffs[0] * Z + coeffs[1] * Y + coeffs[2] * X + coeffs[3] * Z * Y + coeffs[4] * X * X + coeffs[5] * Y * Z
    f = f / (np.abs(f).max() + 1e-9)
    return 1.0 + amplitude * 0.5 * f


def rician(signal: np.ndarray, sigma: float, rng: np.random.Generator) -> np.ndarray:
    a = signal + rng.normal(0, sigma, signal.shape)
    b = rng.normal(0, sigma, signal.shape)
    return np.sqrt(a * a + b * b)


def place_lesions(lab: np.ndarray, spec: PhantomSpec, rng: np.random.Generator) -> Tuple[np.ndarray, List[dict]]:
    """Spheres inside WM (label 3) and/or the brainstem (label 4). Returns the
    lesion label image (1..n) and a per-lesion record (centre, radius, region)."""
    les = np.zeros(lab.shape, dtype=np.int16)
    records = []
    zz, yy, xx = np.mgrid[0:lab.shape[0], 0:lab.shape[1], 0:lab.shape[2]]
    for i in range(spec.n_lesions):
        target = 4 if i < spec.brainstem_lesions else 3
        cand = np.argwhere(lab == target)
        if cand.size == 0:
            continue
        for _ in range(50):
            c = cand[rng.integers(len(cand))]
            r = float(rng.uniform(*spec.lesion_radius_range))
            sph = ((zz - c[0]) ** 2 + (yy - c[1]) ** 2 + (xx - c[2]) ** 2) <= r * r
            inside = sph & (lab == target)
            if inside.sum() >= 0.8 * sph.sum() and not (les[sph] > 0).any():
                les[inside] = i + 1
                records.append({"id": i + 1, "centre": [int(v) for v in c], "radius_mm": r * spec.voxel_mm,
                                "region": "brainstem" if target == 4 else "wm", "voxels": int(inside.sum())})
                break
    return les, records


def render(spec: PhantomSpec, lesions: bool = True):
    rng = np.random.default_rng(spec.seed)
    lab = build_labels(spec)
    les, records = place_lesions(lab, spec, rng) if lesions else (np.zeros(lab.shape, dtype=np.int16), [])
    flair = np.zeros(lab.shape, dtype=np.float32)
    t1 = np.zeros(lab.shape, dtype=np.float32)
    for code, name in ((1, "csf"), (2, "gm"), (3, "wm"), (4, "bs")):
        flair[lab == code] = spec.tissue_flair[name]
        t1[lab == code] = spec.tissue_t1[name]
    # lesions: hyper on FLAIR, hypo on T1, with a soft edge (partial volume)
    if les.any():
        from scipy.ndimage import gaussian_filter

        soft = gaussian_filter((les > 0).astype(np.float32), 0.7)
        soft = np.clip(soft / max(soft.max(), 1e-6), 0, 1)
        flair = flair * (1.0 + spec.lesion_contrast * soft)
        t1 = t1 * (1.0 + spec.lesion_t1_contrast * soft)
    bf = bias_field(lab.shape, spec.bias_amplitude, rng)
    flair = rician(flair * bf, spec.noise_sigma * spec.tissue_flair["wm"], rng)
    t1 = rician(t1 * bias_field(lab.shape, spec.bias_amplitude, rng), spec.noise_sigma * spec.tissue_t1["wm"], rng)
    return {
        "labels": lab, "lesions": les, "flair": flair.astype(np.float32), "t1": t1.astype(np.float32),
        "brain": (lab > 0).astype(np.uint8), "wm": (lab == 3).astype(np.uint8), "brainstem": (lab == 4).astype(np.uint8),
        "gt": (les > 0).astype(np.uint8), "records": records,
    }


def write_subject(root: str, sub: str, spec: PhantomSpec, lesions: bool = True) -> Dict[str, str]:
    """Write a BIDS-like subject: anat/<sub>_{T1w,FLAIR}.nii.gz, <sub>_FLAIR_roi.nii.gz
    (only for lesion subjects), plus derived masks and a JSON record."""
    vols = render(spec, lesions)
    aff = np.diag([spec.voxel_mm, spec.voxel_mm, spec.voxel_mm, 1.0])
    anat = os.path.join(root, sub, "anat")
    os.makedirs(anat, exist_ok=True)
    paths = {}
    for key, name in (("t1", f"{sub}_T1w.nii.gz"), ("flair", f"{sub}_FLAIR.nii.gz"), ("brain", f"{sub}_desc-brain_mask.nii.gz"),
                      ("wm", f"{sub}_desc-wm_mask.nii.gz"), ("brainstem", f"{sub}_desc-brainstem_mask.nii.gz"), ("labels", f"{sub}_dseg.nii.gz")):
        p = os.path.join(anat, name)
        nib.save(nib.Nifti1Image(vols[key], aff), p)
        paths[key] = p
    if lesions:
        p = os.path.join(anat, f"{sub}_FLAIR_roi.nii.gz")
        nib.save(nib.Nifti1Image(vols["gt"], aff), p)
        paths["gt"] = p
    with open(os.path.join(anat, f"{sub}_phantom.json"), "w", encoding="utf-8") as fh:
        json.dump({"spec": spec.__dict__, "lesions": vols["records"], "control": not lesions}, fh, indent=1, default=str)
    return paths


def write_dataset(root: str, n_lesion: int = 4, n_control: int = 2, seed: int = 0, **spec_kw) -> List[str]:
    subs = []
    for i in range(n_lesion + n_control):
        sub = f"sub-{i + 1:03d}"
        spec = PhantomSpec(seed=seed + i, **spec_kw)
        write_subject(root, sub, spec, lesions=i < n_lesion)
        subs.append(sub)
    with open(os.path.join(root, "dataset_description.json"), "w", encoding="utf-8") as fh:
        json.dump({"Name": "BrainStemX synthetic phantom", "BIDSVersion": "1.9.0", "GeneratedBy": [{"Name": "benchmark.phantom"}]}, fh, indent=1)
    return subs
