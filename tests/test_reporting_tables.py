#!/usr/bin/env python3
"""Unit tests for reporting_tables.py (the summary-table aggregator).

Builds a SYNTHETIC results dir with a couple of methods/modalities present and
confirms the tables + top-level report render, and that absent sections are
skipped cleanly. No FSL / nibabel / numpy required (the aggregator is stdlib
only; volume numbers are supplied via the sidecars the bash layer would write).

Run:
    uv run pytest tests/test_reporting_tables.py -v
    python3 tests/test_reporting_tables.py            # standalone
"""

import csv
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "modules"))

import reporting_tables as rt  # noqa: E402


# --------------------------------------------------------------------------- #
# Synthetic results dir fixtures
# --------------------------------------------------------------------------- #


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


@pytest.fixture
def full_results(tmp_path):
    """A results dir with hyperintensity, WMH, seg, cross-modal, and FS inputs."""
    r = str(tmp_path / "results")
    # per-region GMM provenance + stats sidecar
    _write(
        os.path.join(r, "per_region_analysis", "region_provenance.tsv"),
        "region_tag\tregion_base\tsource\tmask_path\n"
        "freesurfer_pons\tpons\tfreesurfer\t/x/pons.nii.gz\n"
        "bianciardi_LC\tLC\tbianciardi\t/x/lc.nii.gz\n",
    )
    _write(
        os.path.join(r, "per_region_analysis", "region_stats.tsv"),
        "region_tag\tvolume_mm3\tn_voxels\tcluster_count\tmean_z\tpeak_z\n"
        "freesurfer_pons\t123.0\t123\t2\t1.81\t3.42\n"
        "bianciardi_LC\t8.0\t8\t1\t2.10\t2.55\n",
    )
    # WMH tool summaries (BIANCA + SHIVA)
    _write(
        os.path.join(r, "analysis", "wmh", "bianca", "bianca_wmh_summary.txt"),
        "tool=bianca\nwhole_brain_wmh_mm3=2500.0\n"
        "whole_brain_wmh_clusters=12\nbrainstem_wmh_mm3=40.0\n"
        "brainstem_wmh_clusters=2\n",
    )
    _write(
        os.path.join(r, "analysis", "wmh", "shiva", "shiva_wmh_summary.txt"),
        "tool=shiva_wmh\nwhole_brain_wmh_mm3=1800.5\n"
        "whole_brain_wmh_clusters=30\nbrainstem_wmh_mm3=12.0\n"
        "brainstem_wmh_clusters=1\n",
    )
    # cross-modal table
    _write(
        os.path.join(r, "analysis", "cross_modal", "cross_modal_clusters.csv"),
        "cluster_id,n_voxels,cog_x,cog_y,cog_z,flair_mean,flair_z,"
        "DWI_z,corroboration,n_corroborating\n"
        "1,50,10,11,12,300,2.1,1.4,RESTRICTION,1\n"
        "2,8,20,21,22,250,1.2,0.1,NONE,0\n",
    )
    # FreeSurfer aseg.stats with measures + a couple of structures
    _write(
        os.path.join(r, "freesurfer", "harvest", "stats", "aseg.stats"),
        "# Measure EstimatedTotalIntraCranialVol, eTIV, "
        "Estimated Total Intracranial Volume, 1500000.0, mm^3\n"
        "# Measure BrainSegVol, BrainSegVol, Brain Segmentation Volume, "
        "1200000.0, mm^3\n"
        "# ColHeaders Index SegId NVoxels Volume_mm3 StructName\n"
        "  1  16  18000  18000.0  Brain-Stem\n"
        "  2  10   7000   7000.0  Left-Thalamus\n"
        "  3   2  90000  90000.0  Left-Cerebral-White-Matter\n",
    )
    # segmentation masks (existence drives the run manifest)
    os.makedirs(os.path.join(r, "segmentation", "brainstem"), exist_ok=True)
    _write(os.path.join(r, "segmentation", "brainstem", "sub_brainstem.nii.gz"), "x")
    _write(os.path.join(r, "segmentation", "detailed_brainstem", "sub_pons.nii.gz"), "x")
    _write(
        os.path.join(r, "segmentation", "detailed_brainstem", "bianciardi_LC_label5.nii.gz"),
        "x",
    )
    # co-registered DWI (modality present in manifest)
    _write(
        os.path.join(r, "registered", "contrast_matched", "EPI_DWI_to_flairWarped.nii.gz"),
        "x",
    )
    # segmentation volume sidecar (the bash layer would compute this via fslstats)
    seg_sidecar = str(tmp_path / "seg_vol.tsv")
    _write(
        seg_sidecar,
        "region\tsource\tvolume_mm3\tn_voxels\n"
        "sub_brainstem\tharvard_oxford\t21000.0\t21000\n"
        "pons\tfreesurfer\t4200.0\t4200\n"
        "LC_label5\tbianciardi\t9.0\t9\n",
    )
    return r, seg_sidecar


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #


