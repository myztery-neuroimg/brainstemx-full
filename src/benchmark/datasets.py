"""Public lesion datasets with ground truth: registry + layout parsers +
fetch helpers. NOTHING is vendored; open datasets are pulled from their public
source at run time, registration-gated ones are referenced with instructions."""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional


@dataclass
class Subject:
    id: str
    flair: str
    t1: Optional[str] = None
    gt: Optional[str] = None          # None => control (no lesions expected)
    masks: Dict[str, str] = field(default_factory=dict)   # brain / wm / brainstem / custom


@dataclass
class Dataset:
    key: str
    name: str
    url: str
    access: str            # open-s3 | open-http | registration | agreement | generated
    modalities: List[str]
    gt: str
    license: str
    citation: str
    layout: Optional[Callable[[str], List[Subject]]] = None
    fetch: Optional[Callable[[str, List[str]], bool]] = None
    reference_key: Optional[str] = None
    notes: str = ""


def _first(pattern: str) -> Optional[str]:
    hits = sorted(glob.glob(pattern))
    return hits[0] if hits else None


def bids_layout(root: str, gt_suffix: str = "_FLAIR_roi.nii.gz") -> List[Subject]:
    """BIDS: <root>/sub-*/anat/sub-*_FLAIR.nii.gz (+ _T1w, + GT roi, + optional
    _desc-<name>_mask.nii.gz masks). Subjects without a GT file are controls."""
    subs: List[Subject] = []
    for d in sorted(glob.glob(os.path.join(root, "sub-*"))):
        sid = os.path.basename(d)
        anat = os.path.join(d, "anat")
        flair = None
        for f in sorted(glob.glob(os.path.join(anat, f"{sid}*_FLAIR.nii.gz"))):
            if not f.endswith(gt_suffix):
                flair = f
                break
        if not flair:
            continue
        t1 = _first(os.path.join(anat, f"{sid}*_T1w.nii.gz"))
        gt = _first(os.path.join(anat, f"{sid}*{gt_suffix}"))
        masks = {}
        for m in glob.glob(os.path.join(anat, f"{sid}*_desc-*_mask.nii.gz")):
            name = os.path.basename(m).split("_desc-")[1].split("_")[0]
            masks[name] = m
        subs.append(Subject(sid, flair, t1, gt, masks))
    return subs


def fetch_ds004199(root: str, subjects: List[str]) -> bool:
    """OpenNeuro ds004199 via anonymous S3 (aws cli) or openneuro-py. Only the
    requested subjects (or the documented smoke set) are pulled."""
    subs = subjects or ["sub-00006", "sub-00001", "sub-00005", "sub-00014", "sub-00048"]
    os.makedirs(root, exist_ok=True)
    if shutil.which("aws"):
        for s in subs:
            cmd = ["aws", "s3", "sync", "--no-sign-request", f"s3://openneuro.org/ds004199/{s}/", os.path.join(root, s)]
            print("+", " ".join(cmd))
            if subprocess.call(cmd) != 0:
                return False
        for f in ("dataset_description.json", "participants.tsv"):
            subprocess.call(["aws", "s3", "cp", "--no-sign-request", f"s3://openneuro.org/ds004199/{f}", root])
        return True
    if shutil.which("openneuro-py") or shutil.which("openneuro"):
        exe = shutil.which("openneuro-py") or shutil.which("openneuro")
        cmd = [exe, "download", "--dataset", "ds004199", "--target-dir", root] + sum([["--include", f"{s}/*"] for s in subs], [])
        print("+", " ".join(cmd))
        return subprocess.call(cmd) == 0
    print("No fetcher available. Install the AWS CLI (anonymous S3: aws s3 sync --no-sign-request "
          "s3://openneuro.org/ds004199/<sub>/ <root>/<sub>) or openneuro-py (uv tool install openneuro-py), "
          "or download from https://openneuro.org/datasets/ds004199 into", root)
    return False


