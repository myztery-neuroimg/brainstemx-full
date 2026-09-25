"""Markdown + HTML benchmark report with per-subject tables and figures."""

from __future__ import annotations

import html
import json
import os
from typing import Optional


def _fig_boxplots(rows, out_png: str) -> Optional[str]:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return None
    keys = [k for k in ("dice", "lesion_f1", "lesion_tpr", "lesion_ppv") if any(k in r for r in rows)]
    if not keys:
        return None
    fig, axes = plt.subplots(1, len(keys), figsize=(2.6 * len(keys), 3))
    axes = [axes] if len(keys) == 1 else list(axes)
    for ax, k in zip(axes, keys):
        v = [r[k] for r in rows if k in r and r[k] == r[k]]
        ax.boxplot(v, widths=0.5) if v else ax.text(0.5, 0.5, "n/a", ha="center")
        ax.set_title(k, fontsize=9); ax.set_xticks([])
        ax.set_ylim(0, 1)
    fig.tight_layout(); fig.savefig(out_png, dpi=110); plt.close(fig)
    return out_png


def write_report(run_dir: str, ab_dir: Optional[str] = None, out: Optional[str] = None) -> str:
    s = json.load(open(os.path.join(run_dir, "summary.json"), encoding="utf-8"))
    rows = json.load(open(os.path.join(run_dir, "per_subject.json"), encoding="utf-8"))
    out = out or run_dir
    os.makedirs(out, exist_ok=True)
    fig = _fig_boxplots([r for r in rows if r.get("control") == 0.0], os.path.join(out, "metrics_boxplot.png"))
    md = [f"# Benchmark report: {s['dataset']} / {s['adapter']} (region={s['region']})", "",
          f"- subjects: {s['n_subjects']} ({s['n_lesion_subjects']} with lesions, {s['n_controls']} controls, {s['n_errors']} errors), {s['seconds']} s",
          f"- params: `{s['params']}`", ""]
    md.append("## Aggregate (lesion subjects)\n\n| metric | n | mean | median | 95% CI |\n|---|---|---|---|---|")
    for k, v in s["aggregate_lesion_subjects"].items():
        md.append(f"| {k} | {v['n']} | {v['mean']:.3f} | {v['median']:.3f} | [{v['ci95_lo']:.3f}, {v['ci95_hi']:.3f}] |")
    if s["aggregate_controls"]:
        md.append("\n## Controls (false-positive burden)\n\n| metric | n | mean | median |\n|---|---|---|---|")
        for k, v in s["aggregate_controls"].items():
            md.append(f"| {k} | {v['n']} | {v['mean']:.1f} | {v['median']:.1f} |")
    if fig:
        md.append(f"\n![metrics]({os.path.basename(fig)})\n")
    md.append("\n## Per subject\n")
    cols = [c for c in ("subject", "dice", "lesion_tpr", "lesion_ppv", "lesion_f1", "fp_lesions", "avd_percent", "hd95_mm", "fp_volume_mm3", "error") if any(c in r for r in rows)]
    md.append("| " + " | ".join(cols) + " |\n|" + "---|" * len(cols))
    for r in rows:
        md.append("| " + " | ".join((f"{r[c]:.3f}" if isinstance(r.get(c), float) else str(r.get(c, ""))) for c in cols) + " |")
    ck = os.path.join(run_dir, "compare_known.json")
    if os.path.isfile(ck):
        c = json.load(open(ck, encoding="utf-8"))
        md.append("\n## Published reference numbers\n\n| reference | metric | published | this run | verified |\n|---|---|---|---|---|")
        for r in c["rows"]:
            mine = "n/a" if r["this_run"] is None else f"{r['this_run']:.3f}"
            md.append(f"| {r['reference']} | {r['metric']} | {r['published']} | {mine} | {'yes' if r['verified'] else 'approximate'} |")
    if ab_dir and os.path.isfile(os.path.join(ab_dir, "ab_summary.md")):
        md.append("\n" + open(os.path.join(ab_dir, "ab_summary.md"), encoding="utf-8").read())
    text = "\n".join(md) + "\n"
    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    body = html.escape(text)
    with open(os.path.join(out, "report.html"), "w", encoding="utf-8") as fh:
        fh.write(f"<!DOCTYPE html><html><head><meta charset='utf-8'><title>BrainStemX benchmark</title><style>body{{font-family:system-ui;margin:2rem;max-width:1100px}}pre{{white-space:pre-wrap}}</style></head><body><pre>{body}</pre>{f'<img src=\"{os.path.basename(fig)}\">' if fig else ''}</body></html>")
    return os.path.join(out, "report.md")
