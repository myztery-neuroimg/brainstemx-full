#!/usr/bin/env python3
"""
GMM-based adaptive threshold estimation for hyperintensity detection.

Reads z-score and region mask NIfTI volumes directly, extracts voxel values,
fits a Gaussian Mixture Model, and prints structured results to stdout for
bash to capture — no intermediate files.

All tuning parameters are exposed as CLI arguments.  The defaults match
config/default_config.sh so the script works standalone, but in the pipeline
analysis.sh passes the config values explicitly.

Usage:
    python3 gmm_threshold.py <zscore_image> <region_mask> [options]

Stdout (key=value, one per line — captured by bash via $(...)):
    THRESHOLD=<float>
    GMM_COMPONENTS=<int>
    N_VOXELS=<int>
    UPPER_MEAN=<float>
    UPPER_STD=<float>
    UPPER_WEIGHT=<float>
    MIN_THRESHOLD=<float>
    DATA_RANGE=<min>_<max>

On failure, THRESHOLD is still emitted (fallback) with GMM_FAILED=true.
Diagnostic messages go to stderr so they don't contaminate stdout parsing.

Exit codes:
    0  GMM fit succeeded
    1  GMM fit failed, fallback threshold emitted
    2  Fatal error (no threshold emitted)
"""

import argparse
import sys
import warnings

import nibabel as nib
import numpy as np
from sklearn.mixture import GaussianMixture

warnings.filterwarnings("ignore")


# ---------------------------------------------------------------------------
# Defaults — must match config/default_config.sh GMM_* variables
# ---------------------------------------------------------------------------
DEFAULTS = {
    "max_components": 3,
    "min_voxels": 20,
    "voxels_per_component": 30,
    "sd_2comp": 1.0,
    "sd_3comp": 1.5,
    "small_weight_cutoff": 0.05,
    "small_weight_sd": 2.5,
    "moderate_weight_cutoff": 0.15,
    "moderate_weight_sd": 2.0,
    "floor_percentile": 95.0,
    "fallback_percentile": 97.5,
    "fallback_threshold": 1.5,
}


def log(msg):
    """Diagnostic output to stderr (does not interfere with stdout results)."""
    print(msg, file=sys.stderr)


def emit(**params):
    """Emit key=value pairs on stdout for bash to capture."""
    for key, value in params.items():
        print(f"{key}={value}")


def extract_values(zscore_path, mask_path):
    """Load NIfTI volumes and extract finite non-zero z-scores within mask."""
    zscore_img = nib.load(zscore_path)
    mask_img = nib.load(mask_path)

    zscore_data = zscore_img.get_fdata()
    mask_data = mask_img.get_fdata()

    if zscore_data.shape != mask_data.shape:
        raise ValueError(
            f"Shape mismatch: zscore {zscore_data.shape} vs mask {mask_data.shape}"
        )

    log(f"Z-score image shape: {zscore_data.shape}")
    log(f"Z-score range: [{np.min(zscore_data):.3f}, {np.max(zscore_data):.3f}]")

    # Binarize mask at 0.5 (matches fslmaths -thr 0.5 -bin)
    binary_mask = mask_data > 0.5
    mask_voxels = int(np.sum(binary_mask))
    log(f"Region mask voxels: {mask_voxels}")

    # Extract values within mask
    masked_values = zscore_data[binary_mask]

    # Keep only finite non-zero values
    valid = np.isfinite(masked_values) & (masked_values != 0)
    values = masked_values[valid]

    log(f"Finite non-zero values extracted: {len(values)}")
    return values


