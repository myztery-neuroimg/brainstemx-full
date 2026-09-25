"""Benchmark runner: run an adapter over a dataset, aggregate, A/B compare,
compare with published reference numbers, and render a report."""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from typing import Dict, List, Optional

import nibabel as nib
import numpy as np

from . import adapters, datasets, metrics, phantom

HERE = os.path.dirname(os.path.abspath(__file__))


def _params(items: List[str]) -> Dict[str, str]:
    out = {}
    for it in items or []:
        k, _, v = it.partition("=")
        out[k.strip()] = v.strip()
    return out


def cmd_phantom(a) -> int:
    subs = phantom.write_dataset(a.out, a.n_lesion, a.n_control, a.seed, n_lesions=a.lesions_per_subject,
                                 lesion_contrast=a.contrast, noise_sigma=a.noise, brainstem_lesions=a.brainstem_lesions)
    print(f"phantom dataset: {len(subs)} subjects ({a.n_lesion} with lesions, {a.n_control} controls) -> {a.out}")
    return 0


def cmd_datasets(a) -> int:
    print(datasets.describe(a.key))
    return 0


def cmd_fetch(a) -> int:
    d = datasets.REGISTRY[a.dataset]
    if d.fetch is None:
        print(f"{d.key}: no automated fetch ({d.access}). {d.url}\n{d.notes}")
        return 1
    return 0 if d.fetch(a.root, a.subjects or []) else 1


