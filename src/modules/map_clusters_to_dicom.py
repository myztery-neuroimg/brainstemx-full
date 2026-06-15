#!/usr/bin/env python3
"""map_clusters_to_dicom.py - map hyperintensity clusters to source DICOM slices.

Given a cluster INDEX volume (``clusters.nii.gz``, integer cluster ids on the
native FLAIR grid) and the directory of ORIGINAL source DICOM files, this tool:

  1. Re-derives each cluster's centre-of-gravity (COG) in voxel space directly
     from the index volume (no fragile prose parsing).
  2. Converts the COG voxel -> world millimetres using the NIfTI sform/qform
     affine (the affine dcm2niix wrote, which encodes the scanner geometry).
  3. Flips NIfTI RAS world mm -> DICOM LPS patient mm (negate X and Y).
  4. Matches each cluster to the nearest source DICOM slice using the proper
     slice-normal projection of ImagePositionPatient / ImageOrientationPatient
     (full 3D distance, NOT Z-only), handling nested SE####/IM#### series dirs.
  5. Emits a CSV + human-readable TXT with, per cluster: id, volume (mm3),
     native voxel COG, world mm, DICOM patient mm, matched DICOM file,
     InstanceNumber, SOPInstanceUID, SliceLocation and the match distance.

Coordinate conventions
----------------------
NIfTI affines are RAS+ (x->Right, y->Anterior, z->Superior). DICOM patient
space is LPS (x->Left, y->Posterior, z->Superior). The conversion is therefore
a negation of the first two world axes: ``lps = (-ras_x, -ras_y, ras_z)``.

Dependencies: nibabel, numpy (required); pydicom (required for DICOM matching).
All are declared in pyproject.toml. Missing pydicom is handled gracefully:
coordinates are still emitted, with empty match columns, and the bash caller may
fall back to a dcmdump-based matcher.

Exit codes: 0 success; 2 missing/invalid required inputs or numpy/nibabel.
"""

import argparse
import csv
import os
import sys

try:
    import numpy as np
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(f"map_clusters_to_dicom: numpy unavailable: {exc}\n")
    sys.exit(2)

try:
    import nibabel as nib
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(f"map_clusters_to_dicom: nibabel unavailable: {exc}\n")
    sys.exit(2)

try:
    import pydicom

    HAS_PYDICOM = True
except ImportError:  # pragma: no cover - environment guard
    HAS_PYDICOM = False


def log(msg):
    """Write one diagnostic line to stderr (captured in the pipeline log)."""
    sys.stderr.write(f"map_clusters_to_dicom: {msg}\n")


# --------------------------------------------------------------------------- #
# Cluster geometry (NIfTI side)
# --------------------------------------------------------------------------- #
def cluster_cogs(index_path):
    """Return per-cluster geometry from an integer cluster index volume.

    Yields dicts with: id, n_voxels, volume_mm3, vox (COG voxel ijk),
    world_mm (RAS), dicom_mm (LPS). COG is the mean voxel index of the cluster.
    """
    img = nib.load(index_path)
    data = np.asanyarray(img.dataobj)
    # Round so float resampling residue collapses back onto integer labels.
    labels = np.rint(data).astype(np.int64)
    affine = img.affine  # voxel(ijk,1) -> world RAS mm
    # Per-voxel volume in mm3 from the affine's spatial scaling (det of the
    # 3x3 direction/scale block), robust to anisotropy and obliquity.
    voxel_volume = abs(float(np.linalg.det(affine[:3, :3])))

    out = []
    present = np.unique(labels)
    for cid in present:
        if cid <= 0:
            continue
        ijk = np.argwhere(labels == cid)
        if ijk.size == 0:
            continue
        n_vox = int(ijk.shape[0])
        cog_vox = ijk.mean(axis=0)  # (i, j, k) float
        homog = np.array([cog_vox[0], cog_vox[1], cog_vox[2], 1.0])
        world = affine.dot(homog)[:3]  # RAS mm
        dicom = np.array([-world[0], -world[1], world[2]])  # RAS -> LPS
        out.append(
            {
                "id": int(cid),
                "n_voxels": n_vox,
                "volume_mm3": round(n_vox * voxel_volume, 4),
                "vox": [round(float(v), 4) for v in cog_vox],
                "world_mm": [round(float(v), 4) for v in world],
                "dicom_mm": [round(float(v), 4) for v in dicom],
            }
        )
    out.sort(key=lambda c: c["id"])
    return out


# --------------------------------------------------------------------------- #
# DICOM series side
# --------------------------------------------------------------------------- #
def _is_dicom(path):
    """Cheap DICOM sniff: .dcm extension or the DICM magic at offset 128."""
    low = path.lower()
    if low.endswith((".dcm", ".ima")):
        return True
    try:
        with open(path, "rb") as handle:
            handle.seek(128)
            return handle.read(4) == b"DICM"
    except OSError:
        return False