def compute_adaptive_threshold(means, stds, weights, n_components, cfg):
    """Compute adaptive threshold from GMM upper-tail component.

    Args:
        means, stds, weights: GMM component parameters
        n_components: number of fitted components
        cfg: dict of threshold parameters (sd_2comp, sd_3comp,
             small_weight_cutoff, small_weight_sd,
             moderate_weight_cutoff, moderate_weight_sd)
    """
    sort_idx = np.argsort(means)
    upper_idx = sort_idx[-1]
    upper_mean = float(means[upper_idx])
    upper_std = float(stds[upper_idx])
    upper_weight = float(weights[upper_idx])

    # Base threshold depends on model complexity
    if n_components == 2:
        threshold = upper_mean + cfg["sd_2comp"] * upper_std
    else:
        threshold = upper_mean + cfg["sd_3comp"] * upper_std

    # Smaller hyperintense population → more conservative threshold
    if upper_weight < cfg["small_weight_cutoff"]:
        threshold = upper_mean + cfg["small_weight_sd"] * upper_std
        log("Small hyperintense component detected, using conservative threshold")
    elif upper_weight < cfg["moderate_weight_cutoff"]:
        threshold = upper_mean + cfg["moderate_weight_sd"] * upper_std
        log("Small hyperintense component, using moderate threshold")

    return threshold, upper_mean, upper_std, upper_weight


