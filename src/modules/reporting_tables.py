#!/usr/bin/env python3
"""reporting_tables.py - aggregate BrainStemX-Full results into summary tables.

This is the Python helper behind ``src/modules/reporting.sh``. It DISCOVERS the
various artefacts a run produced (wherever they landed), normalises them, and
emits each summary table as BOTH a CSV/TSV and an HTML fragment, plus a small
``manifest.json`` describing which sections were populated.

Design goals (mirror the bash conventions of this repo):
  * GRACEFUL - every section is gated on the existence of its inputs. A minimal
    T1+FLAIR run that only produced a brainstem mask and a hyperintensity table
    still yields a valid (smaller) set of tables; absent sections are skipped
    cleanly and recorded as "absent" in the manifest.
  * STDLIB ONLY - no numpy/nibabel/pandas dependency. We parse the CSV/TSV the
    upstream modules already wrote; volume numbers are passed in as a sidecar
    TSV the bash layer prepares (it owns fslstats), so this script never shells
    out itself.
  * DETERMINISTIC - stable column order and row sorting so test fixtures match.

Invocation (see reporting.sh)::

    uv run python reporting_tables.py \
        --results-dir   <RESULTS_DIR> \
        --out-dir       <RESULTS_DIR>/reports/tables \
        --subject-id    <SUBJECT_ID> \
        [--seg-volumes  <sidecar.tsv>]   # region\tsource\tvolume_mm3\tn_voxels

Outputs (under --out-dir):
    hyperintensity_per_region.{tsv,html}
    wmh_tool_volumes.{tsv,html}
    segmentation_volumes.{tsv,html}
    cross_modal.{tsv,html}
    freesurfer_morphometry.{tsv,html}
    run_manifest.{tsv,html}
    manifest.json
"""

from __future__ import annotations

import argparse
import csv
import glob
import html
import json
import os
import re
import sys
from typing import Dict, List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------- #
# Small generic helpers
# --------------------------------------------------------------------------- #


def _read_delim(path: str, delim: Optional[str] = None) -> Tuple[List[str], List[List[str]]]:
    """Read a delimited file; returns (header, rows).

    When ``delim`` is given it is used verbatim (callers that KNOW the format —
    e.g. an always-CSV cross-modal table — should pass it so a header that
    happens to contain the other separator can't flip the auto-detection). When
    omitted, tab vs comma is detected from the WHOLE file (max count wins),
    which is more robust than sampling only the first line.
    """
    if not path or not os.path.isfile(path):
        return [], []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if delim is None:
        delim = "\t" if text.count("\t") >= text.count(",") else ","
    reader = csv.reader(text.splitlines(), delimiter=delim)
    rows = [r for r in reader if any(c.strip() for c in r)]
    if not rows:
        return [], []
    return rows[0], rows[1:]


def _safe_float(value) -> Optional[float]:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _fmt_num(value, ndigits: int = 1) -> str:
    f = value if isinstance(value, (int, float)) else _safe_float(value)
    if f is None:
        return str(value) if value not in (None, "") else ""
    # NaN/Inf would crash int(f) (ValueError/OverflowError) and abort the whole
    # aggregation; pass them through verbatim instead. fslstats -M over an empty
    # region returns "nan" on some FSL builds, so this WILL be hit in practice.
    if f != f or f in (float("inf"), float("-inf")):
        return str(value)
    if f == int(f):
        return str(int(f))
    return f"{f:.{ndigits}f}"


def _first_existing(*candidates: str) -> Optional[str]:
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


def _glob_sorted(pattern: str) -> List[str]:
    return sorted(glob.glob(pattern))


def _parse_kv_summary(path: str) -> Dict[str, str]:
    """Parse a ``key=value`` summary file (the WMH-tool convention)."""
    out: Dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            out[key.strip()] = val.strip()
    return out


# --------------------------------------------------------------------------- #
# Table container + writers
# --------------------------------------------------------------------------- #


