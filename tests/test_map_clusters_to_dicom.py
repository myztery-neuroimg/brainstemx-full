#!/usr/bin/env python3
"""Tests for src/modules/map_clusters_to_dicom.py.

Covers the two correctness-critical properties of the cluster -> DICOM mapping:

1. Round-trip coordinate recovery: a cluster placed at a known native voxel COG
   is mapped through the NIfTI affine to world mm and then to DICOM LPS mm, and
   the result is recovered to sub-millimetre tolerance (including the RAS->LPS
   flip on a deliberately off-origin, anisotropic affine).

2. DICOM slice matching: against a synthetic pydicom-written axial series with
   known ImagePositionPatient / ImageOrientationPatient, each cluster matches
   the correct slice and the emitted row carries the right InstanceNumber and
   SOPInstanceUID.

Skips gracefully if numpy/nibabel/pydicom are unavailable.
"""

import csv
import os
import sys

import pytest

np = pytest.importorskip("numpy")
nib = pytest.importorskip("nibabel")
pydicom = pytest.importorskip("pydicom")

from pydicom.dataset import Dataset, FileDataset  # noqa: E402
from pydicom.uid import ExplicitVRLittleEndian, generate_uid  # noqa: E402

MODULE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "modules"
)
sys.path.insert(0, MODULE_DIR)

import map_clusters_to_dicom as mod  # noqa: E402


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _write_index(path, affine, clusters):
    """Write a cluster index volume. clusters: {id: (i, j, k)} single-voxel COGs."""
    shape = (60, 60, 50)
    data = np.zeros(shape, dtype=np.int16)
    for cid, (i, j, k) in clusters.items():
        data[i, j, k] = cid
    nib.save(nib.Nifti1Image(data, affine), path)


def _write_axial_series(ddir, affine, n_slices=50, description="T2 SPACE FLAIR"):
    """Write a synthetic axial DICOM series consistent with the given affine.

    The series IPP/IOP are derived from the affine so the DICOM patient (LPS)
    geometry matches the NIfTI (RAS) geometry after the RAS->LPS flip.
    """
    os.makedirs(ddir, exist_ok=True)
    series_uid = generate_uid()
    for k in range(n_slices):
        # World (RAS) of voxel (0, 0, k); flip first two axes to LPS.
        ras = affine.dot(np.array([0.0, 0.0, float(k), 1.0]))[:3]
        ipp = [-ras[0], -ras[1], ras[2]]
        ds = FileDataset(None, {}, file_meta=Dataset(), preamble=b"\0" * 128)
        ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds.file_meta.MediaStorageSOPClassUID = generate_uid()
        ds.file_meta.MediaStorageSOPInstanceUID = generate_uid()
        ds.SeriesInstanceUID = series_uid
        ds.SeriesDescription = description
        ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
        ds.ImagePositionPatient = [float(v) for v in ipp]
        ds.PixelSpacing = [
            float(abs(affine[0, 0])),
            float(abs(affine[1, 1])),
        ]
        ds.InstanceNumber = k + 1
        ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID
        ds.SliceLocation = float(ipp[2])
        ds.save_as(os.path.join(ddir, f"IM{k:04d}.dcm"), enforce_file_format=True)


# Off-origin, anisotropic axial affine (1.2 x 0.9 x 3.0 mm, origin shifted).
AFFINE = np.array(
    [
        [1.2, 0.0, 0.0, -85.0],
        [0.0, 0.9, 0.0, -110.0],
        [0.0, 0.0, 3.0, -60.0],
        [0.0, 0.0, 0.0, 1.0],
    ]
)


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #
def test_round_trip_coordinates(tmp_path):
    """Known native voxel COG -> world mm -> DICOM LPS mm recovers the input."""
    idx = str(tmp_path / "clusters.nii.gz")
    cog = (15, 25, 30)
    _write_index(idx, AFFINE, {1: cog})

    clusters = mod.cluster_cogs(idx)
    assert len(clusters) == 1
    cluster = clusters[0]

    # Voxel COG recovered exactly (single-voxel cluster).
    assert cluster["vox"] == pytest.approx(list(map(float, cog)), abs=1e-6)

    # World mm matches a manual affine application.
    expected_world = AFFINE.dot(np.array([cog[0], cog[1], cog[2], 1.0]))[:3]
    assert cluster["world_mm"] == pytest.approx(list(expected_world), abs=1e-3)

    # DICOM LPS = negate X and Y of the RAS world coordinate.
    expected_lps = [-expected_world[0], -expected_world[1], expected_world[2]]
    assert cluster["dicom_mm"] == pytest.approx(expected_lps, abs=1e-3)

    # Volume = number of voxels * |det(affine 3x3)|.
    voxel_vol = abs(np.linalg.det(AFFINE[:3, :3]))
    assert cluster["volume_mm3"] == pytest.approx(voxel_vol, abs=1e-3)


