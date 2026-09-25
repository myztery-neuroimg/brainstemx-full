"""Tests for src/modules/lesion_posterior.py (the principled detection engine)."""

import os
import subprocess
import sys

import nibabel as nib
import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "modules"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import lesion_posterior as lp  # noqa: E402
from benchmark import metrics, phantom  # noqa: E402


def _noise(shape=(30, 30, 30), seed=0):
    rng = np.random.default_rng(seed)
    R = np.zeros(shape, bool); R[4:26, 4:26, 4:26] = True
    return rng.normal(100, 10, shape).astype(np.float32), R


def test_healthy_region_flags_nothing():
    I, R = _noise()
    r = lp.detect_array(I, R)
    assert r["n_final"] == 0 and len(r["clusters"]) == 0
    assert r["pi0"] > 0.9 and abs(r["delta0"]) < 0.2 and 0.8 < r["sigma0"] < 1.2
    assert r["mask_bh"].sum() <= 3          # BH at q=0.05 on ~10k nulls: at most a handful
    assert np.all(r["posterior"][~R] == 0)


def test_empirical_null_recovers_scale_and_pi0():
    rng = np.random.default_rng(1)
    z = np.concatenate([rng.normal(0.2, 1.1, 20000), rng.normal(4.5, 0.6, 1000)])
    d, s, pi0 = lp.empirical_null(z, 0.05, 0.75)
    assert abs(d - 0.2) < 0.15 and abs(s - 1.1) < 0.15 and 0.9 < pi0 <= 1.0


def test_local_fdr_monotone_and_posterior_rule():
    rng = np.random.default_rng(2)
    z = np.concatenate([rng.normal(0, 1, 5000), rng.normal(5, 0.5, 250)])
    lf, grid, lfg = lp.local_fdr(z, 0.0, 1.0, 5000 / 5250)
    right = grid >= 0
    assert np.all(np.diff(lfg[right]) <= 1e-12)          # non-increasing on the right tail
    post = 1 - lf
    mask = lp.posterior_fdr_mask(post, 0.05)
    assert 200 <= mask.sum() <= 320                       # the 250 lesion voxels, few nulls
    assert (1 - post[mask]).mean() <= 0.05


def test_phantom_brainstem_and_wm():
    v = phantom.render(phantom.PhantomSpec(seed=2, n_lesions=5, brainstem_lesions=2))
    for reg, min_dice in (("brainstem", 0.7), ("wm", 0.75)):
        res = lp.detect_array(v["flair"], v[reg], extra={"brain": v["brain"]})
        m = metrics.evaluate(res["mask"], v["gt"] & v[reg].astype(bool), (1, 1, 1), prob=res["posterior"], eval_mask=v[reg])
        assert m["dice"] > min_dice, (reg, m["dice"])
        assert m["lesion_tpr"] == 1.0
        assert m["fp_lesions"] <= 1
        assert m["ece"] < 0.1
        assert "high_lesion_load_null_unreliable" not in res["flags"]


def test_control_phantom_is_clean():
    v = phantom.render(phantom.PhantomSpec(seed=9), lesions=False)
    res = lp.detect_array(v["flair"], v["wm"], extra={"brain": v["brain"]})
    assert res["n_final"] == 0 and res["pi0"] > 0.9


def test_tiny_region_flagged_and_parent_shrinkage():
    I, _ = _noise(seed=3)
    Rt = np.zeros(I.shape, bool); Rt[10:13, 10:13, 10:14] = True
    r = lp.detect_array(I, Rt)
    assert "small_region_low_confidence" in r["flags"] and r["n_final"] == 0
    r2 = lp.detect_array(I, Rt, parent_null=(100.0, 10.0))
    assert r2["null_source"].startswith("shrunk_to_parent")
    Rn = np.zeros(I.shape, bool); Rn[10:12, 10:12, 10:12] = True    # 8 voxels < min_null
    r3 = lp.detect_array(I, Rn)
    assert "too_few_voxels" in r3["flags"] and r3["n_final"] == 0