def _read_tsv(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.reader(fh, delimiter="\t"))


def test_full_run_renders_all_tables(tmp_path, full_results):
    results_dir, seg_sidecar = full_results
    out_dir = str(tmp_path / "tables")
    rc = rt.main([
        "--results-dir", results_dir,
        "--out-dir", out_dir,
        "--subject-id", "sub",
        "--seg-volumes", seg_sidecar,
    ])
    assert rc == 0

    # All per-table CSV/TSV + HTML exist.
    for key in (
        "hyperintensity_per_region",
        "wmh_tool_volumes",
        "segmentation_volumes",
        "cross_modal",
        "freesurfer_morphometry",
        "run_manifest",
    ):
        assert os.path.isfile(os.path.join(out_dir, f"{key}.tsv"))
        assert os.path.isfile(os.path.join(out_dir, f"{key}.html"))

    # Hyperintensity per region: two rows, sorted by source then region.
    rows = _read_tsv(os.path.join(out_dir, "hyperintensity_per_region.tsv"))
    assert rows[0] == ["region", "source", "cluster_count", "volume_mm3",
                       "mean_z", "peak_z"]
    body = rows[1:]
    assert len(body) == 2
    # bianciardi sorts before freesurfer
    assert body[0][0] == "LC" and body[0][1] == "bianciardi"
    assert body[1][0] == "pons" and body[1][1] == "freesurfer"
    assert body[1][2] == "2" and body[1][3] == "123"  # cluster_count, volume

    # WMH volumes: one row per tool present.
    wmh = _read_tsv(os.path.join(out_dir, "wmh_tool_volumes.tsv"))
    tools = {row[0] for row in wmh[1:]}
    assert tools == {"BIANCA", "SHIVA"}

    # Cross-modal passthrough retains the DWI_z column + corroboration.
    cm = _read_tsv(os.path.join(out_dir, "cross_modal.tsv"))
    assert "corroboration" in cm[0]
    assert "DWI_z" in cm[0]
    assert any("RESTRICTION" in row for row in cm[1:])

    # FreeSurfer morphometry includes eTIV and Brain-Stem.
    fs = _read_tsv(os.path.join(out_dir, "freesurfer_morphometry.tsv"))
    fs_names = {row[0] for row in fs[1:]}
    assert "EstimatedTotalIntraCranialVol" in fs_names
    assert "Brain-Stem" in fs_names

    # manifest.json marks the populated sections.
    with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    sections = manifest["sections"]
    assert sections["hyperintensity_per_region"] is True
    assert sections["wmh_tool_volumes"] is True
    assert sections["cross_modal"] is True
    assert sections["freesurfer_morphometry"] is True

    # Top-level HTML + markdown reports were written.
    assert os.path.isfile(os.path.join(results_dir, "reports", "brainstemx_report.html"))
    assert os.path.isfile(os.path.join(results_dir, "reports", "brainstemx_report.md"))
    with open(os.path.join(results_dir, "reports", "brainstemx_report.html"),
              encoding="utf-8") as fh:
        html = fh.read()
    assert "BrainStemX-Full results report" in html
    assert "RESTRICTION" in html  # cross-modal embedded


