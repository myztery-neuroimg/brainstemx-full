"""Tests for src/modules/viz_render.py (synthetic nibabel volumes; no FSL)."""

import os
import subprocess
import sys

import numpy as np
import nibabel as nib
import pytest

HERE = os.path.dirname(__file__)
MOD = os.path.join(HERE, "..", "src", "modules")
sys.path.insert(0, MOD)

import viz_render as vr  # noqa: E402


def _sphere(shape, centre, radius):
    zz, yy, xx = np.mgrid[0:shape[0], 0:shape[1], 0:shape[2]]
    return ((zz - centre[0]) ** 2 + (yy - centre[1]) ** 2 + (xx - centre[2]) ** 2) <= radius ** 2


@pytest.fixture
def vols(tmp_path):
    shape = (32, 40, 36)
    rng = np.random.default_rng(0)
    bg = rng.normal(100, 10, shape).astype(np.float32)
    bg[_sphere(shape, (16, 20, 18), 12)] += 80
    aff = np.diag([1.0, 1.0, 1.0, 1.0])
    p = {}
    p["bg"] = str(tmp_path / "bg.nii.gz"); nib.save(nib.Nifti1Image(bg, aff), p["bg"])
    mask = _sphere(shape, (16, 20, 18), 4).astype(np.uint8)
    p["mask"] = str(tmp_path / "mask.nii.gz"); nib.save(nib.Nifti1Image(mask, aff), p["mask"])
    lab = np.zeros(shape, dtype=np.int16); lab[_sphere(shape, (12, 20, 18), 3)] = 1; lab[_sphere(shape, (20, 20, 18), 3)] = 34
    p["label"] = str(tmp_path / "label.nii.gz"); nib.save(nib.Nifti1Image(lab, aff), p["label"])
    p["lut"] = str(tmp_path / "lut.txt"); open(p["lut"], "w").write("# lut\n1 Pontine nuclei 255 0 0 0\n34 Locus coeruleus 0 255 0 0\n")
    z = np.zeros(shape, dtype=np.float32); z[mask > 0] = rng.uniform(1.5, 4.0, int(mask.sum()))
    p["z"] = str(tmp_path / "z.nii.gz"); nib.save(nib.Nifti1Image(z, aff), p["z"])
    # a "moving" image on a different grid (2mm) for resampling paths
    mv = bg[::2, ::2, ::2].copy()
    p["moving"] = str(tmp_path / "moving.nii.gz"); nib.save(nib.Nifti1Image(mv, np.diag([2.0, 2.0, 2.0, 1.0])), p["moving"])
    p["after"] = str(tmp_path / "after.nii.gz"); nib.save(nib.Nifti1Image(bg * 1.1 + 5, aff), p["after"])
    return p


def _png_ok(path):
    assert os.path.isfile(path), path
    assert os.path.getsize(path) > 2000
    assert os.path.isfile(path[:-4] + ".caption.txt")


def test_overlay_masks_labels_maps(vols, tmp_path):
    out = str(tmp_path / "viz" / "segmentation" / "overlay.png")
    ovs = [vr.Overlay.parse("mask", f"{vols['mask']}:colour=#00ff00,mode=contour,name=pons"),
           vr.Overlay.parse("label", f"{vols['label']}:lut={vols['lut']},alpha=0.5"),
           vr.Overlay.parse("map", f"{vols['z']}:cmap=hot,vmin=1,vmax=4,alpha=0.7")]
    vr.render_overlay(vols["bg"], out, ovs, ["axial", "coronal", "sagittal"], 4, "mask", "overlay test", 80, 0.0, "caption here")
    _png_ok(out)
    assert open(out[:-4] + ".caption.txt").read().strip() == "caption here"


def test_overlay_zoom_and_fill(vols, tmp_path):
    out = str(tmp_path / "zoom.png")
    ovs = [vr.Overlay.parse("mask", f"{vols['mask']}:mode=fill,alpha=0.4,name=lc")]
    vr.render_overlay(vols["bg"], out, ovs, ["axial"], 3, "mask", "", 80, 8.0, "")
    _png_ok(out) if os.path.isfile(out[:-4] + ".caption.txt") else None
    assert os.path.getsize(out) > 1000


def test_overlay_resamples_other_grid(vols, tmp_path):
    out = str(tmp_path / "resample.png")
    ovs = [vr.Overlay.parse("map", f"{vols['moving']}:cmap=viridis,alpha=0.5")]
    vr.render_overlay(vols["bg"], out, ovs, ["axial"], 2, "bg", "", 60, 0.0, "c")
    _png_ok(out)


def test_checkerboard_and_diff_and_hist(vols, tmp_path):
    cb = str(tmp_path / "reg" / "cb.png")
    vr.render_checkerboard(vols["bg"], vols["moving"], cb, 6, ["axial", "sagittal"], 2, "reg", 60, "c", vols["mask"])
    _png_ok(cb)
    df = str(tmp_path / "diff.png")
    vr.render_diff(vols["bg"], vols["after"], df, ["axial"], 2, "n4", 60, "c", ("raw", "N4"), vols["mask"])
    _png_ok(df)
    h = str(tmp_path / "hist.png")
    vr.render_hist(vols["z"], vols["mask"], h, "0.7,2.0,0.4;0.3,3.5,0.3", [2.8], "gmm", 60, "c", 40, "z")
    _png_ok(h)


def test_parse_lut_and_colours(vols):
    lut = vr.parse_lut(vols["lut"])
    assert lut[34][0] == "Locus_coeruleus" and lut[34][1] == (0.0, 1.0, 0.0)
    assert vr.colour_for("jhu_middle_cerebellar_peduncle_label1") == vr.SOURCE_COLOURS["jhu"]
    assert vr.colour_for("unknown_thing", "#123456") == "#123456"


def test_gallery(vols, tmp_path):
    root = tmp_path / "visualizations"
    (root / "segmentation").mkdir(parents=True)
    (root / "empty_stage").mkdir()
    out = str(root / "segmentation" / "a.png")
    vr.render_overlay(vols["bg"], out, [vr.Overlay.parse("mask", vols["mask"])], ["axial"], 1, "mask", "t", 50, 0.0, "seg caption")
    idx = vr.build_gallery(str(root), None, "gallery")
    html_text = open(idx).read()
    assert "seg caption" in html_text and "segmentation/a.png" in html_text
    assert "empty_stage" not in html_text
    assert "segmentation/a.thumb.png" in html_text and os.path.isfile(str(root / "segmentation" / "a.thumb.png"))
    (root / "import").mkdir(); (root / "import" / "b.png").write_bytes(open(out, "rb").read())
    idx2 = open(vr.build_gallery(str(root), None, "gallery")).read()
    assert idx2.index('id="import"') < idx2.index('id="segmentation"')      # fixed stage order
    assert os.path.isfile(str(root / "manifest.json"))


def test_cli_runs_and_reports_errors(vols, tmp_path):
    script = os.path.join(MOD, "viz_render.py")
    out = str(tmp_path / "cli.png")
    r = subprocess.run([sys.executable, script, "overlay", "--bg", vols["bg"], "--out", out, "--mask", vols["mask"], "--slices", "2", "--planes", "axial"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    _png_ok(out)
    r = subprocess.run([sys.executable, script, "overlay", "--bg", "/nonexistent.nii.gz", "--out", out], capture_output=True, text=True)
    assert r.returncode == 1 and "viz_render overlay" in r.stderr
