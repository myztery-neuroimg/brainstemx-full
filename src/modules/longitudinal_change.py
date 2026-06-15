#!/usr/bin/env python3
"""longitudinal_change.py - Longitudinal change analysis for BrainStemX-Full.

Unit E of the longitudinal multi-session feature (see docs/longitudinal_multisession_spec.md §5).

Reads the orchestrator manifest written by src/longitudinal.sh (Unit D), discovers
per-session lesion masks and a common-space region atlas from the anchor session,
computes per-region × per-session lesion volumes and deltas, cross-timepoint lesion
dynamics (new / resolved / growing / shrinking connected components), and emits
change reports under <reports_dir>/.

Design constraints (match the reporting layer conventions):
  - STDLIB + numpy + nibabel ONLY — no pandas.
  - All mask grids are normalised to the anchor/common grid via nearest-neighbour
    resampling (label-preserving) before any comparison.
  - Graceful at every step: missing sessions, missing masks, and missing atlases
    all degrade to a minimal "insufficient data" report rather than crashing.
  - Subject data (paths, labels, identifiers) is runtime-only and never hard-coded.

CLI::

    uv run python src/modules/longitudinal_change.py \\
        --manifest <path/to/longitudinal_manifest.json> \\
        --output   <reports_dir>

Outputs (under --output):
    longitudinal_change.csv       region × session volume table (comma-separated)
    longitudinal_change.tsv       same, tab-separated
    longitudinal_change.json      structured summary (volumes, deltas, dynamics)
    longitudinal_change.html      HTML dashboard with table + dynamics summary
"""

from __future__ import annotations

import argparse
import csv
import glob
import html
import json
import logging
import os
import sys
import warnings
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

try:
    import nibabel as nib
except ImportError:  # pragma: no cover
    print("ERROR: nibabel is required. Install via: uv sync", file=sys.stderr)
    sys.exit(1)

# --------------------------------------------------------------------------- #
# Logging setup
# --------------------------------------------------------------------------- #

logging.basicConfig(
    format="[%(levelname)s] %(name)s: %(message)s",
    level=logging.INFO,
    stream=sys.stderr,
)
_log = logging.getLogger("longitudinal_change")

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

# Connected-component overlap tolerance: components whose volume delta is
# below this fraction of the baseline volume are classified as STABLE.
_STABLE_FRACTION = 0.10   # 10 %
_WHOLE_BRAINSTEM_LABEL = 1  # synthetic label used when no atlas is found
_BACKGROUND_VALUE = 0

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #


def _glob_first(pattern: str) -> Optional[str]:
    """Return the first file matching *pattern* (sorted), or None."""
    matches = sorted(glob.glob(pattern))
    return matches[0] if matches else None


def _discover_lesion_mask(results_dir: str) -> Optional[str]:
    """Discover the primary lesion/cluster mask under a session results dir.

    Search order (most-specific first):
      1. analysis/clusters.nii.gz
      2. analysis/*clusters*.nii.gz
      3. analysis/*hyperintensit*.nii.gz
      4. *clusters*.nii.gz anywhere under results_dir (depth 2)
    """
    # 1. canonical exact path
    exact = os.path.join(results_dir, "analysis", "clusters.nii.gz")
    if os.path.isfile(exact):
        _log.debug("Lesion mask (exact): %s", exact)
        return exact

    # 2-3. named patterns under analysis/
    analysis_dir = os.path.join(results_dir, "analysis")
    for pattern in ("*clusters*.nii.gz", "*hyperintensit*.nii.gz"):
        found = _glob_first(os.path.join(analysis_dir, pattern))
        if found:
            _log.debug("Lesion mask (%s): %s", pattern, found)
            return found

    # 4. broader search (max depth 2 to avoid descending into huge dirs)
    for pattern in ("*clusters*.nii.gz", "*hyperintensit*.nii.gz"):
        for candidate in sorted(glob.glob(os.path.join(results_dir, "*", pattern))):
            _log.debug("Lesion mask (depth-2, %s): %s", pattern, candidate)
            return candidate

    return None