def test_minimal_run_skips_absent_sections(tmp_path):
    """Minimal T1+FLAIR-style run: only a hyperintensity table; rest absent."""
    r = str(tmp_path / "results")
    _write(
        os.path.join(r, "per_region_analysis", "region_provenance.tsv"),
        "region_tag\tregion_base\tsource\tmask_path\n"
        "freesurfer_pons\tpons\tfreesurfer\t/x/pons.nii.gz\n",
    )
    os.makedirs(os.path.join(r, "segmentation", "brainstem"), exist_ok=True)
    out_dir = str(tmp_path / "tables")
    rc = rt.main([
        "--results-dir", r, "--out-dir", out_dir, "--subject-id", "sub",
    ])
    assert rc == 0

    with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as fh:
        sections = json.load(fh)["sections"]
    # Hyperintensity present (provenance exists, even without stats sidecar).
    assert sections["hyperintensity_per_region"] is True
    # These have no inputs -> empty/absent.
    assert sections["wmh_tool_volumes"] is False
    assert sections["cross_modal"] is False
    assert sections["freesurfer_morphometry"] is False
    assert sections["segmentation_volumes"] is False

    # Empty sections still produce a (header-only) TSV and an "absent" HTML note.
    wmh = _read_tsv(os.path.join(out_dir, "wmh_tool_volumes.tsv"))
    assert wmh[0][0] == "tool"
    assert len(wmh) == 1
    with open(os.path.join(out_dir, "wmh_tool_volumes.html"), encoding="utf-8") as fh:
        assert "No data for this section" in fh.read()

    # Top-level report still renders.
    assert os.path.isfile(os.path.join(r, "reports", "brainstemx_report.html"))


def test_html_escaping(tmp_path):
    """A cell with HTML-special chars is escaped in the fragment."""
    t = rt.Table("k", "Title", ["a", "b"])
    t.add(["<x>", "a&b"])
    frag = t.html_fragment()
    assert "&lt;x&gt;" in frag
    assert "a&amp;b" in frag


def test_fmt_num_handles_nan_inf():
    """_fmt_num must NOT raise on nan/inf (fslstats -M over empty region)."""
    assert rt._fmt_num("nan") == "nan"
    assert rt._fmt_num("inf") == "inf"
    assert rt._fmt_num(float("nan")) == str(float("nan"))
    assert rt._fmt_num(float("inf")) == str(float("inf"))
    # sanity: normal values still format
    assert rt._fmt_num("123.0") == "123"
    assert rt._fmt_num("1.234", 2) == "1.23"


def test_nan_meanz_does_not_wipe_report(tmp_path):
    """A nan in region_stats.tsv must not abort the whole aggregation."""
    r = str(tmp_path / "results")
    _write(
        os.path.join(r, "per_region_analysis", "region_provenance.tsv"),
        "region_tag\tregion_base\tsource\tmask_path\n"
        "freesurfer_pons\tpons\tfreesurfer\t/x/pons.nii.gz\n",
    )
    _write(
        os.path.join(r, "per_region_analysis", "region_stats.tsv"),
        "region_tag\tvolume_mm3\tn_voxels\tcluster_count\tmean_z\tpeak_z\n"
        "freesurfer_pons\t123.0\t123\t2\tnan\tnan\n",
    )
    out_dir = str(tmp_path / "tables")
    rc = rt.main(["--results-dir", r, "--out-dir", out_dir, "--subject-id", "sub"])
    assert rc == 0
    # The per-region table + the report were still written.
    assert os.path.isfile(os.path.join(out_dir, "hyperintensity_per_region.tsv"))
    assert os.path.isfile(os.path.join(r, "reports", "brainstemx_report.html"))
    rows = _read_tsv(os.path.join(out_dir, "hyperintensity_per_region.tsv"))
    assert rows[1][0] == "pons"  # row present despite the nan


def test_freesurfer_measure_without_unit_column(tmp_path):
    """A 4-field '# Measure' line (no unit col) must yield the NUMBER, not text."""
    r = str(tmp_path / "results")
    _write(
        os.path.join(r, "freesurfer", "harvest", "stats", "aseg.stats"),
        # No trailing unit column -> only 4 comma fields.
        "# Measure BrainSegVol, BrainSegVol, Brain Segmentation Volume, 1100000.0\n"
        "# ColHeaders Index SegId NVoxels Volume_mm3 StructName\n"
        "  1  16  18000  18000.0  Brain-Stem\n",
    )
    t = rt.build_freesurfer_morphometry(r)
    rowmap = {row[0]: row[1] for row in t.rows}
    assert rowmap["BrainSegVol"] == "1100000"  # the number, not the description
    assert "Brain Segmentation Volume" not in rowmap.values()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