def _gather_dicom_files(dicom_dir):
    """Recursively collect candidate DICOM file paths (nested SE/IM dirs ok)."""
    found = []
    for root, _dirs, files in os.walk(dicom_dir):
        for name in files:
            path = os.path.join(root, name)
            if _is_dicom(path):
                found.append(path)
    return found


def load_series(dicom_dir):
    """Read DICOM headers and group slices by SeriesInstanceUID.

    Returns a list of series dicts; each has 'description' and 'slices', where a
    slice carries path, ipp (3,), iop (6,), instance_number, sop_uid,
    slice_location.
    """
    if not HAS_PYDICOM:
        log("pydicom unavailable - cannot match clusters to DICOM slices")
        return []

    series = {}
    for path in _gather_dicom_files(dicom_dir):
        try:
            ds = pydicom.dcmread(path, stop_before_pixels=True, force=True)
        except Exception as exc:  # noqa: BLE001 - skip unreadable files
            log(f"skip unreadable DICOM {path}: {exc}")
            continue

        ipp = getattr(ds, "ImagePositionPatient", None)
        iop = getattr(ds, "ImageOrientationPatient", None)
        if ipp is None or iop is None:
            # Without geometry we cannot place the slice; skip it.
            continue
        try:
            ipp = np.array([float(v) for v in ipp], dtype=np.float64)
            iop = np.array([float(v) for v in iop], dtype=np.float64)
        except (TypeError, ValueError):
            continue
        if ipp.shape[0] != 3 or iop.shape[0] != 6:
            continue

        uid = str(getattr(ds, "SeriesInstanceUID", "") or path)
        sl = series.setdefault(
            uid,
            {
                "description": str(getattr(ds, "SeriesDescription", "")),
                "slices": [],
            },
        )
        sl["slices"].append(
            {
                "path": path,
                "ipp": ipp,
                "iop": iop,
                "instance_number": getattr(ds, "InstanceNumber", None),
                "sop_uid": str(getattr(ds, "SOPInstanceUID", "")),
                "slice_location": getattr(ds, "SliceLocation", None),
            }
        )
    return list(series.values())


def match_point(point_lps, series_list):
    """Find the closest DICOM slice (across all series) to an LPS point.

    Returns (best_slice, distance_mm, series_description) or (None, inf, "").
    Distance is the FULL 3D Euclidean distance from the point to the slice
    plane (perpendicular offset along the slice normal), not Z-only.
    """
    best = None
    best_dist = float("inf")
    best_desc = ""
    for series in series_list:
        slices = series["slices"]
        if not slices:
            continue
        # Slice normal = row x column direction cosines (constant per series).
        iop = slices[0]["iop"]
        row, col = iop[:3], iop[3:]
        normal = np.cross(row, col)
        norm = np.linalg.norm(normal)
        if norm < 1e-9:
            continue
        normal = normal / norm
        for sl in slices:
            # Perpendicular distance from the point to this slice's plane.
            dist = abs(float(np.dot(point_lps - sl["ipp"], normal)))
            if dist < best_dist:
                best_dist = dist
                best = sl
                best_desc = series["description"]
    return best, best_dist, best_desc


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
CSV_FIELDS = [
    "ClusterID",
    "Volume_mm3",
    "Voxel_i",
    "Voxel_j",
    "Voxel_k",
    "World_X_mm",
    "World_Y_mm",
    "World_Z_mm",
    "DICOM_X_mm",
    "DICOM_Y_mm",
    "DICOM_Z_mm",
    "DICOM_File",
    "SeriesDescription",
    "InstanceNumber",
    "SOPInstanceUID",
    "SliceLocation",
    "MatchDistance_mm",
    "WithinTolerance",
]