class Table:
    """An ordered table: title, columns, rows. Knows how to render TSV + HTML."""

    def __init__(self, key: str, title: str, columns: Sequence[str]):
        self.key = key
        self.title = title
        self.columns = list(columns)
        self.rows: List[List[str]] = []

    def add(self, row: Sequence) -> None:
        self.rows.append(["" if c is None else str(c) for c in row])

    @property
    def populated(self) -> bool:
        return len(self.rows) > 0

    def write_tsv(self, path: str) -> None:
        with open(path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh, delimiter="\t")
            writer.writerow(self.columns)
            writer.writerows(self.rows)

    def html_fragment(self) -> str:
        parts = [f"<h2 id='{html.escape(self.key)}'>{html.escape(self.title)}</h2>"]
        if not self.populated:
            parts.append(
                "<p class='absent'>No data for this section "
                "(inputs absent for this run).</p>"
            )
            return "\n".join(parts)
        parts.append("<table>")
        parts.append(
            "<thead><tr>"
            + "".join(f"<th>{html.escape(c)}</th>" for c in self.columns)
            + "</tr></thead>"
        )
        parts.append("<tbody>")
        for row in self.rows:
            parts.append(
                "<tr>"
                + "".join(f"<td>{html.escape(str(c))}</td>" for c in row)
                + "</tr>"
            )
        parts.append("</tbody></table>")
        return "\n".join(parts)

    def write_html(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(self.html_fragment() + "\n")


# --------------------------------------------------------------------------- #
# Section builders - each returns a Table (possibly empty) and is fully gated.
# --------------------------------------------------------------------------- #


def _find_per_region_dir(results_dir: str) -> Optional[str]:
    for cand in (
        os.path.join(results_dir, "per_region_analysis"),
        os.path.join(results_dir, "analysis", "per_region"),
    ):
        if os.path.isdir(cand):
            return cand
    return None


def _load_region_stats_sidecar(path: str) -> Dict[str, Dict[str, str]]:
    """region_tag -> {volume_mm3, n_voxels, cluster_count, mean_z, peak_z}."""
    header, rows = _read_delim(path)
    if not rows:
        return {}
    idx = {name: i for i, name in enumerate(header)}
    out: Dict[str, Dict[str, str]] = {}
    for r in rows:
        if "region_tag" not in idx:
            continue
        tag = r[idx["region_tag"]] if idx["region_tag"] < len(r) else ""
        if not tag:
            continue
        out[tag] = {
            k: (r[idx[k]] if k in idx and idx[k] < len(r) else "")
            for k in ("volume_mm3", "n_voxels", "cluster_count", "mean_z", "peak_z")
        }
    return out


def build_hyperintensity_per_region(results_dir: str) -> Table:
    """Hyperintensity per region x per source.

    Columns: region, source, cluster_count, volume_mm3, mean_z, peak_z.

    The per-region GMM (analysis.sh apply_per_region_gmm_analysis) writes a
    provenance manifest (region_provenance.tsv: region_tag/region_base/source/
    mask_path) and one ``*_<source>_<region>_GMM.nii.gz`` per analysed region.
    A numeric sidecar (region_stats.tsv, built by the bash layer with fslstats
    over each region output) supplies the numeric columns keyed by region_tag.
    """
    table = Table(
        "hyperintensity_per_region",
        "Hyperintensity detection per region x source (per-region GMM)",
        ["region", "source", "cluster_count", "volume_mm3", "mean_z", "peak_z"],
    )
    prdir = _find_per_region_dir(results_dir)
    if not prdir:
        return table
    prov = os.path.join(prdir, "region_provenance.tsv")
    header, rows = _read_delim(prov)
    if not rows:
        return table
    idx = {name: i for i, name in enumerate(header)}
    stats = _load_region_stats_sidecar(os.path.join(prdir, "region_stats.tsv"))
    out_rows = []
    for r in rows:

        def cell(col: str, row=r) -> str:
            return row[idx[col]] if col in idx and idx[col] < len(row) else ""

        tag = cell("region_tag")
        st = stats.get(tag, {})
        out_rows.append(
            [
                cell("region_base"),
                cell("source"),
                st.get("cluster_count", ""),
                _fmt_num(st.get("volume_mm3", "")),
                _fmt_num(st.get("mean_z", ""), 2),
                _fmt_num(st.get("peak_z", ""), 2),
            ]
        )
    for row in sorted(out_rows, key=lambda x: (x[1], x[0])):
        table.add(row)
    return table


# WMH tools and where each one's per-tool summary lands (relative to the WMH
# root under analysis/wmh). Each tool writes a key=value summary file.
_WMH_TOOLS = [
    ("BIANCA", "bianca", "bianca_wmh_summary.txt"),
    ("LST-AI", "lst_samseg/lst_ai", "lstai_wmh_summary.txt"),
    ("SAMSEG", "lst_samseg/samseg", "samseg_wmh_summary.txt"),
    ("WMH-SynthSeg", "synthseg", "wmh_synthseg_wmh_summary.txt"),
    ("segcsvd", "segcsvd", "segcsvd_wmh_summary.txt"),
    ("SHIVA", "shiva", "shiva_wmh_summary.txt"),
    ("MARS", "mars", "mars_wmh_summary.txt"),
]


def build_wmh_tool_volumes(results_dir: str) -> Table:
    """One row per WMH tool that actually ran (summary file present)."""
    table = Table(
        "wmh_tool_volumes",
        "WMH-tool volumes (one row per enabled tool)",
        [
            "tool",
            "total_wmh_mm3",
            "total_clusters",
            "brainstem_wmh_mm3",
            "brainstem_clusters",
        ],
    )
    wmh_root = os.path.join(results_dir, "analysis", "wmh")
    for name, subdir, fname in _WMH_TOOLS:
        cand = os.path.join(wmh_root, subdir, fname)
        summary = cand if os.path.isfile(cand) else None
        if not summary:
            matches = _glob_sorted(os.path.join(wmh_root, subdir, "*_summary.txt"))
            summary = matches[0] if matches else None
        if not summary:
            continue
        kv = _parse_kv_summary(summary)
        total = kv.get("whole_brain_wmh_mm3") or kv.get("whole_brain_wmh_volume", "")
        bs = kv.get("brainstem_wmh_mm3", "")
        table.add(
            [
                name,
                _fmt_num(total),
                kv.get("whole_brain_wmh_clusters", ""),
                _fmt_num(bs),
                kv.get("brainstem_wmh_clusters", ""),
            ]
        )
    return table


def build_segmentation_volumes(results_dir: str, seg_volumes_tsv: str) -> Table:
    """Segmentation / subregion volumes from a precomputed sidecar.

    The bash layer discovers every mask (HO gross, FS substructures, multi-atlas
    nuclei, SynthSeg/aseg, thalamic/hypothalamic) and runs ``fslstats -V`` to
    build a ``region\tsource\tvolume_mm3\tn_voxels`` sidecar; we render it sorted
    by source then region. Keeping fslstats in bash respects the repo convention
    (safe_fslmaths / no nibabel dependency here).
    """
    table = Table(
        "segmentation_volumes",
        "Segmentation / subregion volumes",
        ["region", "source", "volume_mm3", "n_voxels"],
    )
    header, rows = _read_delim(seg_volumes_tsv)
    if not rows:
        return table
    idx = {name: i for i, name in enumerate(header)}
    if not all(k in idx for k in ("region", "source")):
        return table
    out_rows = []
    for r in rows:
        out_rows.append(
            [
                (r[idx["region"]] if idx["region"] < len(r) else ""),
                (r[idx["source"]] if idx["source"] < len(r) else ""),
                _fmt_num(r[idx["volume_mm3"]])
                if "volume_mm3" in idx and idx["volume_mm3"] < len(r)
                else "",
                (r[idx["n_voxels"]] if "n_voxels" in idx and idx["n_voxels"] < len(r) else ""),
            ]
        )
    for row in sorted(out_rows, key=lambda x: (x[1], x[0])):
        table.add(row)
    return table


def build_cross_modal(results_dir: str, subdir: str) -> Table:
    """Per-cluster cross-modal corroboration table (passthrough of the CSV)."""
    cm_csv = _first_existing(
        os.path.join(results_dir, "analysis", subdir, "cross_modal_clusters.csv"),
        os.path.join(results_dir, "analysis", "cross_modal", "cross_modal_clusters.csv"),
    )
    # The cross-modal table is ALWAYS comma-delimited (cross_modal_sample.py /
    # the bash stub use csv.DictWriter), so force the delimiter rather than
    # auto-detecting (a header with a stray tab must not flip detection).
    header, rows = _read_delim(cm_csv, delim=",") if cm_csv else ([], [])
    title = "Cross-modal per-cluster corroboration (DWI / SWI / T2)"
    if not header:
        return Table(
            "cross_modal",
            title,
            ["cluster_id", "n_voxels", "flair_z", "corroboration", "n_corroborating"],
        )
    table = Table("cross_modal", title, header)
    for r in rows:
        table.add(r)
    return table


# FreeSurfer aseg structures of primary interest for a brainstem study, plus
# eTIV/BrainSeg measures (these appear as ``# Measure`` rows in aseg.stats).
_ASEG_KEEP = re.compile(
    r"(Brain-Stem|Cerebellum|Thalamus|VentralDC|4th-Ventricle|"
    r"Lateral-Ventricle|CSF|Hippocampus|Amygdala)",
    re.IGNORECASE,
)
_ASEG_MEASURES = (
    "EstimatedTotalIntraCranialVol",
    "BrainSegVol",
    "TotalGrayVol",
    "SupraTentorialVol",
    "CerebralWhiteMatterVol",
)


def build_freesurfer_morphometry(results_dir: str) -> Table:
    """aseg volumes + eTIV from the FreeSurfer harvest stats."""
    table = Table(
        "freesurfer_morphometry",
        "FreeSurfer morphometry (aseg volumes + eTIV)",
        ["structure", "volume_mm3"],
    )
    stats_dir = os.path.join(results_dir, "freesurfer", "harvest", "stats")
    aseg_stats = _first_existing(
        os.path.join(stats_dir, "aseg.stats"),
        os.path.join(results_dir, "segmentation", "freesurfer", "stats", "aseg.stats"),
    )
    measures: List[Tuple[str, str]] = []
    structures: List[Tuple[str, str]] = []
    if aseg_stats:
        with open(aseg_stats, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("# Measure"):
                    # "# Measure EstimatedTotalIntraCranialVol, eTIV, ..., 1.5e6, mm^3"
                    # The unit column is optional across FS versions, so locate the
                    # numeric value by scanning from the right rather than assuming
                    # a fixed -2 position (a short line would otherwise emit the
                    # free-text description as the "volume").
                    body = line[len("# Measure"):].strip()
                    fields = [f.strip() for f in body.split(",")]
                    if len(fields) >= 4 and fields[0] in _ASEG_MEASURES:
                        val = next(
                            (f for f in reversed(fields) if _safe_float(f) is not None),
                            "",
                        )
                        if val:
                            measures.append((fields[0], val))
                elif not line.startswith("#") and line.strip():
                    cols = line.split()
                    # aseg.stats data: Index SegId NVoxels Volume_mm3 StructName ...
                    if len(cols) >= 5 and _ASEG_KEEP.search(cols[4]):
                        structures.append((cols[4], cols[3]))
    # If raw aseg.stats absent, fall back to the harvested aseg_volumes.tsv.
    if not structures and not measures:
        header, rows = _read_delim(os.path.join(stats_dir, "aseg_volumes.tsv"))
        if rows:
            # asegstats2table is wide (one row, many structure columns). Emit the
            # brainstem-relevant columns we recognise.
            for name in header[1:]:
                if _ASEG_KEEP.search(name) or name in _ASEG_MEASURES:
                    col = header.index(name)
                    val = rows[0][col] if col < len(rows[0]) else ""
                    if name in _ASEG_MEASURES:
                        measures.append((name, val))
                    else:
                        structures.append((name, val))
    for name, val in measures:
        table.add([name, _fmt_num(val)])
    for name, val in sorted(structures):
        table.add([name, _fmt_num(val)])
    return table


def _present(flag: bool) -> str:
    return "present" if flag else "absent"


def build_run_manifest(
    results_dir: str, subject_id: str, populated: Dict[str, bool]
) -> Table:
    """Which segmentation paths, WMH tools, modalities, and tables ran."""
    table = Table(
        "run_manifest",
        "Run manifest (provenance: what actually ran)",
        ["item", "status", "detail"],
    )
    table.add(["subject_id", "info", subject_id or "(unknown)"])

    seg = os.path.join(results_dir, "segmentation")
    table.add([
        "segmentation: HO gross",
        _present(os.path.isdir(os.path.join(seg, "brainstem"))),
        "segmentation/brainstem",
    ])
    detailed = os.path.join(seg, "detailed_brainstem")
    has_fs = bool(_glob_sorted(os.path.join(detailed, "*_pons.nii.gz")))
    has_bianciardi = bool(_glob_sorted(os.path.join(detailed, "bianciardi_*.nii.gz")))
    has_cit168 = bool(_glob_sorted(os.path.join(detailed, "cit168_*.nii.gz")))
    has_aal3 = bool(_glob_sorted(os.path.join(detailed, "aal3_*.nii.gz")))
    table.add(["segmentation: FS substructures", _present(has_fs), "detailed_brainstem (FS parcels)"])
    table.add(["segmentation: Bianciardi nuclei", _present(has_bianciardi), "detailed_brainstem (bianciardi_*)"])
    table.add(["segmentation: CIT168 nuclei", _present(has_cit168), "detailed_brainstem (cit168_*)"])
    table.add(["segmentation: AAL3", _present(has_aal3), "detailed_brainstem (aal3_*)"])

    fs_harvest = os.path.join(results_dir, "freesurfer", "harvest")
    table.add([
        "FreeSurfer recon harvest",
        _present(os.path.isdir(fs_harvest)),
        "freesurfer/harvest",
    ])

    wmh_root = os.path.join(results_dir, "analysis", "wmh")
    for name, subdir, fname in _WMH_TOOLS:
        cand = os.path.join(wmh_root, subdir, fname)
        ran = os.path.isfile(cand) or bool(
            _glob_sorted(os.path.join(wmh_root, subdir, "*_summary.txt"))
        )
        table.add([f"WMH tool: {name}", _present(ran), f"analysis/wmh/{subdir}"])

    cm = os.path.join(results_dir, "registered", "contrast_matched")
    for mod, kw in (("T2", "*T2*"), ("SWI", "*SWI*"), ("DWI", "*DWI*"), ("ADC", "*ADC*")):
        ran = bool(_glob_sorted(os.path.join(cm, f"{kw}_to_*Warped.nii.gz")))
        table.add([f"modality: {mod}", _present(ran), "registered/contrast_matched"])

    for key, ok in populated.items():
        table.add([f"table: {key}", _present(ok), "reports/tables"])
    return table


# --------------------------------------------------------------------------- #
# Top-level HTML / Markdown report
# --------------------------------------------------------------------------- #

_CSS = """
body { font-family: Arial, Helvetica, sans-serif; line-height: 1.5; margin: 0;
       padding: 24px; color: #222; }
h1 { color: #1a3c5e; border-bottom: 3px solid #2980b9; padding-bottom: 8px; }
h2 { color: #2471a3; margin-top: 36px; }
table { border-collapse: collapse; margin: 12px 0 28px; width: auto; }
th, td { border: 1px solid #ccc; padding: 6px 12px; text-align: left;
         font-size: 14px; }
th { background: #eef4fa; }
tr:nth-child(even) td { background: #f7f9fb; }
.absent { color: #888; font-style: italic; }
.toc a { margin-right: 16px; }
.meta { color: #555; font-size: 13px; }
.viz img { max-width: 460px; border: 1px solid #ddd; margin: 8px; }
.viz figure { display: inline-block; margin: 8px; text-align: center; }
.viz figcaption { font-size: 12px; color: #555; }
"""


def _discover_visualizations(results_dir: str) -> List[Tuple[str, str]]:
    """Return (relpath_from_reports, caption) for embeddable PNGs."""
    reports_dir = os.path.join(results_dir, "reports")
    out: List[Tuple[str, str]] = []
    seen = set()

    def _add_from(d: str, limit: Optional[int] = None) -> None:
        pngs = _glob_sorted(os.path.join(d, "*.png"))
        if limit is not None:
            pngs = pngs[:limit]
        for png in pngs:
            if png in seen:
                continue
            seen.add(png)
            try:
                rel = os.path.relpath(png, reports_dir)
            except ValueError:
                # Different drive/mount (Windows shares) -> relpath raises; fall
                # back to the absolute path so the link still resolves and the
                # report write never aborts.
                rel = png
            cap = os.path.splitext(os.path.basename(png))[0].replace("_", " ")
            out.append((rel, cap))

    _add_from(os.path.join(results_dir, "visualizations"))
    # Surface a handful of legacy QC PNGs so a minimal run still shows something.
    _add_from(os.path.join(results_dir, "qc_visualizations"), limit=6)
    _add_from(os.path.join(results_dir, "advanced_visualization"), limit=6)
    return out


def write_top_level_report(
    results_dir: str,
    subject_id: str,
    tables: Sequence[Table],
    html_path: str,
    md_path: str,
) -> None:
    viz = _discover_visualizations(results_dir)
    # ---- HTML ----
    parts = [
        "<!DOCTYPE html>",
        "<html lang='en'><head><meta charset='UTF-8'>",
        "<meta name='viewport' content='width=device-width, initial-scale=1.0'>",
        f"<title>BrainStemX report - {html.escape(subject_id)}</title>",
        f"<style>{_CSS}</style></head><body>",
        "<h1>BrainStemX-Full results report</h1>",
        f"<p class='meta'>Subject: <b>{html.escape(subject_id)}</b> "
        f"&middot; Results: {html.escape(results_dir)}</p>",
        "<p class='toc'>"
        + " ".join(
            f"<a href='#{html.escape(t.key)}'>{html.escape(t.title.split(' (')[0])}</a>"
            for t in tables
        )
        + "</p>",
    ]
    for t in tables:
        parts.append(t.html_fragment())
    if viz:
        parts.append("<h2 id='visualizations'>Visualizations</h2>")
        parts.append("<div class='viz'>")
        for rel, cap in viz:
            parts.append(
                f"<figure><img src='{html.escape(rel)}' alt='{html.escape(cap)}'>"
                f"<figcaption>{html.escape(cap)}</figcaption></figure>"
            )
        parts.append("</div>")
    parts.append("</body></html>")
    with open(html_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts) + "\n")

    # ---- Markdown fallback ----
    md = ["# BrainStemX-Full results report", "", f"Subject: **{subject_id}**", ""]
    for t in tables:
        md.append(f"## {t.title}")
        md.append("")
        if not t.populated:
            md.append("_No data for this section (inputs absent for this run)._")
            md.append("")
            continue
        md.append("| " + " | ".join(t.columns) + " |")
        md.append("| " + " | ".join("---" for _ in t.columns) + " |")
        for row in t.rows:
            md.append("| " + " | ".join(str(c) for c in row) + " |")
        md.append("")
    if viz:
        md.append("## Visualizations")
        md.append("")
        for rel, cap in viz:
            md.append(f"- {cap}: `{rel}`")
        md.append("")
    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Aggregate BrainStemX results.")
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--subject-id", default="")
    ap.add_argument("--seg-volumes", default="", help="segmentation volume sidecar TSV")
    ap.add_argument("--cross-modal-subdir", default="cross_modal")
    ap.add_argument(
        "--report-html",
        default="",
        help="top-level HTML report path (default <results>/reports/brainstemx_report.html)",
    )
    ap.add_argument("--report-md", default="")
    args = ap.parse_args(argv)

    os.makedirs(args.out_dir, exist_ok=True)

    tables = [
        build_hyperintensity_per_region(args.results_dir),
        build_wmh_tool_volumes(args.results_dir),
        build_segmentation_volumes(args.results_dir, args.seg_volumes),
        build_cross_modal(args.results_dir, args.cross_modal_subdir),
        build_freesurfer_morphometry(args.results_dir),
    ]
    populated = {t.key: t.populated for t in tables}
    manifest = build_run_manifest(args.results_dir, args.subject_id, populated)
    tables.append(manifest)

    for t in tables:
        t.write_tsv(os.path.join(args.out_dir, f"{t.key}.tsv"))
        t.write_html(os.path.join(args.out_dir, f"{t.key}.html"))

    with open(os.path.join(args.out_dir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(
            {
                "subject_id": args.subject_id,
                "results_dir": args.results_dir,
                "sections": {t.key: t.populated for t in tables},
            },
            fh,
            indent=2,
        )

    reports_dir = os.path.join(args.results_dir, "reports")
    os.makedirs(reports_dir, exist_ok=True)
    html_path = args.report_html or os.path.join(reports_dir, "brainstemx_report.html")
    md_path = args.report_md or os.path.join(reports_dir, "brainstemx_report.md")
    write_top_level_report(args.results_dir, args.subject_id, tables, html_path, md_path)

    n_pop = sum(1 for t in tables if t.populated)
    print(f"reporting_tables: wrote {len(tables)} tables ({n_pop} populated)")
    print(f"reporting_tables: report_html={html_path}")
    print(f"reporting_tables: report_md={md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
