#!/usr/bin/env python3
"""
Unit tests for gmm_threshold.py

Tests the GMM-based adaptive threshold estimation used for per-region
hyperintensity detection in the analysis pipeline (stage 6).

Run:
    python3 -m pytest tests/test_gmm_threshold.py -v
    python3 tests/test_gmm_threshold.py              # standalone
"""

import os
import subprocess
import sys

import nibabel as nib
import numpy as np
import pytest

# Add src/modules to path so we can import directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "modules"))

from gmm_threshold import (
    DEFAULTS,
    compute_adaptive_threshold,
    extract_values,
    fit_gmm,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_nifti(data, affine=None, tmpdir=None):
    """Create a temporary NIfTI file from a numpy array."""
    if affine is None:
        affine = np.eye(4)
    img = nib.Nifti1Image(data.astype(np.float32), affine)
    path = os.path.join(tmpdir, f"tmp_{id(data)}.nii.gz")
    nib.save(img, path)
    return path


def make_bimodal_region(shape=(20, 20, 20), n_hot=50, seed=42):
    """Create z-score image with a clear bimodal distribution inside a mask.

    Most voxels are drawn from N(0, 1) (normal tissue).
    A small number are drawn from N(4, 0.5) (hyperintense).
    """
    rng = np.random.RandomState(seed)
    zscore = rng.randn(*shape)  # background N(0,1)

    # Create a cubic mask in the centre
    mask = np.zeros(shape, dtype=np.float32)
    mask[5:15, 5:15, 5:15] = 1.0

    # Inject hyperintense voxels at random positions inside the mask
    hot_coords = np.argwhere(mask > 0)
    chosen = rng.choice(len(hot_coords), size=min(n_hot, len(hot_coords)), replace=False)
    for idx in chosen:
        x, y, z = hot_coords[idx]
        zscore[x, y, z] = rng.normal(4.0, 0.5)

    return zscore.astype(np.float32), mask


def default_cfg(**overrides):
    """Return a copy of DEFAULTS with optional overrides."""
    cfg = dict(DEFAULTS)
    cfg.update(overrides)
    return cfg


# ---------------------------------------------------------------------------
# extract_values
# ---------------------------------------------------------------------------

class TestExtractValues:
    """Tests for NIfTI-based voxel extraction."""

    def test_basic_extraction(self, tmp_path):
        """Extracts finite non-zero values within the mask."""
        data = np.array([[[0, 1, 2], [3, 0, 5]], [[6, 7, 0], [9, 10, 11]]], dtype=np.float32)
        mask = np.array([[[0, 1, 1], [1, 0, 1]], [[1, 1, 0], [1, 1, 1]]], dtype=np.float32)

        zscore_path = make_nifti(data, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        values = extract_values(zscore_path, mask_path)
        # Should include non-zero values where mask > 0.5
        assert len(values) > 0
        assert 0.0 not in values  # zeros filtered out

    def test_shape_mismatch_raises(self, tmp_path):
        """Raises ValueError when shapes don't match."""
        data = np.zeros((10, 10, 10), dtype=np.float32)
        mask = np.zeros((5, 5, 5), dtype=np.float32)

        zscore_path = make_nifti(data, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        with pytest.raises(ValueError, match="Shape mismatch"):
            extract_values(zscore_path, mask_path)

    def test_nan_and_inf_filtered(self, tmp_path):
        """NaN and Inf values are excluded."""
        data = np.array([[[1.0, np.nan, np.inf], [2.0, -np.inf, 3.0]]], dtype=np.float32)
        mask = np.ones_like(data, dtype=np.float32)

        zscore_path = make_nifti(data, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        values = extract_values(zscore_path, mask_path)
        assert np.all(np.isfinite(values))

    def test_empty_mask_returns_empty(self, tmp_path):
        """All-zero mask produces empty values array."""
        data = np.ones((5, 5, 5), dtype=np.float32)
        mask = np.zeros((5, 5, 5), dtype=np.float32)

        zscore_path = make_nifti(data, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        values = extract_values(zscore_path, mask_path)
        assert len(values) == 0


# ---------------------------------------------------------------------------
# compute_adaptive_threshold
# ---------------------------------------------------------------------------

class TestComputeAdaptiveThreshold:
    """Tests for threshold computation from GMM component parameters."""

    def test_two_component_uses_sd_2comp(self):
        """2-component model: threshold = upper_mean + sd_2comp * upper_std."""
        cfg = default_cfg(sd_2comp=1.0)
        means = np.array([0.0, 3.0])
        stds = np.array([1.0, 0.5])
        weights = np.array([0.8, 0.2])  # weight >= 0.15 → no adjustment
        threshold, umean, ustd, uweight = compute_adaptive_threshold(means, stds, weights, 2, cfg)
        assert umean == pytest.approx(3.0)
        assert ustd == pytest.approx(0.5)
        assert threshold == pytest.approx(3.0 + 1.0 * 0.5)

    def test_three_component_uses_sd_3comp(self):
        """3-component model: threshold = upper_mean + sd_3comp * upper_std."""
        cfg = default_cfg(sd_3comp=1.5)
        means = np.array([-1.0, 0.0, 4.0])
        stds = np.array([1.0, 1.0, 0.5])
        weights = np.array([0.2, 0.6, 0.2])
        threshold, _, _, _ = compute_adaptive_threshold(means, stds, weights, 3, cfg)
        assert threshold == pytest.approx(4.0 + 1.5 * 0.5)

    def test_small_weight_uses_conservative_sd(self):
        """Weight < small_weight_cutoff → conservative: upper_mean + small_weight_sd * upper_std."""
        cfg = default_cfg(small_weight_cutoff=0.05, small_weight_sd=2.5)
        means = np.array([0.0, 5.0])
        stds = np.array([1.0, 0.5])
        weights = np.array([0.97, 0.03])  # upper weight < 0.05
        threshold, _, _, _ = compute_adaptive_threshold(means, stds, weights, 2, cfg)
        assert threshold == pytest.approx(5.0 + 2.5 * 0.5)

    def test_moderate_weight_uses_moderate_sd(self):
        """Weight between small and moderate cutoffs → moderate multiplier."""
        cfg = default_cfg(moderate_weight_cutoff=0.15, moderate_weight_sd=2.0)
        means = np.array([0.0, 5.0])
        stds = np.array([1.0, 0.5])
        weights = np.array([0.9, 0.1])  # 0.05 <= weight < 0.15
        threshold, _, _, _ = compute_adaptive_threshold(means, stds, weights, 2, cfg)
        assert threshold == pytest.approx(5.0 + 2.0 * 0.5)

    def test_custom_sd_overrides(self):
        """Custom SD multipliers are respected."""
        cfg = default_cfg(sd_2comp=3.0)
        means = np.array([0.0, 2.0])
        stds = np.array([1.0, 1.0])
        weights = np.array([0.5, 0.5])  # above moderate cutoff
        threshold, _, _, _ = compute_adaptive_threshold(means, stds, weights, 2, cfg)
        assert threshold == pytest.approx(2.0 + 3.0 * 1.0)

    def test_custom_weight_cutoffs(self):
        """Custom weight cutoffs shift the conservative/moderate boundaries."""
        # With cutoff=0.2, a weight of 0.15 now triggers moderate
        cfg = default_cfg(moderate_weight_cutoff=0.2, moderate_weight_sd=4.0)
        means = np.array([0.0, 3.0])
        stds = np.array([1.0, 0.5])
        weights = np.array([0.85, 0.15])  # 0.05 <= 0.15 < 0.2 → moderate
        threshold, _, _, _ = compute_adaptive_threshold(means, stds, weights, 2, cfg)
        assert threshold == pytest.approx(3.0 + 4.0 * 0.5)


# ---------------------------------------------------------------------------
# fit_gmm (end-to-end with NIfTI files)
# ---------------------------------------------------------------------------

class TestFitGmm:
    """End-to-end tests using synthetic NIfTI volumes."""

    def test_bimodal_detection(self, tmp_path, capsys):
        """GMM detects a hyperintense subpopulation and emits a threshold."""
        zscore, mask = make_bimodal_region(shape=(20, 20, 20), n_hot=80, seed=42)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        exit_code = fit_gmm(zscore_path, mask_path, default_cfg())
        assert exit_code == 0

        stdout = capsys.readouterr().out
        assert "THRESHOLD=" in stdout

        # Parse threshold — should be a reasonable positive number
        for line in stdout.strip().split("\n"):
            if line.startswith("THRESHOLD="):
                threshold = float(line.split("=")[1])
                assert 1.0 < threshold < 10.0, f"Threshold {threshold} out of expected range"
                break
        else:
            pytest.fail("No THRESHOLD line in stdout")

    def test_uniform_region_no_crash(self, tmp_path, capsys):
        """Uniform intensity region (no hyperintensities) still produces a threshold."""
        rng = np.random.RandomState(99)
        zscore = rng.randn(15, 15, 15).astype(np.float32)
        mask = np.zeros((15, 15, 15), dtype=np.float32)
        mask[3:12, 3:12, 3:12] = 1.0

        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        exit_code = fit_gmm(zscore_path, mask_path, default_cfg())
        assert exit_code in (0, 1)

        stdout = capsys.readouterr().out
        assert "THRESHOLD=" in stdout

    def test_too_few_voxels_uses_fallback_threshold(self, tmp_path, capsys):
        """Fewer than min_voxels → fallback threshold from config."""
        zscore = np.ones((5, 5, 5), dtype=np.float32) * 2.0
        mask = np.zeros((5, 5, 5), dtype=np.float32)
        mask[1:3, 1:3, 1:3] = 1.0  # 8 voxels

        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        cfg = default_cfg(fallback_threshold=3.14)
        exit_code = fit_gmm(zscore_path, mask_path, cfg)
        assert exit_code == 1

        stdout = capsys.readouterr().out
        assert "GMM_FAILED=true" in stdout
        assert "THRESHOLD=3.140000" in stdout

    def test_output_keys_complete(self, tmp_path, capsys):
        """Successful run emits all expected key=value pairs."""
        zscore, mask = make_bimodal_region(shape=(20, 20, 20), n_hot=80, seed=123)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        exit_code = fit_gmm(zscore_path, mask_path, default_cfg())
        assert exit_code == 0

        stdout = capsys.readouterr().out
        keys = {line.split("=")[0] for line in stdout.strip().split("\n") if "=" in line}
        expected_keys = {
            "THRESHOLD", "GMM_COMPONENTS", "N_VOXELS",
            "UPPER_MEAN", "UPPER_STD", "UPPER_WEIGHT",
            "MIN_THRESHOLD", "DATA_RANGE",
        }
        assert expected_keys.issubset(keys), f"Missing keys: {expected_keys - keys}"

    def test_floor_percentile_respected(self, tmp_path, capsys):
        """Threshold is never below the configured floor percentile."""
        zscore, mask = make_bimodal_region(shape=(20, 20, 20), n_hot=80, seed=77)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        fit_gmm(zscore_path, mask_path, default_cfg())

        stdout = capsys.readouterr().out
        threshold = None
        min_threshold = None
        for line in stdout.strip().split("\n"):
            if line.startswith("THRESHOLD="):
                threshold = float(line.split("=")[1])
            if line.startswith("MIN_THRESHOLD="):
                min_threshold = float(line.split("=")[1])

        if threshold is not None and min_threshold is not None:
            assert threshold >= min_threshold

    def test_custom_floor_percentile(self, tmp_path, capsys):
        """A high floor percentile forces the threshold up."""
        zscore, mask = make_bimodal_region(shape=(20, 20, 20), n_hot=80, seed=42)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        # Run with default floor (95th percentile)
        fit_gmm(zscore_path, mask_path, default_cfg(floor_percentile=95))
        out_95 = capsys.readouterr().out

        # Run with very high floor (99.9th percentile)
        fit_gmm(zscore_path, mask_path, default_cfg(floor_percentile=99.9))
        out_999 = capsys.readouterr().out

        t_95 = float([l for l in out_95.split("\n") if l.startswith("THRESHOLD=")][0].split("=")[1])
        t_999 = float([l for l in out_999.split("\n") if l.startswith("THRESHOLD=")][0].split("=")[1])

        assert t_999 >= t_95, "Higher floor percentile should produce higher or equal threshold"

    def test_min_voxels_configurable(self, tmp_path, capsys):
        """Raising min_voxels causes regions that previously fit to fallback."""
        zscore, mask = make_bimodal_region(shape=(10, 10, 10), n_hot=20, seed=42)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        # Should succeed with default min_voxels=20
        code1 = fit_gmm(zscore_path, mask_path, default_cfg(min_voxels=20))
        out1 = capsys.readouterr().out

        # Should fallback with min_voxels=99999
        code2 = fit_gmm(zscore_path, mask_path, default_cfg(min_voxels=99999))
        out2 = capsys.readouterr().out

        assert "GMM_FAILED" not in out1 or code1 == 0  # either way, not forced to fail
        assert "GMM_FAILED=true" in out2
        assert code2 == 1


# ---------------------------------------------------------------------------
# CLI integration test
# ---------------------------------------------------------------------------

class TestCLI:
    """Tests running gmm_threshold.py as a subprocess (how analysis.sh calls it)."""

    @staticmethod
    def _script_path():
        return os.path.join(
            os.path.dirname(__file__), "..", "src", "modules", "gmm_threshold.py"
        )

    def test_cli_success(self, tmp_path):
        """CLI invocation produces key=value on stdout, diagnostics on stderr."""
        zscore, mask = make_bimodal_region(shape=(20, 20, 20), n_hot=80, seed=42)
        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        result = subprocess.run(
            [sys.executable, self._script_path(), zscore_path, mask_path],
            capture_output=True, text=True, timeout=30,
        )

        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert "THRESHOLD=" in result.stdout
        # Diagnostics should be on stderr, not stdout
        assert "Processing" in result.stderr or "component" in result.stderr.lower()
        # stdout should only have KEY=VALUE lines
        for line in result.stdout.strip().split("\n"):
            assert "=" in line, f"Non key=value line on stdout: {line!r}"

    def test_cli_passes_config_params(self, tmp_path):
        """CLI args are respected (e.g., custom fallback-threshold)."""
        zscore = np.ones((5, 5, 5), dtype=np.float32) * 2.0
        mask = np.zeros((5, 5, 5), dtype=np.float32)
        mask[1:3, 1:3, 1:3] = 1.0  # 8 voxels — too few → fallback

        zscore_path = make_nifti(zscore, tmpdir=str(tmp_path))
        mask_path = make_nifti(mask, tmpdir=str(tmp_path))

        result = subprocess.run(
            [sys.executable, self._script_path(), zscore_path, mask_path,
             "--fallback-threshold", "7.77"],
            capture_output=True, text=True, timeout=30,
        )

        assert "THRESHOLD=7.770000" in result.stdout
        assert "GMM_FAILED=true" in result.stdout

    def test_cli_missing_file(self, tmp_path):
        """CLI with nonexistent file exits non-zero and still emits THRESHOLD."""
        result = subprocess.run(
            [sys.executable, self._script_path(),
             "/nonexistent.nii.gz", "/also_missing.nii.gz"],
            capture_output=True, text=True, timeout=30,
        )

        assert result.returncode != 0
        assert "THRESHOLD=" in result.stdout

    def test_cli_no_args(self):
        """CLI with no arguments exits non-zero."""
        result = subprocess.run(
            [sys.executable, self._script_path()],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0

    def test_cli_help_shows_all_params(self):
        """--help lists all configurable GMM parameters."""
        result = subprocess.run(
            [sys.executable, self._script_path(), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0
        for param in ["--max-components", "--min-voxels", "--sd-2comp", "--sd-3comp",
                       "--small-weight-cutoff", "--moderate-weight-cutoff",
                       "--floor-percentile", "--fallback-threshold"]:
            assert param in result.stdout, f"Missing param in help: {param}"


# ---------------------------------------------------------------------------
# Config / defaults consistency
# ---------------------------------------------------------------------------

class TestDefaults:
    """Verify DEFAULTS dict is complete and consistent."""

    def test_all_cfg_keys_present(self):
        """DEFAULTS has all keys used by fit_gmm and compute_adaptive_threshold."""
        required_keys = {
            "max_components", "min_voxels", "voxels_per_component",
            "sd_2comp", "sd_3comp",
            "small_weight_cutoff", "small_weight_sd",
            "moderate_weight_cutoff", "moderate_weight_sd",
            "floor_percentile", "fallback_percentile", "fallback_threshold",
        }
        assert required_keys == set(DEFAULTS.keys())

    def test_weight_cutoffs_ordered(self):
        """small_weight_cutoff < moderate_weight_cutoff (sanity)."""
        assert DEFAULTS["small_weight_cutoff"] < DEFAULTS["moderate_weight_cutoff"]

    def test_sd_multipliers_positive(self):
        """All SD multipliers are positive."""
        for key in ["sd_2comp", "sd_3comp", "small_weight_sd", "moderate_weight_sd"]:
            assert DEFAULTS[key] > 0, f"{key} should be positive"

    def test_percentiles_in_range(self):
        """Percentile values are between 0 and 100."""
        for key in ["floor_percentile", "fallback_percentile"]:
            assert 0 < DEFAULTS[key] < 100, f"{key} should be in (0, 100)"


# ---------------------------------------------------------------------------
# Standalone runner
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    pytest.main([__file__, "-v"])