def write_outputs(clusters, series_list, csv_path, txt_path, tolerance):
    """Match every cluster and write the CSV + human-readable TXT report."""
    rows = []
    for cluster in clusters:
        point_lps = np.array(cluster["dicom_mm"], dtype=np.float64)
        best, dist, desc = match_point(point_lps, series_list)
        row = {
            "ClusterID": cluster["id"],
            "Volume_mm3": cluster["volume_mm3"],
            "Voxel_i": cluster["vox"][0],
            "Voxel_j": cluster["vox"][1],
            "Voxel_k": cluster["vox"][2],
            "World_X_mm": cluster["world_mm"][0],
            "World_Y_mm": cluster["world_mm"][1],
            "World_Z_mm": cluster["world_mm"][2],
            "DICOM_X_mm": cluster["dicom_mm"][0],
            "DICOM_Y_mm": cluster["dicom_mm"][1],
            "DICOM_Z_mm": cluster["dicom_mm"][2],
            "DICOM_File": "",
            "SeriesDescription": "",
            "InstanceNumber": "",
            "SOPInstanceUID": "",
            "SliceLocation": "",
            "MatchDistance_mm": "",
            "WithinTolerance": "",
        }
        if best is not None:
            within = dist <= tolerance
            row["DICOM_File"] = os.path.abspath(best["path"])
            row["SeriesDescription"] = desc
            row["InstanceNumber"] = (
                "" if best["instance_number"] is None else str(best["instance_number"])
            )
            row["SOPInstanceUID"] = best["sop_uid"]
            row["SliceLocation"] = (
                "" if best["slice_location"] is None else str(best["slice_location"])
            )
            row["MatchDistance_mm"] = round(dist, 4)
            row["WithinTolerance"] = "yes" if within else "no"
            if not within:
                log(
                    f"cluster {cluster['id']}: nearest slice {dist:.2f} mm "
                    f"exceeds tolerance {tolerance} mm (reported; WithinTolerance=no)"
                )
        else:
            log(f"cluster {cluster['id']}: no DICOM slice available to match")
        rows.append(row)

    os.makedirs(os.path.dirname(os.path.abspath(csv_path)) or ".", exist_ok=True)
    with open(csv_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    with open(txt_path, "w", encoding="utf-8") as handle:
        handle.write("Cluster-to-DICOM mapping\n")
        handle.write("========================\n")
        handle.write(f"Clusters: {len(rows)}\n")
        handle.write(f"Matching tolerance: {tolerance} mm\n\n")
        for row in rows:
            handle.write(f"Cluster {row['ClusterID']} (volume {row['Volume_mm3']} mm3)\n")
            handle.write(
                "  native voxel COG : "
                f"({row['Voxel_i']}, {row['Voxel_j']}, {row['Voxel_k']})\n"
            )
            handle.write(
                "  world mm (RAS)   : "
                f"({row['World_X_mm']}, {row['World_Y_mm']}, {row['World_Z_mm']})\n"
            )
            handle.write(
                "  DICOM mm (LPS)   : "
                f"({row['DICOM_X_mm']}, {row['DICOM_Y_mm']}, {row['DICOM_Z_mm']})\n"
            )
            if row["DICOM_File"]:
                handle.write(f"  matched DICOM    : {row['DICOM_File']}\n")
                handle.write(f"  series           : {row['SeriesDescription']}\n")
                handle.write(f"  InstanceNumber   : {row['InstanceNumber']}\n")
                handle.write(f"  SOPInstanceUID   : {row['SOPInstanceUID']}\n")
                handle.write(f"  SliceLocation    : {row['SliceLocation']}\n")
                handle.write(
                    "  match distance   : "
                    f"{row['MatchDistance_mm']} mm (within tolerance: {row['WithinTolerance']})\n"
                )
            else:
                handle.write("  matched DICOM    : (none - pydicom unavailable or no geometry)\n")
            handle.write("\n")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, help="cluster index NIfTI (clusters.nii.gz)")
    parser.add_argument("--dicom-dir", required=True, help="original source DICOM directory")
    parser.add_argument("--out-csv", required=True, help="output CSV path")
    parser.add_argument("--out-txt", required=True, help="output TXT report path")
    parser.add_argument(
        "--tolerance",
        type=float,
        default=5.0,
        help=(
            "match tolerance in mm: the nearest slice is always reported, and "
            "WithinTolerance is set to yes/no by comparing MatchDistance_mm to this"
        ),
    )
    args = parser.parse_args()

    if not os.path.isfile(args.index):
        log(f"cluster index volume not found: {args.index}")
        return 2

    clusters = cluster_cogs(args.index)
    log(f"derived {len(clusters)} cluster COG(s) from {args.index}")

    series_list = []
    if os.path.isdir(args.dicom_dir):
        series_list = load_series(args.dicom_dir)
        n_slices = sum(len(s["slices"]) for s in series_list)
        log(f"loaded {len(series_list)} DICOM series ({n_slices} positioned slices)")
    else:
        log(f"DICOM directory not found: {args.dicom_dir} (coords-only output)")

    rows = write_outputs(clusters, series_list, args.out_csv, args.out_txt, args.tolerance)
    log(f"wrote {args.out_csv} and {args.out_txt}")

    # Machine-readable summary on stdout for the bash caller (avoids re-parsing
    # the CSV, whose SeriesDescription field may legally contain commas).
    n_matched = sum(1 for r in rows if r["DICOM_File"])
    n_within = sum(1 for r in rows if r["WithinTolerance"] == "yes")
    print(f"SUMMARY clusters={len(rows)} matched={n_matched} within_tolerance={n_within}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
