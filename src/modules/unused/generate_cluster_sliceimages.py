#!/usr/bin/env python3
"""
Generate HTML side-by-side slice viewers for multimodal cluster analysis.

Assumes all cluster slices have been exported as PNGs by backtrace_to_dicom.py,
and that a manifest CSV/JSON exists mapping:
  - cluster_id
  - modality
  - slice_index
  - png_path (relative or absolute)

Usage:
    python generate_cluster_slice_viewers.py \
        --manifest traced_manifest.csv \
        --images_dir ./traced_slices \
        --output_dir ./viewers
"""

import os
import argparse
import pandas as pd
from collections import defaultdict
import json

def load_manifest(manifest_path):
    if manifest_path.endswith(".csv"):
        return pd.read_csv(manifest_path)
    elif manifest_path.endswith(".json"):
        with open(manifest_path) as f:
            return pd.DataFrame(json.load(f))
    else:
        raise ValueError("Manifest must be .csv or .json")

def group_images_by_cluster(df):
    clusters = defaultdict(lambda: defaultdict(list))
    for _, row in df.iterrows():
        cluster = str(row["cluster_id"])
        modality = str(row["modality"])
        png = row["png_path"]
        slice_idx = row.get("slice_index", "unknown")
        clusters[cluster][modality].append((slice_idx, png))
    return clusters

def generate_html(cluster_id, modalities, output_path):
    with open(output_path, "w") as f:
        f.write(f"<html><head><title>Cluster {cluster_id} Viewer</title>\n")
        f.write("<style>body{font-family:sans-serif;} .row{display:flex;margin-bottom:16px} .col{margin-right:20px}</style></head><body>\n")
        f.write(f"<h2>Cluster {cluster_id}</h2>\n")

        for modality, slices in sorted(modalities.items()):
            f.write(f"<h3>{modality}</h3>\n")
            for slice_idx, img_path in sorted(slices, key=lambda x: int(x[0]) if str(x[0]).isdigit() else 0):
                f.write(f"<div class='row'><div class='col'><b>Slice {slice_idx}</b></div><div class='col'><img src='{img_path}' height='400'></div></div>\n")

        f.write("</body></html>\n")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, help="Path to manifest CSV or JSON")
    parser.add_argument("--images_dir", required=True, help="Directory containing PNG slices")
    parser.add_argument("--output_dir", required=True, help="Directory to write HTML viewers")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    manifest_df = load_manifest(args.manifest)

    # Make image paths absolute
    manifest_df["png_path"] = manifest_df["png_path"].apply(lambda p: os.path.join(args.images_dir, os.path.basename(p)))

    clusters = group_images_by_cluster(manifest_df)

    for cluster_id, modalities in clusters.items():
        html_file = os.path.join(args.output_dir, f"cluster_{cluster_id}_viewer.html")
        generate_html(cluster_id, modalities, html_file)
        print(f"✓ HTML viewer created: {html_file}")

if __name__ == "__main__":
    main()