REGISTRY: Dict[str, Dataset] = {
    "phantom": Dataset(
        key="phantom", name="BrainStemX synthetic phantom (generated)", url="scripts/benchmark.py phantom",
        access="generated", modalities=["FLAIR", "T1w"], gt="known inserted lesions (FLAIR_roi)",
        license="n/a (generated)", citation="this repository, src/benchmark/phantom.py", layout=bids_layout,
        notes="controllable ground truth incl. brainstem lesions and lesion-free controls"),
    "ds004199": Dataset(
        key="ds004199", name="OpenNeuro ds004199: presurgical MRI, focal cortical dysplasia + healthy controls",
        url="https://openneuro.org/datasets/ds004199", access="open-s3",
        modalities=["FLAIR", "T1w"], gt="FLAIR lesion ROI (FCD subjects only; 85 controls without lesions)",
        license="CC0", citation="Schuch F, et al. An open presurgery MRI dataset of people with epilepsy and focal cortical dysplasia type II. Sci Data 2023;10:475",
        layout=lambda root: bids_layout(root, "_FLAIR_roi.nii.gz"), fetch=fetch_ds004199, reference_key="ds004199",
        notes="not brainstem-specific; controls give the false-positive burden; see docs/ds004199_validation_dataset.md"),
    "custom": Dataset(
        key="custom", name="Custom BIDS directory (sub-*/anat/*_FLAIR.nii.gz + *_FLAIR_roi.nii.gz GT)", url="local",
        access="local", modalities=["FLAIR", "T1w"], gt="*_FLAIR_roi.nii.gz (configurable via --gt-suffix)",
        license="your data", citation="", layout=bids_layout),
    "wmh2017": Dataset(
        key="wmh2017", name="WMH Segmentation Challenge 2017 (MICCAI)", url="https://wmh.isi.uu.nl/",
        access="agreement", modalities=["FLAIR", "T1w"], gt="manual WMH masks (60 training subjects, 3 sites)",
        license="data-use agreement", citation="Kuijf HJ, et al. Standardized assessment of automatic segmentation of white matter hyperintensities and results of the WMH Segmentation Challenge. IEEE TMI 2019;38(11):2556-2568",
        reference_key="wmh2017", notes="place the unpacked training set under <root>/<site>/<subject>/{pre/FLAIR.nii.gz,wmh.nii.gz}; parser: --dataset custom after converting to BIDS, or extend datasets.py"),
    "isbi2015": Dataset(
        key="isbi2015", name="ISBI 2015 longitudinal MS lesion segmentation challenge", url="https://smart-stats-tools.org/lesion-challenge",
        access="registration", modalities=["FLAIR", "T1w", "T2w", "PD"], gt="two raters' lesion masks",
        license="registration", citation="Carass A, et al. Longitudinal multiple sclerosis lesion segmentation: resource and challenge. NeuroImage 2017;148:77-102",
        reference_key="isbi2015"),
    "msseg2016": Dataset(
        key="msseg2016", name="MICCAI MSSEG 2016 MS lesion segmentation challenge", url="https://portal.fli-iam.irisa.fr/msseg-challenge/",
        access="registration", modalities=["FLAIR", "T1w", "T2w", "PD", "T1c"], gt="consensus of 7 experts",
        license="registration (Shanoir)", citation="Commowick O, et al. Objective evaluation of multiple sclerosis lesion segmentation using a data management and processing infrastructure. Sci Rep 2018;8:13650",
        reference_key="msseg2016"),
    "shifts_ms": Dataset(
        key="shifts_ms", name="Shifts 2.0 MS lesion segmentation (distributional shift benchmark)", url="https://shifts.ai/",
        access="open-http", modalities=["FLAIR", "T1w"], gt="expert lesion masks", license="CC BY-NC-SA 4.0 (check the release)",
        citation="Malinin A, et al. Shifts 2.0: Extending the dataset of real distributional shifts. arXiv 2022 (2206.15407)",
        reference_key="shifts_ms", notes="download from the Shifts project page; convert to BIDS and use --dataset custom"),
}


def describe(key: Optional[str] = None) -> str:
    keys = [key] if key else list(REGISTRY)
    lines = []
    for k in keys:
        d = REGISTRY[k]
        lines.append(f"{d.key:10s} {d.access:12s} {d.name}\n{'':10s} url: {d.url}\n{'':10s} gt: {d.gt}\n{'':10s} licence: {d.license}\n{'':10s} cite: {d.citation}" + (f"\n{'':10s} note: {d.notes}" if d.notes else ""))
    return "\n".join(lines)


def load_subjects(key: str, root: str, subjects: Optional[List[str]] = None, gt_suffix: Optional[str] = None) -> List[Subject]:
    d = REGISTRY[key]
    if d.layout is None:
        raise SystemExit(f"dataset '{key}' has no automated layout parser: {d.notes or 'convert to BIDS and use --dataset custom'}")
    subs = bids_layout(root, gt_suffix) if gt_suffix else d.layout(root)
    if subjects:
        want = set(subjects)
        subs = [s for s in subs if s.id in want]
    return subs


def write_manifest(subs: List[Subject], path: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump([s.__dict__ for s in subs], fh, indent=1)
