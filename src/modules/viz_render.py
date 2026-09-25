#!/usr/bin/env python3
"""viz_render.py - shared, headless figure renderer for the BrainStemX pipeline.

The bash stages only DISCOVER inputs; every figure is drawn here (numpy +
nibabel + matplotlib, ``Agg`` backend) so visual QC no longer depends on FSL
``slicer`` / ``fsleyes`` being installed and looks the same on every host.

Sub-commands (all write a PNG and, next to it, a ``<name>.caption.txt``):

  overlay       background + any number of overlays (binary masks as contour
                or filled alpha, label images with a LUT + legend, continuous
                maps with a colormap + colorbar) as a planes x slices mosaic,
                slices centred on a mask / the brainstem / explicit voxel.
  checkerboard  registration QC: fixed/moving checkerboard + moving edges on
                fixed, per plane.
  diff          before/after/difference (e.g. denoising, N4, FP filter).
  hist          intensity histogram inside a mask with optional Gaussian
                mixture components and threshold lines (GMM fit QC).
  gallery       walk <root>/<stage>/*.png and write <root>/index.html (+
                manifest.json) grouped by stage with captions.

Exit status: 0 on success, 1 on any error (message on stderr). Callers treat a
failure as non-fatal. Never imports FSL/ANTs. Python 3.12 (run via ``uv run``).
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

try:  # matplotlib is an explicit project dependency; fail cleanly if absent
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import colors as mcolors
    from matplotlib.patches import Patch
except Exception as exc:  # pragma: no cover - environment problem
    sys.stderr.write(f"viz_render: matplotlib unavailable: {exc}\n")
    sys.exit(1)

try:
    import nibabel as nib
    from nibabel.processing import resample_from_to
except Exception as exc:  # pragma: no cover
    sys.stderr.write(f"viz_render: nibabel unavailable: {exc}\n")
    sys.exit(1)


# --------------------------------------------------------------------------- #
# Colour conventions (consistent across every figure and the HTML report)
# --------------------------------------------------------------------------- #
SOURCE_COLOURS: Dict[str, str] = {
    "harvard_oxford": "#ff7f0e",
    "freesurfer": "#1f77b4",
    "bianciardi": "#2ca02c",
    "cit168": "#d62728",
    "aal3": "#9467bd",
    "jhu": "#8c564b",
    "xtract": "#e377c2",
    "aan": "#7f7f7f",
    "lc": "#bcbd22",
    "dr": "#17becf",
    "nextbrain": "#ffbb78",
    "nextbrainmni": "#98df8a",
    "synthseg": "#c5b0d5",
    "aseg": "#c49c94",
    "lesion": "#ff0000",
    "consensus": "#ffff00",
    "csf": "#00bfff",
    "brain": "#00ff7f",
    "brainstem": "#ffa500",
    "pons": "#00ff00",
    "midbrain": "#1e90ff",
    "medulla": "#ff69b4",
}
PLANES = ("axial", "coronal", "sagittal")
PLANE_AXIS = {"axial": 2, "coronal": 1, "sagittal": 0}


def colour_for(name: str, fallback: str = "#ff0000") -> str:
    """Colour for a source/region tag (prefix match), else the fallback."""
    n = (name or "").lower()
    for key, col in SOURCE_COLOURS.items():
        if n == key or n.startswith(key + "_") or n.endswith("_" + key):
            return col
    return fallback


# --------------------------------------------------------------------------- #
# Volume loading helpers
# --------------------------------------------------------------------------- #
def load_canonical(path: str) -> nib.Nifti1Image:
    """Load a NIfTI and reorient to RAS so every figure shares one convention."""
    img = nib.load(path)
    if img.ndim > 3:
        data = np.asanyarray(img.dataobj)
        img = nib.Nifti1Image(data[..., 0] if data.ndim == 4 else data, img.affine, img.header)
    return nib.as_closest_canonical(img)


def on_grid(img: nib.Nifti1Image, ref: nib.Nifti1Image, order: int) -> np.ndarray:
    """Return ``img`` data on ``ref``'s grid (identity when already aligned)."""
    if img.shape[:3] == ref.shape[:3] and np.allclose(img.affine, ref.affine, atol=1e-3):
        return np.asanyarray(img.dataobj).astype(np.float32)
    res = resample_from_to(img, (ref.shape[:3], ref.affine), order=order)
    return np.asanyarray(res.dataobj).astype(np.float32)