def _discover_atlas(anchor_results_dir: str) -> Optional[str]:
    """Discover a labeled region atlas under the anchor session's results dir.

    Search priority:
      1. segmentation/brainstem/ *labeled*.nii.gz   (HO/FS labeled volume)
      2. segmentation/detailed_brainstem/ *labels*.nii.gz
      3. segmentation/ *brainstem*label*.nii.gz
      4. segmentation/ *brainstem*.nii.gz  (grab any; treat as binary single-region)
    """
    seg_dir = os.path.join(anchor_results_dir, "segmentation")
    bs_dir = os.path.join(seg_dir, "brainstem")
    detailed_dir = os.path.join(seg_dir, "detailed_brainstem")

    for pattern in ("*labeled*.nii.gz", "*labels*.nii.gz"):
        for d in (bs_dir, detailed_dir):
            found = _glob_first(os.path.join(d, pattern))
            if found:
                return found

    for pattern in ("*brainstem*label*.nii.gz", "*brainstem*.nii.gz"):
        found = _glob_first(os.path.join(seg_dir, pattern))
        if found:
            return found

    return None


# --------------------------------------------------------------------------- #
# NIfTI loading + grid conformity
# --------------------------------------------------------------------------- #


def _load_nifti(path: str) -> Tuple[np.ndarray, np.ndarray]:
    """Load a NIfTI volume; return (data_int32, affine)."""
    img = nib.load(path)
    data = np.asanyarray(img.dataobj).squeeze()
    return data.astype(np.int32), np.array(img.affine)


def _grids_match(affine_a: np.ndarray, shape_a: tuple,
                 affine_b: np.ndarray, shape_b: tuple,
                 tol: float = 1e-4) -> bool:
    return (shape_a == shape_b and
            np.allclose(affine_a, affine_b, atol=tol))


def _resample_nearest(
    data: np.ndarray,
    src_affine: np.ndarray,
    ref_affine: np.ndarray,
    ref_shape: tuple,
) -> np.ndarray:
    """Resample *data* onto a reference grid using nearest-neighbour.

    Works purely with numpy (no scipy / ANTs).  Only a rigid/affine transform
    between grids is expected (same subject, same space); for large deformations
    this is NOT appropriate, but cross-session grids that differ only in
    sub-voxel origin/rounding are handled correctly.
    """
    ref_shape_3d = ref_shape[:3]
    # Build voxel indices for every voxel in the reference grid
    i, j, k = np.meshgrid(
        np.arange(ref_shape_3d[0]),
        np.arange(ref_shape_3d[1]),
        np.arange(ref_shape_3d[2]),
        indexing="ij",
    )
    ones = np.ones_like(i)
    ref_vox = np.stack([i.ravel(), j.ravel(), k.ravel(), ones.ravel()], axis=0)  # 4 × N

    # Map reference voxels → world coordinates → source voxels
    src_inv = np.linalg.inv(src_affine)
    vox_in_src = src_inv @ (ref_affine @ ref_vox)  # 4 × N

    src_i = np.round(vox_in_src[0]).astype(np.int64)
    src_j = np.round(vox_in_src[1]).astype(np.int64)
    src_k = np.round(vox_in_src[2]).astype(np.int64)

    # Clamp to valid source bounds
    sx, sy, sz = data.shape[:3]
    np.clip(src_i, 0, sx - 1, out=src_i)
    np.clip(src_j, 0, sy - 1, out=src_j)
    np.clip(src_k, 0, sz - 1, out=src_k)

    out = data[src_i, src_j, src_k].reshape(ref_shape_3d)
    return out.astype(np.int32)


def _ensure_common_grid(
    data: np.ndarray,
    src_affine: np.ndarray,
    ref_affine: np.ndarray,
    ref_shape: tuple,
    label: str,
) -> np.ndarray:
    """Return *data* resampled to the reference grid if grids differ."""
    if _grids_match(src_affine, data.shape, ref_affine, ref_shape):
        return data
    _log.warning(
        "Session '%s': mask grid differs from common grid — resampling "
        "(nearest-neighbour, label-preserving).  Shape %s → %s.",
        label, data.shape, ref_shape,
    )
    return _resample_nearest(data, src_affine, ref_affine, ref_shape)


