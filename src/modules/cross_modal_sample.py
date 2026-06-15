#!/usr/bin/env python3
"""cross_modal_sample.py - per-cluster cross-modal corroboration sampling.

Given the PRIMARY FLAIR hyperintensity cluster index volume and one or more
co-registered secondary modalities (already resampled onto the cluster grid),
sample each modality inside every cluster ROI and emit a per-cluster table plus
a corroboration summary.

This is CORROBORATION on top of the primary detection: it never re-detects
lesions and never modifies the primary mask. Each modality is z-scored within
the brainstem ROI (robust mean/SD) so thresholds are scale independent.

Flags (a cluster's per-modality z is its MEAN z over the cluster voxels):
  DWI restriction  : trace z >= DWI_TRACE_Z AND ADC z <= ADC_Z  -> "RESTRICTION"
  SWI hypointensity: SWI z <= SWI_Z                             -> "HEMORRHAGE"
  T2 hyperintensity: T2  z >= T2_Z                              -> "T2_CORROB"

All output goes to the CSV (and a summary file); diagnostics go to stderr.
Exit non-zero only on hard failure (missing/invalid primary inputs).
"""

import argparse
import csv
import sys

import numpy as np

try:
    import nibabel as nib
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(f"cross_modal_sample: nibabel unavailable: {exc}\n")
    sys.exit(2)

# Clinical reading order for the modality columns; only present ones are emitted.
PREFERRED_ORDER = ["T2", "SWI", "DWI", "ADC"]


def log(msg):
    """Write one diagnostic line to stderr (captured in the pipeline log)."""
    sys.stderr.write(f"cross_modal_sample: {msg}\n")


def load(path):
    """Load a NIfTI as a float64 ndarray."""
    img = nib.load(path)
    return np.asanyarray(img.dataobj).astype(np.float64)


def robust_stats(values):
    """Return (mean, sd) over finite values; sd floored to avoid /0."""
    finite = values[np.isfinite(values)]
    if finite.size == 0:
        return 0.0, 1.0
    mean = float(np.mean(finite))
    sd = float(np.std(finite))
    if not np.isfinite(sd) or sd < 1e-6:
        sd = 1.0
    return mean, sd


def parse_modspec(spec):
    """Parse 'NAME:/path/to.nii.gz' into ('NAME', '/path/to.nii.gz')."""
    name, _, path = spec.partition(":")
    return name.strip().upper(), path.strip()


def build_modality_zmaps(modspecs, clusters_shape, brainstem):
    """Load each present modality and z-score it within the brainstem ROI.

    Returns (mod_z, mod_raw, present) where mod_z/mod_raw are name->ndarray dicts
    aligned to the cluster grid and `present` is the ordered list of usable names.
    Modalities that fail to load or mismatch the cluster grid are skipped.
    """
    mod_z, mod_raw = {}, {}
    for spec in modspecs:
        name, path = parse_modspec(spec)
        if not path:
            continue
        try:
            vol = load(path)
        except (OSError, ValueError, nib.filebasedimages.ImageFileError) as exc:
            log(f"skipping {name}: load failed ({exc})")
            continue
        if vol.shape != clusters_shape:
            log(f"skipping {name}: shape {vol.shape} != clusters {clusters_shape}")
            continue
        mean, sd = robust_stats(vol[brainstem])
        mod_z[name] = (vol - mean) / sd
        mod_raw[name] = vol
        log(f"{name}: brainstem mean={mean:.3f} sd={sd:.3f}")

    present = [m for m in PREFERRED_ORDER if m in mod_z]
    present += [m for m in mod_z if m not in present]
    return mod_z, mod_raw, present