def robust_window(data: np.ndarray, lo: float = 1.0, hi: float = 99.0) -> Tuple[float, float]:
    vals = data[np.isfinite(data)]
    vals = vals[vals != 0]
    if vals.size == 0:
        return 0.0, 1.0
    a, b = np.percentile(vals, [lo, hi])
    if b <= a:
        b = a + 1.0
    return float(a), float(b)


def parse_lut(path: Optional[str]) -> Dict[int, Tuple[str, Optional[Tuple[float, float, float]]]]:
    """'value name [R G B [A]]' (FreeSurfer / registry) or 'value name'."""
    out: Dict[int, Tuple[str, Optional[Tuple[float, float, float]]]] = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.replace("\t", " ").split()
            try:
                val = int(parts[0])
            except (ValueError, IndexError):
                continue
            rgb = None
            name_parts = parts[1:]
            if len(parts) >= 5 and all(p.isdigit() for p in parts[-3:]):
                rgb_raw = parts[-3:]
                name_parts = parts[1:-3]
                if len(parts) >= 6 and parts[-4].isdigit() and all(p.isdigit() for p in parts[-4:]):
                    rgb_raw = parts[-4:-1]
                    name_parts = parts[1:-4]
                rgb = tuple(int(c) / 255.0 for c in rgb_raw)  # type: ignore[assignment]
            name = "_".join(name_parts) if name_parts else f"label{val}"
            out[val] = (name, rgb)  # type: ignore[arg-type]
    return out


# --------------------------------------------------------------------------- #
# Slice selection
# --------------------------------------------------------------------------- #
def mask_bbox_centroid(mask: np.ndarray) -> Tuple[Optional[np.ndarray], Optional[np.ndarray]]:
    idx = np.argwhere(mask > 0)
    if idx.size == 0:
        return None, None
    return idx.min(axis=0), idx.max(axis=0)


def pick_slices(shape: Sequence[int], axis: int, n: int, focus: Optional[np.ndarray],
                margin: int = 2) -> List[int]:
    """``n`` slice indices along ``axis``: spread through the focus mask's
    extent (plus a margin) when given, else through the central 60 % of the
    volume."""
    dim = int(shape[axis])
    if focus is not None and focus.any():
        lo, hi = mask_bbox_centroid(focus)
        a = max(0, int(lo[axis]) - margin)  # type: ignore[index]
        b = min(dim - 1, int(hi[axis]) + margin)  # type: ignore[index]
    else:
        a, b = int(dim * 0.2), int(dim * 0.8)
    if n <= 1:
        return [int(round((a + b) / 2))]
    return sorted(set(int(round(v)) for v in np.linspace(a, b, n)))


def take_slice(vol: np.ndarray, axis: int, i: int) -> np.ndarray:
    """2-D slice oriented for display (RAS volume; anterior/superior up)."""
    i = int(np.clip(i, 0, vol.shape[axis] - 1))
    if axis == 2:      # axial: x right, y up
        sl = vol[:, :, i]
    elif axis == 1:    # coronal: x right, z up
        sl = vol[:, i, :]
    else:              # sagittal: y right, z up
        sl = vol[i, :, :]
    return np.rot90(sl)