# --------------------------------------------------------------------------- #
# Voxel volume computation
# --------------------------------------------------------------------------- #


def _voxel_volume_mm3(affine: np.ndarray) -> float:
    """Volume of one voxel in mm³ from the NIfTI affine."""
    vox_sizes = np.sqrt(np.sum(affine[:3, :3] ** 2, axis=0))
    return float(np.prod(vox_sizes))


# --------------------------------------------------------------------------- #
# Per-region volume computation
# --------------------------------------------------------------------------- #


def _region_volumes(
    lesion_mask: np.ndarray,
    atlas: np.ndarray,
    vox_vol: float,
) -> Dict[int, float]:
    """Compute lesion volume (mm³) per atlas label.

    Parameters
    ----------
    lesion_mask : int32 array — non-zero = lesion
    atlas       : int32 array — integer region labels (0 = background)
    vox_vol     : mm³ per voxel

    Returns
    -------
    {label_int: volume_mm3}  — only labels with >0 lesion voxels
    """
    lesion_bin = (lesion_mask != _BACKGROUND_VALUE)
    volumes: Dict[int, float] = {}
    for label in np.unique(atlas):
        if label == _BACKGROUND_VALUE:
            continue
        region_mask = atlas == label
        n_vox = int(np.sum(lesion_bin & region_mask))
        if n_vox > 0:
            volumes[int(label)] = n_vox * vox_vol
    return volumes


# --------------------------------------------------------------------------- #
# Connected-component dynamics
# --------------------------------------------------------------------------- #


def _label_components(binary: np.ndarray) -> np.ndarray:
    """Minimal 26-connectivity connected-component labeling (pure numpy).

    Returns an integer array where each connected component has a unique
    positive label.  Background voxels are 0.

    This is a simplified flood-fill using iterative dilation — correct for
    small brainstem lesion masks (typically < few hundred components).
    """
    labeled = np.zeros_like(binary, dtype=np.int32)
    current_label = 0
    coords = list(zip(*np.where(binary)))
    if not coords:
        return labeled

    # Build set for O(1) membership lookup
    remaining = set(coords)
    shape = binary.shape

    def _neighbors(pos):
        x, y, z = pos
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    if dx == 0 and dy == 0 and dz == 0:
                        continue
                    nx, ny, nz = x + dx, y + dy, z + dz
                    if 0 <= nx < shape[0] and 0 <= ny < shape[1] and 0 <= nz < shape[2]:
                        yield (nx, ny, nz)

    while remaining:
        seed = next(iter(remaining))
        current_label += 1
        queue = [seed]
        component = []
        remaining.discard(seed)
        while queue:
            cur = queue.pop()
            component.append(cur)
            for nb in _neighbors(cur):
                if nb in remaining:
                    remaining.discard(nb)
                    queue.append(nb)
        for vox in component:
            labeled[vox] = current_label

    return labeled


def _compute_dynamics(
    baseline_mask: np.ndarray,
    followup_mask: np.ndarray,
    vox_vol: float,
) -> Dict[str, int | float]:
    """Compare connected components between baseline and follow-up masks.

    Returns a dict with counts of:
      - new       : components in follow-up with no overlap with baseline
      - resolved  : components in baseline with no overlap in follow-up
      - growing   : overlapping components whose volume grew > _STABLE_FRACTION
      - shrinking : overlapping components whose volume shrank > _STABLE_FRACTION
      - stable    : overlapping components with < _STABLE_FRACTION volume change
    """
    bl_bin = (baseline_mask != _BACKGROUND_VALUE)
    fu_bin = (followup_mask != _BACKGROUND_VALUE)

    bl_labeled = _label_components(bl_bin)
    fu_labeled = _label_components(fu_bin)

    bl_labels = set(np.unique(bl_labeled)) - {0}
    fu_labels = set(np.unique(fu_labeled)) - {0}

    resolved_count = 0
    growing_count = 0
    shrinking_count = 0
    stable_count = 0

    # For each baseline component check overlap with follow-up
    for bl_lbl in bl_labels:
        bl_region = (bl_labeled == bl_lbl)
        fu_overlap = fu_bin & bl_region
        if not np.any(fu_overlap):
            resolved_count += 1
        else:
            # Find which follow-up component(s) overlap; pick largest
            bl_vol = int(np.sum(bl_region)) * vox_vol
            # Approximate follow-up volume as the union of all overlapping fu components
            fu_touching_labels = set(np.unique(fu_labeled[fu_overlap])) - {0}
            fu_region = np.isin(fu_labeled, list(fu_touching_labels))
            fu_vol = int(np.sum(fu_region)) * vox_vol
            delta_frac = (fu_vol - bl_vol) / max(bl_vol, 1.0)
            if abs(delta_frac) < _STABLE_FRACTION:
                stable_count += 1
            elif delta_frac > 0:
                growing_count += 1
            else:
                shrinking_count += 1

    # New components: follow-up components with no overlap with any baseline voxel
    new_count = 0
    for fu_lbl in fu_labels:
        fu_region = (fu_labeled == fu_lbl)
        if not np.any(bl_bin & fu_region):
            new_count += 1

    return {
        "new": new_count,
        "resolved": resolved_count,
        "growing": growing_count,
        "shrinking": shrinking_count,
        "stable": stable_count,
    }