def run(dataset: str, root: str, adapter: str, region: str, out: str, subjects=None, params=None,
        gt_suffix=None, save_masks=True, eval_region_only=True) -> Dict:
    """eval_region_only (default): score prediction AND ground truth inside the
    analysed region, so a brainstem run is not penalised for supratentorial
    lesions it was never asked to find. Pass False (--eval-whole-image) to
    score against the full ground truth."""
    params = params or {}
    subs = datasets.load_subjects(dataset, root, subjects, gt_suffix)
    if not subs:
        raise SystemExit(f"no subjects found for dataset {dataset} under {root}")
    os.makedirs(out, exist_ok=True)
    rows = []
    t0 = time.time()
    for s in subs:
        ts = time.time()
        try:
            prob, mask, reg, img = adapters.predict(adapter, s, region, params)
        except Exception as exc:
            rows.append({"subject": s.id, "error": f"{type(exc).__name__}: {exc}"})
            print(f"  {s.id}: ERROR {exc}", file=sys.stderr)
            continue
        if mask is None:
            rows.append({"subject": s.id, "error": "no prediction"})
            continue
        spacing = img.header.get_zooms()[:3]
        gt = np.asanyarray(nib.load(s.gt).dataobj) if s.gt else None
        row = {"subject": s.id, "adapter": adapter, "region": region, "region_voxels": float(reg.sum()),
               "seconds": round(time.time() - ts, 2), "eval_region_only": float(eval_region_only)}
        if gt is not None and eval_region_only and not (np.asarray(gt) > 0.5)[reg].any():
            row["gt_in_region"] = 0.0     # no ground-truth lesion inside this region: scored as a control
            gt = None
        elif gt is not None:
            row["gt_in_region"] = 1.0
        row.update(metrics.evaluate(mask, gt, spacing, prob=prob, eval_mask=reg if eval_region_only else None))
        rows.append(row)
        if save_masks:
            sd = os.path.join(out, "predictions"); os.makedirs(sd, exist_ok=True)
            nib.save(nib.Nifti1Image(mask.astype(np.uint8), img.affine, img.header), os.path.join(sd, f"{s.id}_pred.nii.gz"))
            if prob is not None:
                nib.save(nib.Nifti1Image(prob.astype(np.float32), img.affine, img.header), os.path.join(sd, f"{s.id}_prob.nii.gz"))
        print(f"  {s.id}: " + ", ".join(f"{k}={v:.3f}" for k, v in row.items() if isinstance(v, float) and k in ("dice", "lesion_f1", "fp_volume_mm3", "avd_percent")))
    lesion_rows = [r for r in rows if r.get("control") == 0.0]
    control_rows = [r for r in rows if r.get("control") == 1.0]
    summary = {
        "dataset": dataset, "root": root, "adapter": adapter, "region": region, "params": params,
        "n_subjects": len(rows), "n_lesion_subjects": len(lesion_rows), "n_controls": len(control_rows),
        "n_errors": sum(1 for r in rows if "error" in r), "seconds": round(time.time() - t0, 1),
        "aggregate_lesion_subjects": metrics.aggregate(lesion_rows, ["dice", "jaccard", "sensitivity", "precision", "lesion_tpr", "lesion_ppv", "lesion_f1", "fp_lesions", "avd_percent", "hd95_mm", "brier", "ece"]),
        "aggregate_controls": metrics.aggregate(control_rows, ["fp_volume_mm3", "fp_lesions"]),
    }
    keys = sorted({k for r in rows for k in r})
    with open(os.path.join(out, "per_subject.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=keys); w.writeheader(); w.writerows(rows)
    with open(os.path.join(out, "per_subject.json"), "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=1)
    with open(os.path.join(out, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=1)
    return summary


def cmd_run(a) -> int:
    s = run(a.dataset, a.root, a.adapter, a.region, a.out, a.subjects, _params(a.param), a.gt_suffix, not a.no_masks, not a.eval_whole_image)
    agg = s["aggregate_lesion_subjects"]
    print(json.dumps({k: {kk: round(vv, 4) if isinstance(vv, float) else vv for kk, vv in v.items()} for k, v in agg.items()}, indent=1))
    print(f"summary -> {os.path.join(a.out, 'summary.json')}")
    return 0 if s["n_errors"] < s["n_subjects"] else 1


def ab_compare(run_a: str, run_b: str, out: str, keys=None) -> Dict:
    ra = json.load(open(os.path.join(run_a, "per_subject.json"), encoding="utf-8"))
    rb = json.load(open(os.path.join(run_b, "per_subject.json"), encoding="utf-8"))
    sa = json.load(open(os.path.join(run_a, "summary.json"), encoding="utf-8"))
    sb = json.load(open(os.path.join(run_b, "summary.json"), encoding="utf-8"))
    keys = keys or ["dice", "lesion_f1", "lesion_tpr", "lesion_ppv", "fp_lesions", "avd_percent", "hd95_mm", "fp_volume_mm3", "brier", "ece"]
    res = {"a": {"run": run_a, "adapter": sa.get("adapter"), "params": sa.get("params")},
           "b": {"run": run_b, "adapter": sb.get("adapter"), "params": sb.get("params")},
           "paired": {k: metrics.paired_compare(ra, rb, k) for k in keys}}
    lower_better = {"fp_lesions", "avd_percent", "hd95_mm", "fp_volume_mm3", "brier", "ece"}
    verdict = []
    for k, p in res["paired"].items():
        if p.get("n", 0) == 0:
            continue
        better = (p["mean_diff"] < 0) if k in lower_better else (p["mean_diff"] > 0)
        sig = p.get("wilcoxon_p", 1.0) < 0.05 if "wilcoxon_p" in p else (p["ci95_lo"] > 0 or p["ci95_hi"] < 0)
        verdict.append({"metric": k, "b_better": bool(better), "significant": bool(sig), "mean_diff": p["mean_diff"], "n": p["n"]})
    res["verdict"] = verdict
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "ab_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    lines = ["| metric | n | mean diff (B-A) | 95% CI | Wilcoxon p | B better |", "|---|---|---|---|---|---|"]
    for v in verdict:
        p = res["paired"][v["metric"]]
        lines.append(f"| {v['metric']} | {p['n']} | {p['mean_diff']:+.4f} | [{p['ci95_lo']:+.4f}, {p['ci95_hi']:+.4f}] | {p.get('wilcoxon_p', float('nan')):.3g} | {'yes' if v['b_better'] else 'no'}{' *' if v['significant'] else ''} |")
    md = f"# A/B: {sa.get('adapter')} (A) vs {sb.get('adapter')} (B)\n\nA: `{run_a}` params={sa.get('params')}\nB: `{run_b}` params={sb.get('params')}\n\n" + "\n".join(lines) + "\n\n`*` = significant (Wilcoxon p<0.05 or bootstrap CI excluding 0).\n"
    with open(os.path.join(out, "ab_summary.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    return res


def cmd_ab(a) -> int:
    res = ab_compare(a.a, a.b, a.out)
    print(open(os.path.join(a.out, "ab_summary.md"), encoding="utf-8").read())
    return 0


def compare_known(run_dir: str, reference: Optional[str] = None) -> Dict:
    s = json.load(open(os.path.join(run_dir, "summary.json"), encoding="utf-8"))
    known = json.load(open(os.path.join(HERE, "known_benchmarks.json"), encoding="utf-8"))
    ref_key = reference or datasets.REGISTRY.get(s["dataset"], datasets.REGISTRY["custom"]).reference_key
    agg = s["aggregate_lesion_subjects"]; ctrl = s["aggregate_controls"]
    out = {"run": run_dir, "dataset": s["dataset"], "adapter": s["adapter"], "reference": ref_key, "rows": []}
    refs = [ref_key] if ref_key and ref_key in known else [k for k in known if not k.startswith("_")]
    for rk in refs:
        r = known[rk]
        for m, val in r["metrics"].items():
            mine = agg.get(m, {}).get("mean") if m in agg else (ctrl.get("fp_volume_mm3", {}).get("mean") if m == "control_fp_volume_mm3" else None)
            out["rows"].append({"reference": rk, "metric": m, "published": val, "this_run": mine, "verified": r.get("verified", False), "citation": r["citation"]})
    return out


def cmd_compare_known(a) -> int:
    res = compare_known(a.run, a.reference)
    print(f"run: {res['run']} ({res['dataset']}, {res['adapter']})")
    print("| reference | metric | published | this run | verified |\n|---|---|---|---|---|")
    for r in res["rows"]:
        mine = "n/a" if r["this_run"] is None else f"{r['this_run']:.3f}"
        print(f"| {r['reference']} | {r['metric']} | {r['published']} | {mine} | {'yes' if r['verified'] else 'no (approximate)'} |")
    with open(os.path.join(a.run, "compare_known.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    return 0


def cmd_report(a) -> int:
    from . import report

    path = report.write_report(a.run, a.ab, a.out)
    print(path)
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="benchmark", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("phantom", help="generate a synthetic BIDS dataset with ground truth")
    p.add_argument("--out", required=True); p.add_argument("--n-lesion", type=int, default=4); p.add_argument("--n-control", type=int, default=2)
    p.add_argument("--seed", type=int, default=0); p.add_argument("--lesions-per-subject", type=int, default=4); p.add_argument("--brainstem-lesions", type=int, default=1)
    p.add_argument("--contrast", type=float, default=0.45); p.add_argument("--noise", type=float, default=0.04)
    p.set_defaults(func=cmd_phantom)
    p = sub.add_parser("datasets", help="list the dataset registry"); p.add_argument("--key", default=None); p.set_defaults(func=cmd_datasets)
    p = sub.add_parser("fetch", help="fetch an open dataset (or print instructions)"); p.add_argument("--dataset", required=True); p.add_argument("--root", required=True)
    p.add_argument("--subjects", nargs="*"); p.set_defaults(func=cmd_fetch)
    p = sub.add_parser("run", help="run an adapter over a dataset and score it")
    p.add_argument("--dataset", required=True, choices=list(datasets.REGISTRY)); p.add_argument("--root", required=True)
    p.add_argument("--adapter", required=True, choices=adapters.ADAPTERS); p.add_argument("--region", default="wm")
    p.add_argument("--out", required=True); p.add_argument("--subjects", nargs="*"); p.add_argument("--param", action="append", default=[])
    p.add_argument("--gt-suffix", default=None); p.add_argument("--no-masks", action="store_true")
    p.add_argument("--eval-whole-image", action="store_true", help="score against the full ground truth instead of within the analysed region")
    p.set_defaults(func=cmd_run)
    p = sub.add_parser("ab", help="paired A/B comparison of two runs"); p.add_argument("--a", required=True); p.add_argument("--b", required=True); p.add_argument("--out", required=True); p.set_defaults(func=cmd_ab)
    p = sub.add_parser("compare-known", help="compare a run with published reference numbers"); p.add_argument("--run", required=True); p.add_argument("--reference", default=None); p.set_defaults(func=cmd_compare_known)
    p = sub.add_parser("report", help="HTML/Markdown report for a run (+ optional A/B)"); p.add_argument("--run", required=True); p.add_argument("--ab", default=None); p.add_argument("--out", default=None); p.set_defaults(func=cmd_report)
    return ap


def main(argv=None) -> int:
    a = build_parser().parse_args(argv)
    return a.func(a)