def flag_cluster(zmean, row, thresholds, counts):
    """Apply the corroboration flags for one cluster.

    Mutates `row` (per-modality *_flag fields) and `counts`, and returns the
    list of corroboration tags that fired for this cluster.
    """
    corrob = []

    if "T2" in zmean and zmean["T2"] >= thresholds["t2"]:
        row["T2_flag"] = "HYPER"
        corrob.append("T2_CORROB")
        counts["T2_CORROB"] += 1

    if "SWI" in zmean and zmean["SWI"] <= thresholds["swi"]:
        row["SWI_flag"] = "HYPO"
        corrob.append("SWI_HEMORRHAGE")
        counts["SWI_HEMORRHAGE"] += 1

    if "DWI" in zmean and "ADC" in zmean:
        trace_up = zmean["DWI"] >= thresholds["dwi"]
        adc_down = zmean["ADC"] <= thresholds["adc"]
        if trace_up and adc_down:
            row["DWI_flag"] = "RESTRICT"
            row["ADC_flag"] = "LOW"
            corrob.append("DWI_RESTRICTION")
            counts["DWI_RESTRICTION"] += 1
        else:
            if trace_up:
                row["DWI_flag"] = "HIGH"
            if adc_down:
                row["ADC_flag"] = "LOW"
    elif "DWI" in zmean and zmean["DWI"] >= thresholds["dwi"]:
        # Trace present without ADC: report elevation, cannot confirm restriction.
        row["DWI_flag"] = "HIGH"

    return corrob


def build_row(lab, roi, vols, mods):
    """Assemble the base per-cluster row (id, geometry, intensities + z).

    `vols` is (flair, flair_z); `mods` is (mod_z, mod_raw, present).
    """
    flair, flair_z = vols
    mod_z, mod_raw, present = mods
    idx = np.argwhere(roi)
    cog = idx.mean(axis=0)
    row = {
        "cluster_id": int(lab),
        "n_voxels": int(idx.shape[0]),
        "cog_x": round(float(cog[0]), 1),
        "cog_y": round(float(cog[1]), 1),
        "cog_z": round(float(cog[2]), 1),
        "flair_mean": round(float(np.mean(flair[roi])), 3),
        "flair_z": round(float(np.mean(flair_z[roi])), 3),
    }
    zmean = {}
    for mod in present:
        mz = float(np.mean(mod_z[mod][roi]))
        zmean[mod] = mz
        row[f"{mod}_mean"] = round(float(np.mean(mod_raw[mod][roi])), 3)
        row[f"{mod}_z"] = round(mz, 3)
        row[f"{mod}_flag"] = ""
    return row, zmean


def build_header(present):
    """Build the CSV header columns for the present modalities."""
    header = ["cluster_id", "n_voxels", "cog_x", "cog_y", "cog_z",
              "flair_mean", "flair_z"]
    for mod in present:
        header += [f"{mod}_mean", f"{mod}_z", f"{mod}_flag"]
    header += ["corroboration", "n_corroborating"]
    return header


def sample_clusters(clusters, vols, mods, params):
    """Sample every cluster ROI and return (rows, counts).

    `vols` is (flair, flair_z); `mods` is (mod_z, mod_raw, present);
    `params` is (thresholds, min_voxels).
    """
    thresholds, min_voxels = params
    counts = {"clusters_total": 0, "clusters_reported": 0,
              "DWI_RESTRICTION": 0, "SWI_HEMORRHAGE": 0, "T2_CORROB": 0,
              "any_corroboration": 0}
    rows = []
    for lab in np.unique(clusters[clusters > 0]).astype(int):
        counts["clusters_total"] += 1
        roi = clusters == lab
        if int(np.count_nonzero(roi)) < min_voxels:
            continue
        counts["clusters_reported"] += 1
        row, zmean = build_row(lab, roi, vols, mods)
        corrob = flag_cluster(zmean, row, thresholds, counts)
        row["corroboration"] = ";".join(corrob) if corrob else "NONE"
        row["n_corroborating"] = len(corrob)
        if corrob:
            counts["any_corroboration"] += 1
        rows.append(row)
    return rows, counts