# --------------------------------------------------------------------------- #
# Overlay figure
# --------------------------------------------------------------------------- #
class Overlay:
    """One overlay spec: kind in {mask, label, map}."""

    def __init__(self, kind: str, path: str, **kw):
        self.kind = kind
        self.path = path
        self.name = kw.get("name") or os.path.basename(path).split(".")[0]
        self.colour = kw.get("colour") or colour_for(self.name)
        self.mode = kw.get("mode", "contour")
        self.alpha = float(kw.get("alpha", 0.45))
        self.cmap = kw.get("cmap", "hot")
        self.vmin = kw.get("vmin")
        self.vmax = kw.get("vmax")
        self.lut = kw.get("lut")
        self.value = kw.get("value")  # select one label value from a label image

    @classmethod
    def parse(cls, kind: str, spec: str) -> "Overlay":
        """CLI spec: path[:key=value,...]  e.g. mask.nii.gz:colour=#ff0000,mode=fill,alpha=0.4,name=pons"""
        path, _, rest = spec.partition("::") if "::" in spec else (spec.split(":")[0], ":", ":".join(spec.split(":")[1:]))
        kw: Dict[str, object] = {}
        for item in filter(None, rest.split(",")):
            k, _, v = item.partition("=")
            k = k.strip()
            if k in ("alpha", "vmin", "vmax"):
                try:
                    kw[k] = float(v)
                except ValueError:
                    pass
            elif k == "value":
                kw[k] = int(v)
            elif k:
                kw[k] = v
        return cls(kind, path, **kw)


def _label_colour_table(values: np.ndarray, lut: Dict[int, Tuple[str, Optional[Tuple[float, float, float]]]]):
    cmap20 = plt.get_cmap("tab20")
    table = {}
    for i, v in enumerate(sorted(int(x) for x in values if x != 0)):
        name, rgb = lut.get(v, (f"label{v}", None))
        table[v] = (name, rgb if rgb is not None else cmap20(i % 20)[:3])
    return table


