"""Tests for src/benchmark (phantom, metrics, datasets, adapters, runner, A/B, report)."""

import json
import os
import subprocess
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from benchmark import adapters, datasets, metrics, phantom, runner  # noqa: E402


@pytest.fixture(scope="module")
def phantom_ds(tmp_path_factory):
    root = str(tmp_path_factory.mktemp("phantom"))
    subs = phantom.write_dataset(root, n_lesion=3, n_control=2, seed=11)
    return root, subs


def test_phantom_layout_and_ground_truth(phantom_ds):
    root, subs = phantom_ds
    assert subs == ["sub-001", "sub-002", "sub-003", "sub-004", "sub-005"]
    loaded = datasets.load_subjects("phantom", root)
    assert [s.id for s in loaded] == subs
    assert loaded[0].gt is not None and loaded[-1].gt is None      # controls have no GT
    assert set(loaded[0].masks) >= {"brain", "wm", "brainstem"}
    rec = json.load(open(os.path.join(root, "sub-001", "anat", "sub-001_phantom.json")))
    assert len(rec["lesions"]) >= 3 and any(l["region"] == "brainstem" for l in rec["lesions"])


def test_metrics_perfect_and_empty():
    g = np.zeros((10, 10, 10), bool); g[2:5, 2:5, 2:5] = True
    m = metrics.evaluate(g, g, (1, 1, 1))
    assert m["dice"] == 1.0 and m["lesion_f1"] == 1.0 and m["hd95_mm"] == 0.0 and m["avd_percent"] == 0.0
    e = metrics.evaluate(np.zeros_like(g), g, (1, 1, 1))
    assert e["dice"] == 0.0 and e["lesion_tpr"] == 0.0 and np.isnan(e["hd95_mm"])
    c = metrics.evaluate(np.zeros_like(g), None, (1, 1, 1))
    assert c["control"] == 1.0 and c["fp_volume_mm3"] == 0.0


def test_lesion_wise_counts():
    g = np.zeros((20, 20, 20), bool); g[2:4, 2:4, 2:4] = True; g[10:13, 10:13, 10:13] = True
    p = np.zeros_like(g); p[2:4, 2:4, 2:4] = True; p[16:18, 16:18, 16:18] = True   # one hit, one miss, one FP
    lw = metrics.lesion_wise(p, g)
    assert lw["gt_lesions"] == 2 and lw["detected_lesions"] == 1 and lw["fp_lesions"] == 1
    assert lw["lesion_tpr"] == 0.5 and lw["lesion_ppv"] == 0.5


def test_calibration_and_aggregate():
    g = np.zeros((8, 8, 8), bool); g[:4] = True
    prob = np.where(g, 0.9, 0.1)
    c = metrics.calibration(prob, g)
    assert 0 <= c["ece"] <= 0.2 and c["brier"] < 0.05
    agg = metrics.aggregate([{"dice": 0.5}, {"dice": 0.7}, {"dice": float("nan")}], ["dice"], n_boot=50)
    assert agg["dice"]["n"] == 2 and abs(agg["dice"]["mean"] - 0.6) < 1e-9


def test_paired_compare_direction():
    a = [{"subject": f"s{i}", "dice": 0.5} for i in range(6)]
    b = [{"subject": f"s{i}", "dice": 0.5 + 0.1 * (i + 1)} for i in range(6)]
    p = metrics.paired_compare(a, b, "dice")
    assert p["n"] == 6 and p["mean_diff"] > 0 and p["frac_b_better"] == 1.0 and p["wilcoxon_p"] < 0.05


def test_threshold_adapter_beats_chance_and_controls_are_clean(phantom_ds, tmp_path):
    root, _ = phantom_ds
    s = runner.run("phantom", root, "threshold", "wm", str(tmp_path / "run"), params={"k": "3"})
    assert s["n_lesion_subjects"] == 3 and s["n_controls"] == 2 and s["n_errors"] == 0
    assert s["aggregate_lesion_subjects"]["dice"]["mean"] > 0.5
    assert s["aggregate_lesion_subjects"]["lesion_tpr"]["mean"] > 0.6
    assert os.path.isfile(tmp_path / "run" / "predictions" / "sub-001_pred.nii.gz")
    # a robust z>3 rule on a lesion-free control flags at most a sprinkle of noise voxels
    assert s["aggregate_controls"]["fp_volume_mm3"]["mean"] < 60


def test_legacy_gmm_adapter_runs(phantom_ds, tmp_path):
    root, _ = phantom_ds
    s = runner.run("phantom", root, "legacy_gmm", "brainstem", str(tmp_path / "run"), subjects=["sub-001", "sub-004"])
    assert s["n_errors"] == 0 and s["n_subjects"] == 2
    # the legacy engine's 95th-percentile floor flags voxels even on a control
    assert s["aggregate_controls"]["fp_volume_mm3"]["mean"] > 0


def test_posterior_adapter_absent_is_reported(phantom_ds, tmp_path):
    root, _ = phantom_ds
    if os.path.isfile(os.path.join(os.path.dirname(__file__), "..", "src", "modules", "lesion_posterior.py")):
        pytest.skip("posterior engine present; covered by its own tests")
    s = runner.run("phantom", root, "posterior", "wm", str(tmp_path / "run"), subjects=["sub-001"])
    assert s["n_errors"] == 1


def test_ab_compare_known_report(phantom_ds, tmp_path):
    root, _ = phantom_ds
    a = str(tmp_path / "A"); b = str(tmp_path / "B")
    runner.run("phantom", root, "threshold", "wm", a, params={"k": "2.5"})
    runner.run("phantom", root, "threshold", "wm", b, params={"k": "3.5"})
    res = runner.ab_compare(a, b, str(tmp_path / "ab"))
    assert res["paired"]["dice"]["n"] == 3 and any(v["metric"] == "fp_lesions" for v in res["verdict"])
    assert os.path.isfile(tmp_path / "ab" / "ab_summary.md")
    ck = runner.compare_known(a, "wmh2017")
    assert any(r["metric"] == "dice" and r["this_run"] is not None for r in ck["rows"])
    from benchmark import report

    md = report.write_report(a, str(tmp_path / "ab"))
    text = open(md).read()
    assert "Aggregate (lesion subjects)" in text and "A/B" in text
    assert os.path.isfile(os.path.join(a, "report.html"))


def test_registry_and_fetch_instructions(capsys):
    text = datasets.describe()
    for k in ("ds004199", "wmh2017", "isbi2015", "msseg2016", "phantom"):
        assert k in text
    d = datasets.REGISTRY["wmh2017"]
    assert d.fetch is None and d.access == "agreement"


def test_precomputed_adapter(phantom_ds, tmp_path):
    root, _ = phantom_ds
    subs = datasets.load_subjects("phantom", root, ["sub-001"])
    prob, mask, reg, img = adapters.predict("precomputed", subs[0], "wm", {"pred_pattern": subs[0].gt})
    assert mask is not None and mask.sum() > 0 and prob is None


def test_cli_smoke(tmp_path):
    script = os.path.join(os.path.dirname(__file__), "..", "scripts", "benchmark.py")
    r = subprocess.run([sys.executable, script, "phantom", "--out", str(tmp_path / "ds"), "--n-lesion", "1", "--n-control", "1"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    r = subprocess.run([sys.executable, script, "run", "--dataset", "phantom", "--root", str(tmp_path / "ds"), "--adapter", "threshold", "--region", "wm", "--out", str(tmp_path / "r"), "--no-masks"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert os.path.isfile(tmp_path / "r" / "summary.json")