def write_outputs(paths, header, rows, summary_ctx):
    """Write the per-cluster CSV table and the corroboration summary file.

    `paths` is (out_csv, out_summary); `summary_ctx` is (present, counts,
    min_voxels).
    """
    out_csv, out_summary = paths
    present, counts, min_voxels = summary_ctx
    with open(out_csv, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=header)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in header})
    log(f"wrote per-cluster table: {out_csv} ({len(rows)} row(s))")

    with open(out_summary, "w", encoding="utf-8") as fh:
        fh.write("Cross-modal corroboration summary\n")
        fh.write("=================================\n")
        fh.write(f"Modalities sampled: {', '.join(present) if present else '(none)'}\n")
        fh.write(f"Clusters total: {counts['clusters_total']}\n")
        fh.write(f"Clusters reported (>= {min_voxels} voxels): "
                 f"{counts['clusters_reported']}\n")
        fh.write(f"Clusters with ANY corroboration: {counts['any_corroboration']}\n")
        fh.write(f"  DWI restriction (acute/ischemic): {counts['DWI_RESTRICTION']}\n")
        fh.write(f"  SWI hypointensity (hemorrhage):   {counts['SWI_HEMORRHAGE']}\n")
        fh.write(f"  T2 hyperintensity (corroborates): {counts['T2_CORROB']}\n")
    log(f"wrote summary: {out_summary}")


def parse_args():
    """Parse CLI arguments."""
    ap = argparse.ArgumentParser(description="Per-cluster cross-modal sampling")
    ap.add_argument("clusters", help="cluster index NIfTI (integer labels)")
    ap.add_argument("brainstem", help="brainstem mask NIfTI (ROI for z-scoring)")
    ap.add_argument("flair", help="FLAIR intensity NIfTI (analysis space)")
    ap.add_argument("--modality", action="append", default=[],
                    help="NAME:path of a co-registered modality (repeatable)")
    ap.add_argument("--out-csv", required=True)
    ap.add_argument("--out-summary", required=True)
    ap.add_argument("--min-voxels", type=int, default=5)
    ap.add_argument("--dwi-trace-z", type=float, default=1.0)
    ap.add_argument("--adc-z", type=float, default=-1.0)
    ap.add_argument("--swi-z", type=float, default=-1.5)
    ap.add_argument("--t2-z", type=float, default=1.0)
    return ap.parse_args()


def load_brainstem(path, flair):
    """Return the boolean ROI mask used for per-modality z-scoring.

    Normally the brainstem segmentation. When `path` is the sentinel "NONE"/""
    or fails to load, fall back to the nonzero-FLAIR (brain) extent rather than
    the cluster voxels or the whole padded volume — z-scoring over background
    zeros or over only the lesion voxels would make the z-scores degenerate.
    """
    if path and path.upper() != "NONE":
        try:
            return load(path) > 0.5
        except (OSError, ValueError, nib.filebasedimages.ImageFileError) as exc:
            log(f"could not load brainstem mask ({exc}); using nonzero-FLAIR ROI")
    else:
        log("no brainstem mask supplied; using nonzero-FLAIR ROI for z-scoring")
    roi = np.isfinite(flair) & (flair != 0)
    if not roi.any():
        roi = np.ones_like(flair, dtype=bool)
    return roi


def main():
    """Sample co-registered modalities over the primary clusters; emit table."""
    args = parse_args()
    thresholds = {"dwi": args.dwi_trace_z, "adc": args.adc_z,
                  "swi": args.swi_z, "t2": args.t2_z}

    clusters = load(args.clusters)
    flair = load(args.flair)
    brainstem = load_brainstem(args.brainstem, flair)

    if clusters.shape != flair.shape:
        log(f"shape mismatch clusters {clusters.shape} vs flair {flair.shape}")
        sys.exit(3)

    mods = build_modality_zmaps(args.modality, clusters.shape, brainstem)
    present = mods[2]

    f_mean, f_sd = robust_stats(flair[brainstem])
    vols = (flair, (flair - f_mean) / f_sd)

    log(f"sampling {len(present)} modality column(s): {present}")
    rows, counts = sample_clusters(
        clusters, vols, mods, (thresholds, args.min_voxels))

    write_outputs((args.out_csv, args.out_summary), build_header(present), rows,
                  (present, counts, args.min_voxels))

    # Compact key=value block on stdout for the bash caller to log.
    print(f"modalities={','.join(present)}")
    print(f"clusters_reported={counts['clusters_reported']}")
    print(f"any_corroboration={counts['any_corroboration']}")
    print(f"dwi_restriction={counts['DWI_RESTRICTION']}")
    print(f"swi_hemorrhage={counts['SWI_HEMORRHAGE']}")
    print(f"t2_corroboration={counts['T2_CORROB']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