def fit_gmm(zscore_path, mask_path, cfg):
    """Extract voxels, fit GMM, emit threshold parameters to stdout.

    Args:
        zscore_path: path to z-score NIfTI image
        mask_path: path to binary region mask NIfTI
        cfg: dict of all GMM parameters (from CLI args / config)
    """
    values = extract_values(zscore_path, mask_path)

    if len(values) < cfg["min_voxels"]:
        log(f"Insufficient voxels for GMM: {len(values)} (need {cfg['min_voxels']})")
        emit(
            THRESHOLD=f"{cfg['fallback_threshold']:.6f}",
            N_VOXELS=len(values),
            GMM_FAILED="true",
        )
        return 1

    log(f"Processing {len(values)} z-score values")
    log(f"Value range: {np.min(values):.3f} to {np.max(values):.3f}")

    values_2d = values.reshape(-1, 1)

    # Adaptive component count: fewer for sparse data
    n_components = min(
        cfg["max_components"],
        max(2, len(values) // cfg["voxels_per_component"]),
    )
    log(f"Using {n_components}-component GMM")

    try:
        gmm = GaussianMixture(
            n_components=n_components, random_state=42, max_iter=200
        )
        gmm.fit(values_2d)
    except Exception as e:
        log(f"GMM fitting failed: {e}")
        return _emit_fallback(values, cfg)

    means = gmm.means_.flatten()
    stds = np.sqrt(gmm.covariances_.flatten())
    weights = gmm.weights_
    sort_idx = np.argsort(means)

    log(f"Component means: {[f'{m:.3f}' for m in means[sort_idx]]}")
    log(f"Component weights: {[f'{w:.3f}' for w in weights[sort_idx]]}")

    threshold, upper_mean, upper_std, upper_weight = compute_adaptive_threshold(
        means, stds, weights, n_components, cfg
    )
    log(
        f"Upper component: mean={upper_mean:.3f}, std={upper_std:.3f}, "
        f"weight={upper_weight:.3f}"
    )

    # Floor: never go below configured percentile of the data
    min_threshold = float(np.percentile(values, cfg["floor_percentile"]))
    threshold = max(threshold, min_threshold)

    emit(
        THRESHOLD=f"{threshold:.6f}",
        GMM_COMPONENTS=n_components,
        N_VOXELS=len(values),
        UPPER_MEAN=f"{upper_mean:.6f}",
        UPPER_STD=f"{upper_std:.6f}",
        UPPER_WEIGHT=f"{upper_weight:.6f}",
        MIN_THRESHOLD=f"{min_threshold:.6f}",
        DATA_RANGE=f"{np.min(values):.3f}_{np.max(values):.3f}",
    )

    log(
        f"Final GMM threshold: {threshold:.3f} "
        f"(weight: {upper_weight:.3f}, components: {n_components})"
    )
    return 0


def _emit_fallback(values, cfg):
    """Emit fallback threshold when GMM fitting fails."""
    if len(values) > 10:
        fallback = float(np.percentile(values, cfg["fallback_percentile"]))
        log(f"Using data-driven fallback threshold: {fallback:.3f}")
    else:
        fallback = cfg["fallback_threshold"]
        log(f"Using config fallback threshold: {fallback}")

    emit(
        THRESHOLD=f"{fallback:.6f}",
        GMM_FAILED="true",
        N_VOXELS=len(values),
    )
    return 1


def build_parser():
    """Build argument parser with defaults matching config/default_config.sh."""
    d = DEFAULTS
    parser = argparse.ArgumentParser(
        description="GMM-based adaptive threshold for hyperintensity detection"
    )
    parser.add_argument("zscore_image", help="Z-score NIfTI image (.nii.gz)")
    parser.add_argument("region_mask", help="Binary region mask NIfTI (.nii.gz)")

    g = parser.add_argument_group(
        "GMM parameters",
        "All values should match config/default_config.sh GMM_* variables",
    )
    g.add_argument("--max-components", type=int, default=d["max_components"],
                    help=f"Max GMM components (default: {d['max_components']})")
    g.add_argument("--min-voxels", type=int, default=d["min_voxels"],
                    help=f"Min voxels for GMM fit (default: {d['min_voxels']})")
    g.add_argument("--voxels-per-component", type=int, default=d["voxels_per_component"],
                    help=f"Adaptive component ratio (default: {d['voxels_per_component']})")
    g.add_argument("--sd-2comp", type=float, default=d["sd_2comp"],
                    help=f"SD multiplier for 2-component model (default: {d['sd_2comp']})")
    g.add_argument("--sd-3comp", type=float, default=d["sd_3comp"],
                    help=f"SD multiplier for 3-component model (default: {d['sd_3comp']})")
    g.add_argument("--small-weight-cutoff", type=float, default=d["small_weight_cutoff"],
                    help=f"Weight cutoff for conservative mode (default: {d['small_weight_cutoff']})")
    g.add_argument("--small-weight-sd", type=float, default=d["small_weight_sd"],
                    help=f"SD multiplier in conservative mode (default: {d['small_weight_sd']})")
    g.add_argument("--moderate-weight-cutoff", type=float, default=d["moderate_weight_cutoff"],
                    help=f"Weight cutoff for moderate mode (default: {d['moderate_weight_cutoff']})")
    g.add_argument("--moderate-weight-sd", type=float, default=d["moderate_weight_sd"],
                    help=f"SD multiplier in moderate mode (default: {d['moderate_weight_sd']})")
    g.add_argument("--floor-percentile", type=float, default=d["floor_percentile"],
                    help=f"Threshold floor percentile (default: {d['floor_percentile']})")
    g.add_argument("--fallback-percentile", type=float, default=d["fallback_percentile"],
                    help=f"Data-driven fallback percentile (default: {d['fallback_percentile']})")
    g.add_argument("--fallback-threshold", type=float, default=d["fallback_threshold"],
                    help=f"Hard fallback threshold (default: {d['fallback_threshold']})")
    return parser


def args_to_cfg(args):
    """Convert parsed argparse namespace to config dict."""
    return {
        "max_components": args.max_components,
        "min_voxels": args.min_voxels,
        "voxels_per_component": args.voxels_per_component,
        "sd_2comp": args.sd_2comp,
        "sd_3comp": args.sd_3comp,
        "small_weight_cutoff": args.small_weight_cutoff,
        "small_weight_sd": args.small_weight_sd,
        "moderate_weight_cutoff": args.moderate_weight_cutoff,
        "moderate_weight_sd": args.moderate_weight_sd,
        "floor_percentile": args.floor_percentile,
        "fallback_percentile": args.fallback_percentile,
        "fallback_threshold": args.fallback_threshold,
    }


def main():
    parser = build_parser()
    args = parser.parse_args()
    cfg = args_to_cfg(args)

    try:
        sys.exit(fit_gmm(args.zscore_image, args.region_mask, cfg))
    except Exception as e:
        log(f"GMM analysis failed: {e}")
        import traceback
        traceback.print_exc(file=sys.stderr)
        # Last resort: emit a fallback so bash always gets a threshold
        emit(
            THRESHOLD=f"{cfg['fallback_threshold']:.6f}",
            GMM_FAILED="true",
            N_VOXELS="0",
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