def test_dicom_slice_matching(tmp_path):
    """Each cluster matches the correct slice with right InstanceNumber/SOP UID."""
    idx = str(tmp_path / "clusters.nii.gz")
    ddir = str(tmp_path / "dicom")
    # Two clusters at different slice indices k.
    clusters = {1: (10, 20, 12), 2: (40, 35, 33)}
    _write_index(idx, AFFINE, clusters)
    _write_axial_series(ddir, AFFINE, n_slices=50)

    out_csv = str(tmp_path / "map.csv")
    out_txt = str(tmp_path / "map.txt")

    cog_list = mod.cluster_cogs(idx)
    series = mod.load_series(ddir)
    assert len(series) == 1
    assert len(series[0]["slices"]) == 50

    mod.write_outputs(cog_list, series, out_csv, out_txt, tolerance=5.0)

    with open(out_csv, encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 2
    by_id = {int(r["ClusterID"]): r for r in rows}

    # Cluster 1 sits exactly on slice k=12 -> InstanceNumber 13, distance ~0.
    r1 = by_id[1]
    assert r1["InstanceNumber"] == "13"
    assert r1["SOPInstanceUID"] != ""
    assert r1["DICOM_File"].endswith("IM0012.dcm")
    assert float(r1["MatchDistance_mm"]) < 1e-3
    assert r1["WithinTolerance"] == "yes"

    # Cluster 2 sits on slice k=33 -> InstanceNumber 34.
    r2 = by_id[2]
    assert r2["InstanceNumber"] == "34"
    assert r2["DICOM_File"].endswith("IM0033.dcm")
    assert float(r2["MatchDistance_mm"]) < 1e-3
    assert r2["WithinTolerance"] == "yes"


def test_out_of_tolerance_flagged(tmp_path):
    """A cluster far from every slice is reported but flagged WithinTolerance=no."""
    idx = str(tmp_path / "clusters.nii.gz")
    ddir = str(tmp_path / "dicom")
    # Cluster k=12 is within the stack; the slices only span k=0..9, so the
    # nearest slice plane is several mm away (3mm slice spacing on Z).
    _write_index(idx, AFFINE, {1: (10, 20, 30)})
    _write_axial_series(ddir, AFFINE, n_slices=5)  # k=0..4 only

    cog_list = mod.cluster_cogs(idx)
    series = mod.load_series(ddir)
    out_csv = str(tmp_path / "map.csv")
    out_txt = str(tmp_path / "map.txt")
    mod.write_outputs(cog_list, series, out_csv, out_txt, tolerance=2.0)

    with open(out_csv, encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))
    # Nearest slice still reported, but flagged out of tolerance.
    assert row["DICOM_File"] != ""
    assert row["WithinTolerance"] == "no"
    assert float(row["MatchDistance_mm"]) > 2.0


def test_cli_end_to_end(tmp_path):
    """The CLI runs end-to-end and populates match columns for valid clusters."""
    import subprocess

    idx = str(tmp_path / "clusters.nii.gz")
    ddir = str(tmp_path / "dicom")
    _write_index(idx, AFFINE, {1: (20, 20, 25)})
    _write_axial_series(ddir, AFFINE, n_slices=50)
    out_csv = str(tmp_path / "map.csv")
    out_txt = str(tmp_path / "map.txt")

    result = subprocess.run(
        [
            sys.executable,
            os.path.join(MODULE_DIR, "map_clusters_to_dicom.py"),
            "--index", idx,
            "--dicom-dir", ddir,
            "--out-csv", out_csv,
            "--out-txt", out_txt,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert os.path.isfile(out_csv)
    assert os.path.isfile(out_txt)

    with open(out_csv, encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 1
    assert rows[0]["InstanceNumber"] == "26"  # voxel k=25 -> slice 26
    assert rows[0]["DICOM_File"].endswith("IM0025.dcm")


def test_nested_series_dirs(tmp_path):
    """Nested SE####/IM#### layout is traversed recursively."""
    idx = str(tmp_path / "clusters.nii.gz")
    ddir = str(tmp_path / "dicom" / "SE000001")
    _write_index(idx, AFFINE, {1: (5, 5, 8)})
    _write_axial_series(ddir, AFFINE, n_slices=30)

    series = mod.load_series(str(tmp_path / "dicom"))
    assert len(series) == 1
    assert len(series[0]["slices"]) == 30