def render_overlay(bg_path: str, out: str, overlays: List[Overlay], planes: Sequence[str],
                   n_slices: int, center: str, title: str, dpi: int, zoom_mm: float,
                   caption: str) -> None:
    bg = load_canonical(bg_path)
    bgd = np.asanyarray(bg.dataobj).astype(np.float32)
    vmin, vmax = robust_window(bgd)

    prepared = []
    focus = None
    for ov in overlays:
        img = load_canonical(ov.path)
        order = 0 if ov.kind in ("mask", "label") else 1
        data = on_grid(img, bg, order)
        if ov.kind == "mask":
            if ov.value is not None:
                data = (np.rint(data) == ov.value).astype(np.float32)
            else:
                data = (data > 0).astype(np.float32)
        prepared.append((ov, data))
        if ov.kind in ("mask", "label") and center == "mask" and focus is None and data.any():
            focus = data > 0
    if center not in ("mask", "bg") and "," in center:
        try:
            cx, cy, cz = (int(v) for v in center.split(","))
            focus = np.zeros(bgd.shape, dtype=bool)
            focus[cx, cy, cz] = True
        except ValueError:
            pass
    if center == "mask" and focus is None:
        # nothing to centre on: fall back to any overlay with signal
        for ov, data in prepared:
            if data.any():
                focus = np.abs(data) > 0
                break

    planes = [p for p in planes if p in PLANE_AXIS] or list(PLANES)
    ncol = max(1, n_slices)
    fig, axes = plt.subplots(len(planes), ncol, figsize=(2.4 * ncol, 2.6 * len(planes)), squeeze=False)
    fig.patch.set_facecolor("black")
    zoom_vox = None
    if zoom_mm > 0 and focus is not None:
        vs = np.asarray(bg.header.get_zooms()[:3], dtype=float)
        zoom_vox = np.maximum(1, np.rint(zoom_mm / vs)).astype(int)
        lo, hi = mask_bbox_centroid(focus)
        ctr = (lo + hi) / 2.0  # type: ignore[operator]

    legend_handles: List[Patch] = []
    seen_legend = set()
    mappable = None
    for r, plane in enumerate(planes):
        axis = PLANE_AXIS[plane]
        idxs = pick_slices(bgd.shape, axis, ncol, focus)
        for c in range(ncol):
            ax = axes[r][c]
            ax.set_facecolor("black")
            ax.set_xticks([])
            ax.set_yticks([])
            for spine in ax.spines.values():
                spine.set_visible(False)
            if c >= len(idxs):
                ax.axis("off")
                continue
            i = idxs[c]
            ax.imshow(take_slice(bgd, axis, i), cmap="gray", vmin=vmin, vmax=vmax, interpolation="nearest")
            for ov, data in prepared:
                sl = take_slice(data, axis, i)
                if ov.kind == "mask":
                    if not sl.any():
                        continue
                    if ov.mode == "fill":
                        rgba = np.zeros(sl.shape + (4,), dtype=np.float32)
                        rgb = mcolors.to_rgb(ov.colour)
                        rgba[sl > 0] = (*rgb, ov.alpha)
                        ax.imshow(rgba, interpolation="nearest")
                    else:
                        ax.contour(sl, levels=[0.5], colors=[ov.colour], linewidths=0.9)
                    if ov.name not in seen_legend:
                        legend_handles.append(Patch(facecolor=ov.colour, edgecolor=ov.colour, label=ov.name))
                        seen_legend.add(ov.name)
                elif ov.kind == "label":
                    vals = np.unique(np.rint(data[data != 0]))
                    table = _label_colour_table(vals, parse_lut(ov.lut))
                    rgba = np.zeros(sl.shape + (4,), dtype=np.float32)
                    sli = np.rint(sl).astype(int)
                    for v, (name, rgb) in table.items():
                        m = sli == v
                        if m.any():
                            rgba[m] = (*rgb, ov.alpha)
                            if name not in seen_legend and len(legend_handles) < 40:
                                legend_handles.append(Patch(facecolor=rgb, label=name))
                                seen_legend.add(name)
                    ax.imshow(rgba, interpolation="nearest")
                else:  # continuous map
                    masked = np.ma.masked_where(~np.isfinite(sl) | (sl == 0), sl)
                    vmn = ov.vmin if ov.vmin is not None else float(np.nanmin(data[data != 0])) if (data != 0).any() else 0.0
                    vmx = ov.vmax if ov.vmax is not None else float(np.nanmax(data)) if (data != 0).any() else 1.0
                    mappable = ax.imshow(masked, cmap=ov.cmap, vmin=vmn, vmax=vmx, alpha=ov.alpha, interpolation="nearest")
            if zoom_vox is not None:
                # crop the panel around the focus centre (in slice coordinates)
                h, w = take_slice(bgd, axis, i).shape
                if axis == 2:
                    cx, cy = ctr[0], ctr[1]; span_x, span_y = zoom_vox[0], zoom_vox[1]
                elif axis == 1:
                    cx, cy = ctr[0], ctr[2]; span_x, span_y = zoom_vox[0], zoom_vox[2]
                else:
                    cx, cy = ctr[1], ctr[2]; span_x, span_y = zoom_vox[1], zoom_vox[2]
                ax.set_xlim(max(0, cx - span_x), min(w, cx + span_x))
                ax.set_ylim(min(h, h - cy + span_y), max(0, h - cy - span_y))
            ax.text(0.02, 0.96, f"{plane[:3]} {i}", color="white", fontsize=6, transform=ax.transAxes, va="top")
            if plane in ("axial", "coronal"):
                ax.text(0.02, 0.04, "L", color="yellow", fontsize=7, transform=ax.transAxes)
                ax.text(0.94, 0.04, "R", color="yellow", fontsize=7, transform=ax.transAxes)
    if legend_handles:
        fig.legend(handles=legend_handles, loc="lower center", ncol=min(6, len(legend_handles)), fontsize=6,
                   facecolor="black", labelcolor="white", frameon=False)
    if mappable is not None:
        cb = fig.colorbar(mappable, ax=axes.ravel().tolist(), fraction=0.02, pad=0.01)
        cb.ax.yaxis.set_tick_params(color="white", labelcolor="white", labelsize=6)
    if title:
        fig.suptitle(title, color="white", fontsize=9)
    _layout(fig, (0, 0.06 if legend_handles else 0, 1, 0.96 if title else 1))
    _save(fig, out, dpi, caption or title)