# --------------------------------------------------------------------------- #
# Report writers
# --------------------------------------------------------------------------- #

_CSS = """
body { font-family: Arial, Helvetica, sans-serif; line-height: 1.5; margin: 0;
       padding: 24px; color: #222; }
h1 { color: #1a3c5e; border-bottom: 3px solid #2980b9; padding-bottom: 8px; }
h2 { color: #2471a3; margin-top: 36px; }
table { border-collapse: collapse; margin: 12px 0 28px; width: auto; }
th, td { border: 1px solid #ccc; padding: 6px 12px; text-align: left;
         font-size: 14px; }
th { background: #eef4fa; }
tr:nth-child(even) td { background: #f7f9fb; }
.absent { color: #888; font-style: italic; }
.meta { color: #555; font-size: 13px; }
.dynamics-table td { min-width: 80px; }
"""


def _fmt_vol(vol: Optional[float]) -> str:
    if vol is None:
        return ""
    return f"{vol:.1f}"


def _fmt_delta(delta: Optional[float]) -> str:
    if delta is None:
        return ""
    sign = "+" if delta >= 0 else ""
    return f"{sign}{delta:.1f}"


def _write_csv(
    path: str,
    region_names: Dict[int, str],
    session_labels: List[str],
    volumes: Dict[str, Dict[int, float]],  # session_label -> {label: vol_mm3}
    deltas: Dict[str, Dict[int, float]],   # session_label -> {label: delta_mm3}
    delimiter: str = ",",
) -> None:
    """Write the region × session volume table."""
    all_labels = sorted(region_names.keys())
    header = ["region_label", "region_name"]
    for sl in session_labels:
        header += [f"{sl}_volume_mm3", f"{sl}_delta_mm3"]

    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh, delimiter=delimiter)
        writer.writerow(header)
        for lbl in all_labels:
            row: List[str] = [str(lbl), region_names.get(lbl, f"region_{lbl}")]
            for sl in session_labels:
                vol = volumes.get(sl, {}).get(lbl)
                dlt = deltas.get(sl, {}).get(lbl)
                row.append(_fmt_vol(vol))
                row.append(_fmt_delta(dlt))
            writer.writerow(row)