def test_mrf_and_cluster_filter_on_isolated_voxel():
    """The mean-field prior pulls an isolated, moderately bright voxel DOWN
    (its six neighbours are all null) and leaves a compact lesion intact; a
    lone voxel that still survives is removed by the default cluster filter."""
    I0, R = _noise(seed=4)
    I0[8:11, 8:11, 8:11] += 45                              # a 27-voxel lesion
    I0[15, 15, 15] = 100.0                                  # reset the target voxel to the null mean
    chosen = None
    for boost in (24, 27, 30, 33, 36):
        I = I0.copy(); I[15, 15, 15] += boost
        r_no = lp.detect_array(I, R, beta=0.0, min_cluster=1, cluster_post=0.0)
        if 0.3 <= r_no["posterior"][15, 15, 15] <= 0.95:
            chosen = (I, r_no)
            break
    assert chosen is not None, "no boost gave an intermediate posterior"
    I, r_no = chosen
    r_mrf = lp.detect_array(I, R, beta=0.8, min_cluster=1, cluster_post=0.0)
    assert r_mrf["posterior"][15, 15, 15] < 0.5 * r_no["posterior"][15, 15, 15]
    assert r_mrf["mask"][8:11, 8:11, 8:11].sum() >= 20      # the real lesion survives
    r_def = lp.detect_array(I, R)                           # default config: min_cluster=3
    assert not r_def["mask"][15, 15, 15]
    assert r_def["mask"][8:11, 8:11, 8:11].sum() >= 20


def test_high_lesion_load_flag():
    I, R = _noise(seed=5)
    I[R] = np.where(np.random.default_rng(6).random(int(R.sum())) < 0.45, I[R] + 40, I[R])   # ~45 % of the region abnormal (bimodal)
    r = lp.detect_array(I, R)
    assert "high_lesion_load_null_unreliable" in r["flags"]


def test_t2_channel_and_trend():
    v = phantom.render(phantom.PhantomSpec(seed=8, n_lesions=4, brainstem_lesions=0, bias_amplitude=0.3))
    res = lp.detect_array(v["flair"], v["wm"], extra={"brain": v["brain"], "t2": v["flair"] * 0.9 + 0.01}, trend_degree=2, trend_min_n=1000)
    assert res["null_source"].startswith("region+trend2") and res["null_source"].endswith("+t2")
    m = metrics.evaluate(res["mask"], v["gt"] & v["wm"].astype(bool), (1, 1, 1), eval_mask=v["wm"])
    assert m["lesion_tpr"] == 1.0


def test_cli_outputs(tmp_path):
    v = phantom.render(phantom.PhantomSpec(seed=2, n_lesions=3, brainstem_lesions=1))
    aff = np.eye(4)
    fl = str(tmp_path / "flair.nii.gz"); nib.save(nib.Nifti1Image(v["flair"], aff), fl)
    rg = str(tmp_path / "bs.nii.gz"); nib.save(nib.Nifti1Image(v["brainstem"], aff), rg)
    br = str(tmp_path / "brain.nii.gz"); nib.save(nib.Nifti1Image(v["brain"], aff), br)
    pre = str(tmp_path / "out" / "pons")
    script = os.path.join(os.path.dirname(__file__), "..", "src", "modules", "lesion_posterior.py")
    r = subprocess.run([sys.executable, script, "--image", fl, "--region", rg, "--brain", br, "--out-prefix", pre, "--region-name", "pons", "--q", "0.05"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    for suf in ("_posterior.nii.gz", "_lfdr.nii.gz", "_z.nii.gz", "_mask.nii.gz", "_mask_bh.nii.gz", "_params.txt", "_params.json", "_clusters.tsv"):
        assert os.path.isfile(pre + suf), suf
    txt = open(pre + "_params.txt").read()
    for key in ("ENGINE=posterior", "NULL_MEAN=", "NULL_SD=", "PI0=", "THRESHOLD=", "FLAGS=", "N_CLUSTERS="):
        assert key in txt
    assert "THRESHOLD=" in r.stdout
    r2 = subprocess.run([sys.executable, script, "--image", "/nonexistent.nii.gz", "--region", rg, "--out-prefix", pre], capture_output=True, text=True)
    assert r2.returncode == 1 and "lesion_posterior" in r2.stderr