# --------------------------------------------------------------------------- #
# Registration QC: checkerboard + edges
# --------------------------------------------------------------------------- #
def render_checkerboard(fixed_path: str, moving_path: str, out: str, tiles: int, planes: Sequence[str],
                        n_slices: int, title: str, dpi: int, caption: str, mask_path: Optional[str]) -> None:
    fixed = load_canonical(fixed_path)
    fx = np.asanyarray(fixed.dataobj).astype(np.float32)
    mv = on_grid(load_canonical(moving_path), fixed, 1)
    focus = None
    if mask_path and os.path.isfile(mask_path):
        focus = on_grid(load_canonical(mask_path), fixed, 0) > 0
    fvmin, fvmax = robust_window(fx)
    mvmin, mvmax = robust_window(mv)
    fxn = np.clip((fx - fvmin) / (fvmax - fvmin), 0, 1)
    mvn = np.clip((mv - mvmin) / (mvmax - mvmin), 0, 1)
    planes = [p for p in planes if p in PLANE_AXIS] or list(PLANES)
    fig, axes = plt.subplots(len(planes), 2 * n_slices, figsize=(2.4 * 2 * n_slices, 2.6 * len(planes)), squeeze=False)
    fig.patch.set_facecolor("black")
    for r, plane in enumerate(planes):
        axis = PLANE_AXIS[plane]
        idxs = pick_slices(fx.shape, axis, n_slices, focus)
        for c in range(n_slices):
            i = idxs[min(c, len(idxs) - 1)]
            a = take_slice(fxn, axis, i)
            b = take_slice(mvn, axis, i)
            h, w = a.shape
            yy, xx = np.mgrid[0:h, 0:w]
            checker = ((yy // max(1, h // tiles)) + (xx // max(1, w // tiles))) % 2 == 0
            board = np.where(checker, a, b)
            ax = axes[r][2 * c]
            ax.imshow(board, cmap="gray", vmin=0, vmax=1, interpolation="nearest")
            ax.set_title(f"{plane[:3]} {i} checker", color="white", fontsize=6)
            ax2 = axes[r][2 * c + 1]
            ax2.imshow(a, cmap="gray", vmin=0, vmax=1, interpolation="nearest")
            # edges of the moving image via gradient magnitude threshold
            gy, gx = np.gradient(b)
            edges = np.hypot(gx, gy)
            thr = np.percentile(edges[np.isfinite(edges)], 92) if np.isfinite(edges).any() else 1.0
            ax2.contour(edges, levels=[thr], colors=["#ff3333"], linewidths=0.6)
            ax2.set_title(f"{plane[:3]} {i} moving edges on fixed", color="white", fontsize=6)
            for a_ in (ax, ax2):
                a_.set_xticks([]); a_.set_yticks([])
                for spine in a_.spines.values():
                    spine.set_visible(False)
    if title:
        fig.suptitle(title, color="white", fontsize=9)
    _layout(fig, (0, 0, 1, 0.96 if title else 1))
    _save(fig, out, dpi, caption or title)


# --------------------------------------------------------------------------- #
# Before / after / difference
# --------------------------------------------------------------------------- #
def render_diff(a_path: str, b_path: str, out: str, planes: Sequence[str], n_slices: int, title: str,
                dpi: int, caption: str, labels: Tuple[str, str], mask_path: Optional[str]) -> None:
    a_img = load_canonical(a_path)
    a = np.asanyarray(a_img.dataobj).astype(np.float32)
    b = on_grid(load_canonical(b_path), a_img, 1)
    focus = on_grid(load_canonical(mask_path), a_img, 0) > 0 if mask_path and os.path.isfile(mask_path) else None
    vmin, vmax = robust_window(a)
    d = b - a
    dlim = float(np.percentile(np.abs(d[np.isfinite(d)]), 99)) if np.isfinite(d).any() else 1.0
    dlim = dlim if dlim > 0 else 1.0
    planes = [p for p in planes if p in PLANE_AXIS] or list(PLANES)
    fig, axes = plt.subplots(len(planes) * n_slices, 3, figsize=(7.5, 2.6 * len(planes) * n_slices), squeeze=False)
    fig.patch.set_facecolor("black")
    row = 0
    mappable = None
    for plane in planes:
        axis = PLANE_AXIS[plane]
        for i in pick_slices(a.shape, axis, n_slices, focus):
            for col, (vol, name, cmap, lim) in enumerate(((a, labels[0], "gray", None), (b, labels[1], "gray", None), (d, "difference (after - before)", "coolwarm", dlim))):
                ax = axes[row][col]
                if lim is None:
                    ax.imshow(take_slice(vol, axis, i), cmap=cmap, vmin=vmin, vmax=vmax, interpolation="nearest")
                else:
                    mappable = ax.imshow(take_slice(vol, axis, i), cmap=cmap, vmin=-lim, vmax=lim, interpolation="nearest")
                ax.set_title(f"{name} [{plane[:3]} {i}]", color="white", fontsize=6)
                ax.set_xticks([]); ax.set_yticks([])
                for spine in ax.spines.values():
                    spine.set_visible(False)
            row += 1
    if mappable is not None:
        cb = fig.colorbar(mappable, ax=axes[:, 2].ravel().tolist(), fraction=0.03, pad=0.01)
        cb.ax.yaxis.set_tick_params(color="white", labelcolor="white", labelsize=6)
    if title:
        fig.suptitle(title, color="white", fontsize=9)
    _layout(fig, (0, 0, 1, 0.96 if title else 1))
    _save(fig, out, dpi, caption or title)


# --------------------------------------------------------------------------- #
# Histogram + mixture components
# --------------------------------------------------------------------------- #
def render_hist(image_path: str, mask_path: Optional[str], out: str, components: str, thresholds: Sequence[float],
                title: str, dpi: int, caption: str, bins: int, xlabel: str) -> None:
    img = load_canonical(image_path)
    data = np.asanyarray(img.dataobj).astype(np.float32)
    if mask_path and os.path.isfile(mask_path):
        m = on_grid(load_canonical(mask_path), img, 0) > 0
        vals = data[m]
    else:
        vals = data[data != 0]
    vals = vals[np.isfinite(vals)]
    fig, ax = plt.subplots(figsize=(6, 3.2))
    if vals.size == 0:
        ax.text(0.5, 0.5, "no voxels", ha="center", va="center")
    else:
        counts, edges, _ = ax.hist(vals, bins=bins, density=True, color="#9ecae1", edgecolor="none", label="voxels")
        xs = np.linspace(edges[0], edges[-1], 400)
        total = np.zeros_like(xs)
        for k, comp in enumerate(filter(None, components.split(";"))):
            try:
                w, mu, sd = (float(v) for v in comp.split(","))
            except ValueError:
                continue
            pdf = w * np.exp(-0.5 * ((xs - mu) / max(sd, 1e-6)) ** 2) / (max(sd, 1e-6) * np.sqrt(2 * np.pi))
            total += pdf
            ax.plot(xs, pdf, lw=1.2, label=f"component {k + 1}: w={w:.2f} mu={mu:.2f} sd={sd:.2f}")
        if total.any():
            ax.plot(xs, total, "k--", lw=1.0, label="mixture")
        for t in thresholds:
            ax.axvline(t, color="#d62728", lw=1.2, ls="-", label=f"threshold {t:.2f}")
        ax.legend(fontsize=6)
    ax.set_xlabel(xlabel)
    ax.set_ylabel("density")
    if title:
        ax.set_title(title, fontsize=9)
    fig.tight_layout()
    _save(fig, out, dpi, caption or title)


# --------------------------------------------------------------------------- #
# Gallery
# --------------------------------------------------------------------------- #
STAGE_ORDER = ["import", "preprocess", "brain_extraction", "registration", "segmentation", "detection",
               "fp_filter", "wmh", "cross_modal", "qa", "report"]


def _thumbnail(png: str, max_w: int = 360) -> Optional[str]:
    """<name>.thumb.png (stride-downsampled, no PIL); skipped when up to date."""
    thumb = png[:-4] + ".thumb.png"
    try:
        if os.path.isfile(thumb) and os.path.getmtime(thumb) >= os.path.getmtime(png):
            return thumb
        img = plt.imread(png)
        stride = max(1, int(np.ceil(img.shape[1] / max_w)))
        plt.imsave(thumb, img[::stride, ::stride])
        return thumb
    except Exception:
        return None


def build_gallery(root: str, out: Optional[str], title: str, thumbs: bool = True) -> str:
    out = out or os.path.join(root, "index.html")
    sections = []
    manifest = {"root": root, "stages": []}
    stages = [d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))]
    stages.sort(key=lambda d: (STAGE_ORDER.index(d) if d in STAGE_ORDER else len(STAGE_ORDER), d))
    for stage in stages:
        pngs = sorted(f for f in os.listdir(os.path.join(root, stage)) if f.lower().endswith(".png") and not f.endswith(".thumb.png"))
        if not pngs:
            continue
        items = []
        for f in pngs:
            base = f[:-4]
            cap_path = os.path.join(root, stage, base + ".caption.txt")
            caption = open(cap_path, encoding="utf-8", errors="replace").read().strip() if os.path.isfile(cap_path) else base.replace("_", " ")
            th = _thumbnail(os.path.join(root, stage, f)) if thumbs else None
            items.append({"file": f"{stage}/{f}", "thumb": f"{stage}/{os.path.basename(th)}" if th else f"{stage}/{f}", "caption": caption})
        manifest["stages"].append({"stage": stage, "items": items})
        cards = "\n".join(
            f'<figure><a href="{html.escape(it["file"])}"><img loading="lazy" src="{html.escape(it["thumb"])}" alt="{html.escape(it["caption"])}"></a>'
            f'<figcaption>{html.escape(it["caption"])}</figcaption></figure>' for it in items)
        sections.append(f'<section id="{html.escape(stage)}"><h2>{html.escape(stage.replace("_", " "))}</h2><div class="grid">{cards}</div></section>')
    # top-level PNGs (legacy report visualisations) as their own section
    top = sorted(f for f in os.listdir(root) if f.lower().endswith(".png") and not f.endswith(".thumb.png"))
    if top:
        items = [{"file": f, "caption": f[:-4].replace("_", " ")} for f in top]
        manifest["stages"].append({"stage": "report", "items": items})
        cards = "\n".join(f'<figure><a href="{html.escape(it["file"])}"><img loading="lazy" src="{html.escape(it["file"])}" alt=""></a><figcaption>{html.escape(it["caption"])}</figcaption></figure>' for it in items)
        sections.append(f'<section id="report"><h2>report</h2><div class="grid">{cards}</div></section>')
    nav = " | ".join(f'<a href="#{html.escape(s["stage"])}">{html.escape(s["stage"])}</a>' for s in manifest["stages"])
    doc = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:1.5rem}}h1{{font-size:1.3rem}}h2{{font-size:1.05rem;border-bottom:1px solid #444;padding-bottom:.2rem;margin-top:2rem}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:1rem}}figure{{margin:0;background:#1b1b1b;padding:.5rem;border-radius:6px}}img{{width:100%;height:auto;display:block}}
figcaption{{font-size:.8rem;color:#bbb;margin-top:.4rem}}nav{{font-size:.85rem;color:#9ecae1}}a{{color:#9ecae1}}</style></head>
<body><h1>{html.escape(title)}</h1><nav>{nav}</nav>{''.join(sections) or '<p>No visualisations were produced.</p>'}</body></html>"""
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(doc)
    with open(os.path.join(os.path.dirname(out) or ".", "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)
    return out


# --------------------------------------------------------------------------- #
def _save(fig, out: str, dpi: int, caption: str) -> None:
    """Write the PNG and ALWAYS a sidecar caption (the gallery relies on it)."""
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    fig.savefig(out, dpi=dpi, facecolor=fig.get_facecolor())
    plt.close(fig)
    if not caption:
        caption = os.path.basename(out).rsplit(".", 1)[0].replace("_", " ")
    cap = out[:-4] + ".caption.txt" if out.lower().endswith(".png") else out + ".caption.txt"
    with open(cap, "w", encoding="utf-8") as fh:
        fh.write(caption.strip() + "\n")


def _layout(fig, rect) -> None:
    """tight_layout that stays quiet when a colorbar axis is present."""
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            fig.tight_layout(rect=rect)
        except Exception:
            pass


def _planes(arg: str) -> List[str]:
    return [p.strip() for p in arg.split(",") if p.strip()]


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("overlay")
    p.add_argument("--bg", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mask", action="append", default=[], help="path[:colour=#hex,mode=contour|fill,alpha=,name=,value=]")
    p.add_argument("--label", action="append", default=[], help="path[:lut=path,alpha=]")
    p.add_argument("--map", action="append", default=[], help="path[:cmap=,vmin=,vmax=,alpha=]")
    p.add_argument("--planes", default="axial,coronal,sagittal")
    p.add_argument("--slices", type=int, default=5)
    p.add_argument("--center", default="mask", help="mask | bg | x,y,z (voxel)")
    p.add_argument("--zoom-mm", type=float, default=0.0, help="crop panels to +/- this many mm around the focus")
    p.add_argument("--title", default="")
    p.add_argument("--caption", default="")
    p.add_argument("--dpi", type=int, default=110)

    p = sub.add_parser("checkerboard")
    p.add_argument("--fixed", required=True)
    p.add_argument("--moving", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mask", default=None, help="focus mask (slice selection)")
    p.add_argument("--tiles", type=int, default=8)
    p.add_argument("--planes", default="axial,coronal,sagittal")
    p.add_argument("--slices", type=int, default=2)
    p.add_argument("--title", default="")
    p.add_argument("--caption", default="")
    p.add_argument("--dpi", type=int, default=110)

    p = sub.add_parser("diff")
    p.add_argument("--before", required=True)
    p.add_argument("--after", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mask", default=None)
    p.add_argument("--labels", default="before,after")
    p.add_argument("--planes", default="axial")
    p.add_argument("--slices", type=int, default=2)
    p.add_argument("--title", default="")
    p.add_argument("--caption", default="")
    p.add_argument("--dpi", type=int, default=110)

    p = sub.add_parser("hist")
    p.add_argument("--image", required=True)
    p.add_argument("--mask", default=None)
    p.add_argument("--out", required=True)
    p.add_argument("--components", default="", help='"w,mu,sd;w,mu,sd" Gaussian components')
    p.add_argument("--threshold", type=float, action="append", default=[])
    p.add_argument("--bins", type=int, default=80)
    p.add_argument("--xlabel", default="intensity / z")
    p.add_argument("--title", default="")
    p.add_argument("--caption", default="")
    p.add_argument("--dpi", type=int, default=120)

    p = sub.add_parser("gallery")
    p.add_argument("--root", required=True)
    p.add_argument("--out", default=None)
    p.add_argument("--title", default="BrainStemX visual QC")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "overlay":
            ovs = [Overlay.parse("mask", s) for s in args.mask] + [Overlay.parse("label", s) for s in args.label] + [Overlay.parse("map", s) for s in args.map]
            render_overlay(args.bg, args.out, ovs, _planes(args.planes), args.slices, args.center, args.title, args.dpi, args.zoom_mm, args.caption)
        elif args.cmd == "checkerboard":
            render_checkerboard(args.fixed, args.moving, args.out, args.tiles, _planes(args.planes), args.slices, args.title, args.dpi, args.caption, args.mask)
        elif args.cmd == "diff":
            lab = tuple(args.labels.split(",", 1)) if "," in args.labels else (args.labels, "after")
            render_diff(args.before, args.after, args.out, _planes(args.planes), args.slices, args.title, args.dpi, args.caption, lab, args.mask)  # type: ignore[arg-type]
        elif args.cmd == "hist":
            render_hist(args.image, args.mask, args.out, args.components, args.threshold, args.title, args.dpi, args.caption, args.bins, args.xlabel)
        elif args.cmd == "gallery":
            print(build_gallery(args.root, args.out, args.title))
    except Exception as exc:  # any failure is reported, never a traceback flood
        sys.stderr.write(f"viz_render {args.cmd}: {type(exc).__name__}: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