def _write_html(
    path: str,
    anchor_label: str,
    session_labels: List[str],
    region_names: Dict[int, str],
    volumes: Dict[str, Dict[int, float]],
    deltas: Dict[str, Dict[int, float]],
    dynamics: Dict[str, Dict[str, int]],  # session_label -> dynamics dict
    insufficient: bool = False,
    note: str = "",
) -> None:
    """Write the longitudinal change HTML report."""
    all_labels = sorted(region_names.keys())

    parts: List[str] = [
        "<!DOCTYPE html>",
        "<html lang='en'><head><meta charset='UTF-8'>",
        "<meta name='viewport' content='width=device-width, initial-scale=1.0'>",
        "<title>BrainStemX longitudinal change report</title>",
        f"<style>{_CSS}</style></head><body>",
        "<h1>BrainStemX-Full — Longitudinal Change Report</h1>",
        f"<p class='meta'>Common-space anchor session: <b>{html.escape(anchor_label)}</b></p>",
    ]

    if note:
        parts.append(f"<p class='absent'>{html.escape(note)}</p>")

    if insufficient:
        parts.append(
            "<p class='absent'>Insufficient successful sessions (&lt;2) for "
            "longitudinal change analysis.</p>"
        )
        parts += ["</body></html>"]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(parts) + "\n")
        return

    # --- Volume table ---
    parts.append("<h2 id='volume-table'>Per-region lesion volumes and deltas</h2>")
    header_cells = (
        "<th>Region label</th><th>Region name</th>"
        + "".join(
            f"<th>{html.escape(sl)}<br>vol (mm³)</th>"
            f"<th>{html.escape(sl)}<br>delta (mm³)</th>"
            for sl in session_labels
        )
    )
    parts += [
        "<table>",
        f"<thead><tr>{header_cells}</tr></thead>",
        "<tbody>",
    ]
    if not all_labels:
        parts.append(
            "<tr><td colspan='100' class='absent'>No lesion voxels detected "
            "in any session or region.</td></tr>"
        )
    for lbl in all_labels:
        cells = (
            f"<td>{lbl}</td>"
            f"<td>{html.escape(region_names.get(lbl, f'region_{lbl}'))}</td>"
        )
        for sl in session_labels:
            vol = volumes.get(sl, {}).get(lbl)
            dlt = deltas.get(sl, {}).get(lbl)
            cells += f"<td>{html.escape(_fmt_vol(vol))}</td>"
            cells += f"<td>{html.escape(_fmt_delta(dlt))}</td>"
        parts.append(f"<tr>{cells}</tr>")
    parts += ["</tbody></table>"]

    # --- Dynamics table ---
    parts.append("<h2 id='dynamics'>Cross-timepoint lesion dynamics</h2>")
    dyn_keys = ["new", "resolved", "growing", "shrinking", "stable"]
    dyn_header = "<th>Session (vs anchor)</th>" + "".join(
        f"<th>{html.escape(k.capitalize())}</th>" for k in dyn_keys
    )
    parts += [
        "<table class='dynamics-table'>",
        f"<thead><tr>{dyn_header}</tr></thead>",
        "<tbody>",
    ]
    # Only timepoints (non-anchor) have dynamics
    for sl in session_labels:
        if sl == anchor_label:
            continue
        dyn = dynamics.get(sl, {})
        if not dyn:
            parts.append(
                f"<tr><td>{html.escape(sl)}</td>"
                "<td colspan='5' class='absent'>No dynamics data</td></tr>"
            )
            continue
        cells = f"<td>{html.escape(sl)}</td>" + "".join(
            f"<td>{dyn.get(k, 0)}</td>" for k in dyn_keys
        )
        parts.append(f"<tr>{cells}</tr>")
    parts += ["</tbody></table>"]

    parts += ["</body></html>"]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts) + "\n")


# --------------------------------------------------------------------------- #
# Main analysis routine
# --------------------------------------------------------------------------- #


def run_analysis(manifest_path: str, output_dir: str) -> int:
    """Read manifest, compute change metrics, emit reports.

    Returns 0 on success, 1 on hard failure.
    """
    os.makedirs(output_dir, exist_ok=True)

    # ── Load manifest ─────────────────────────────────────────────────────────
    if not os.path.isfile(manifest_path):
        _log.error("Manifest file not found: %s", manifest_path)
        return 1

    with open(manifest_path, encoding="utf-8") as fh:
        try:
            manifest = json.load(fh)
        except json.JSONDecodeError as exc:
            _log.error("Failed to parse manifest JSON: %s", exc)
            return 1

    anchor_label: str = manifest.get("anchor_label", "anchor")
    long_out_dir: str = manifest.get("longitudinal_output_dir", "")
    sessions_raw: List[dict] = manifest.get("sessions", [])

    _log.info("Manifest loaded: anchor='%s', %d session(s)", anchor_label, len(sessions_raw))

    # ── Filter to successful sessions ─────────────────────────────────────────
    successful = [s for s in sessions_raw if s.get("exit_code", -1) == 0]
    _log.info("%d / %d session(s) succeeded", len(successful), len(sessions_raw))

    def _write_insufficient(note: str) -> None:
        _log.warning(note)
        empty_json = {
            "anchor_label": anchor_label,
            "note": note,
            "sessions": [],
            "region_volumes": {},
            "dynamics": {},
        }
        with open(os.path.join(output_dir, "longitudinal_change.json"), "w", encoding="utf-8") as f:
            json.dump(empty_json, f, indent=2)
        # Empty CSV / TSV
        for ext, delim in (("csv", ","), ("tsv", "\t")):
            with open(os.path.join(output_dir, f"longitudinal_change.{ext}"), "w",
                      newline="", encoding="utf-8") as f:
                csv.writer(f, delimiter=delim).writerow(
                    ["note", note]
                )
        _write_html(
            os.path.join(output_dir, "longitudinal_change.html"),
            anchor_label=anchor_label,
            session_labels=[],
            region_names={},
            volumes={},
            deltas={},
            dynamics={},
            insufficient=True,
            note=note,
        )

    if len(successful) < 2:
        _write_insufficient(
            f"Insufficient successful sessions ({len(successful)} < 2) — "
            "longitudinal change analysis requires at least 2."
        )
        return 0

    # ── Resolve session order: anchor first, then timepoints in list order ────
    ordered_sessions = sorted(
        successful,
        key=lambda s: (0 if s.get("role") == "anchor" else 1),
    )
    session_labels = [s["label"] for s in ordered_sessions]

    # Anchor session object (first after sort)
    anchor_session = ordered_sessions[0]
    anchor_results_dir = anchor_session.get("results_dir", "")

    _log.info("Session order: %s", " → ".join(session_labels))

    # ── Discover common-space atlas from anchor session ───────────────────────
    atlas_data: Optional[np.ndarray] = None
    atlas_affine: Optional[np.ndarray] = None
    atlas_shape: Optional[tuple] = None
    region_names: Dict[int, str] = {}

    atlas_path = _discover_atlas(anchor_results_dir) if anchor_results_dir else None
    if atlas_path:
        _log.info("Using region atlas: %s", atlas_path)
        try:
            atlas_data, atlas_affine = _load_nifti(atlas_path)
            atlas_shape = atlas_data.shape[:3]
            labels_in_atlas = [int(v) for v in np.unique(atlas_data) if v != _BACKGROUND_VALUE]
            for lbl in labels_in_atlas:
                region_names[lbl] = f"region_{lbl}"
            _log.info("Atlas: %d region label(s)", len(labels_in_atlas))
        except Exception as exc:  # pylint: disable=broad-except
            _log.warning("Failed to load atlas '%s': %s — falling back to whole-lesion mode.", atlas_path, exc)
            atlas_data = atlas_affine = atlas_shape = None
    else:
        _log.warning(
            "No region atlas found under anchor results dir '%s'. "
            "Using single whole-lesion region.", anchor_results_dir
        )

    # ── Discover and load lesion masks ────────────────────────────────────────
    session_masks: Dict[str, Tuple[np.ndarray, np.ndarray]] = {}  # label -> (data, affine)
    for sess in ordered_sessions:
        lbl = sess["label"]
        rdir = sess.get("results_dir", "")
        mask_path = _discover_lesion_mask(rdir) if rdir else None
        if not mask_path:
            _log.warning("Session '%s': no lesion mask found under '%s' — skipping.", lbl, rdir)
            continue
        try:
            mdata, maffine = _load_nifti(mask_path)
            session_masks[lbl] = (mdata, maffine)
            _log.info("Session '%s': lesion mask loaded from %s", lbl, mask_path)
        except Exception as exc:  # pylint: disable=broad-except
            _log.warning("Session '%s': failed to load mask '%s': %s — skipping.", lbl, mask_path, exc)

    if len(session_masks) < 2:
        _write_insufficient(
            f"Fewer than 2 sessions yielded loadable lesion masks "
            f"({len(session_masks)}) — longitudinal change analysis skipped."
        )
        return 0

    # ── Establish common grid from anchor mask (fallback if atlas absent) ─────
    if atlas_shape is None:
        # Use anchor mask grid as the common reference
        if anchor_label in session_masks:
            ref_data, ref_affine_arr = session_masks[anchor_label]
            atlas_affine = ref_affine_arr
            atlas_shape = ref_data.shape[:3]
            # Build a synthetic single-region "atlas" matching the anchor mask grid
            atlas_data = np.ones(atlas_shape, dtype=np.int32)
            region_names = {_WHOLE_BRAINSTEM_LABEL: "whole_lesion_region"}
            _log.info("Synthetic single-region atlas built from anchor mask grid.")
        else:
            _write_insufficient(
                "No atlas and anchor mask not loadable — cannot establish common grid."
            )
            return 0

    # ── Resample all masks to common grid ────────────────────────────────────
    resampled_masks: Dict[str, np.ndarray] = {}
    for lbl, (mdata, maffine) in session_masks.items():
        resampled_masks[lbl] = _ensure_common_grid(
            mdata, maffine, atlas_affine, atlas_shape, lbl
        )

    # Ensure atlas is on its own grid (should already be, but normalise type)
    atlas_bin = atlas_data.astype(np.int32)
    vox_vol = _voxel_volume_mm3(atlas_affine)
    _log.info("Common-space voxel volume: %.4f mm³", vox_vol)

    # ── Per-region volumes ────────────────────────────────────────────────────
    # volumes[session_label][region_int] = vol_mm3
    volumes: Dict[str, Dict[int, float]] = {}

    for lbl in session_labels:
        if lbl not in resampled_masks:
            volumes[lbl] = {}
            continue
        volumes[lbl] = _region_volumes(resampled_masks[lbl], atlas_bin, vox_vol)

    # ── Deltas vs anchor (anchor delta = 0.0 for regions present in anchor) ──
    deltas: Dict[str, Dict[int, float]] = {}
    anchor_vols = volumes.get(anchor_label, {})
    all_region_labels: set[int] = set()
    for sv in volumes.values():
        all_region_labels.update(sv.keys())
    # Also include atlas labels even if zero in all sessions
    all_region_labels.update(region_names.keys())

    for lbl in session_labels:
        sess_vols = volumes.get(lbl, {})
        deltas[lbl] = {}
        for rlbl in all_region_labels:
            baseline_vol = anchor_vols.get(rlbl, 0.0)
            session_vol = sess_vols.get(rlbl, 0.0)
            if lbl == anchor_label:
                deltas[lbl][rlbl] = 0.0
            else:
                deltas[lbl][rlbl] = session_vol - baseline_vol

    # Prune: only keep region labels that are non-zero in at least one session
    nonzero_regions: Dict[int, str] = {}
    for rlbl, rname in region_names.items():
        if any(volumes.get(sl, {}).get(rlbl, 0.0) > 0.0 for sl in session_labels):
            nonzero_regions[rlbl] = rname

    # If still empty keep all atlas labels (for minimal empty-run reports)
    if not nonzero_regions:
        nonzero_regions = region_names.copy()

    # ── Cross-timepoint dynamics ──────────────────────────────────────────────
    dynamics: Dict[str, Dict[str, int]] = {}
    anchor_mask = resampled_masks.get(anchor_label)

    if anchor_mask is not None:
        for lbl in session_labels:
            if lbl == anchor_label:
                continue
            fu_mask = resampled_masks.get(lbl)
            if fu_mask is None:
                _log.warning("Session '%s': no resampled mask for dynamics — skipping.", lbl)
                continue
            _log.info("Computing dynamics: anchor='%s' vs followup='%s'", anchor_label, lbl)
            try:
                dyn = _compute_dynamics(anchor_mask, fu_mask, vox_vol)
                dynamics[lbl] = dyn
                _log.info(
                    "  Dynamics for '%s': new=%d resolved=%d growing=%d shrinking=%d stable=%d",
                    lbl, dyn["new"], dyn["resolved"], dyn["growing"],
                    dyn["shrinking"], dyn["stable"],
                )
            except Exception as exc:  # pylint: disable=broad-except
                _log.warning("Dynamics computation failed for '%s': %s", lbl, exc)

    # ── Optional add-ons (silently skipped if data absent) ────────────────────
    # Contrast-enhanced T1 note
    enhancement_notes: Dict[str, str] = {}
    for sess in ordered_sessions:
        ce_env = sess.get("contrast_enhanced_t1", "")
        if ce_env:
            enhancement_notes[sess["label"]] = "contrast-enhanced T1 present"

    # DWI restriction evolution (if cross-modal CSV present)
    dwi_evolution: Dict[str, str] = {}
    for sess in ordered_sessions:
        rdir = sess.get("results_dir", "")
        if not rdir:
            continue
        cm_csv = os.path.join(rdir, "analysis", "cross_modal", "cross_modal_clusters.csv")
        if os.path.isfile(cm_csv):
            dwi_evolution[sess["label"]] = cm_csv

    # ── Emit reports ──────────────────────────────────────────────────────────
    # --- CSV ---
    csv_path = os.path.join(output_dir, "longitudinal_change.csv")
    _write_csv(csv_path, nonzero_regions, session_labels, volumes, deltas, delimiter=",")
    _log.info("Wrote: %s", csv_path)

    # --- TSV ---
    tsv_path = os.path.join(output_dir, "longitudinal_change.tsv")
    _write_csv(tsv_path, nonzero_regions, session_labels, volumes, deltas, delimiter="\t")
    _log.info("Wrote: %s", tsv_path)

    # --- JSON ---
    json_summary = {
        "anchor_label": anchor_label,
        "session_labels": session_labels,
        "common_space": "anchor_t1",
        "voxel_volume_mm3": round(vox_vol, 6),
        "region_names": {str(k): v for k, v in nonzero_regions.items()},
        "region_volumes": {
            sl: {str(k): round(v, 3) for k, v in volumes.get(sl, {}).items()}
            for sl in session_labels
        },
        "region_deltas_vs_anchor": {
            sl: {str(k): round(v, 3) for k, v in deltas.get(sl, {}).items()}
            for sl in session_labels
            if sl != anchor_label
        },
        "lesion_dynamics": {
            sl: dyn for sl, dyn in dynamics.items()
        },
        "enhancement_notes": enhancement_notes,
        "dwi_cross_modal_available": {sl: path for sl, path in dwi_evolution.items()},
    }
    json_path = os.path.join(output_dir, "longitudinal_change.json")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(json_summary, fh, indent=2)
    _log.info("Wrote: %s", json_path)

    # --- HTML ---
    html_path = os.path.join(output_dir, "longitudinal_change.html")
    _write_html(
        html_path,
        anchor_label=anchor_label,
        session_labels=session_labels,
        region_names=nonzero_regions,
        volumes=volumes,
        deltas=deltas,
        dynamics=dynamics,
    )
    _log.info("Wrote: %s", html_path)

    _log.info(
        "Longitudinal change analysis complete: %d session(s), %d region(s), "
        "%d dynamics comparison(s).",
        len(session_labels), len(nonzero_regions), len(dynamics),
    )
    print(f"longitudinal_change: reports written to {output_dir}")
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="longitudinal_change.py",
        description=(
            "BrainStemX-Full Unit E — longitudinal change analysis.\n"
            "Reads the orchestrator manifest (longitudinal_manifest.json) and "
            "emits per-region × per-session lesion volume tables, deltas, "
            "new/resolved/growing/shrinking dynamics, and HTML/CSV/JSON reports."
        ),
    )
    ap.add_argument(
        "--manifest",
        required=True,
        metavar="PATH",
        help="Path to longitudinal_manifest.json written by src/longitudinal.sh.",
    )
    ap.add_argument(
        "--output",
        required=True,
        metavar="DIR",
        help="Directory to write longitudinal_change.{csv,tsv,json,html}.",
    )
    return ap


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = _build_parser()
    args = ap.parse_args(argv)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return run_analysis(args.manifest, args.output)


if __name__ == "__main__":
    sys.exit(main())
