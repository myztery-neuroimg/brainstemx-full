import os
import pandas as pd
import numpy as np
from glob import glob

# ====== CONFIG ======
INPUT_DIR = "../mri_results/analysis_multimodal"  # where your report_*.tsv files live
THRESH_MM = 10.0
MIN_VOXELS = 10
OUTPUT = "../mri_results/cluster_overlap_summary_10mm.csv"

# ====== LOAD ALL REPORTS ======
modality_files = glob(os.path.join(INPUT_DIR, "report_*.tsv"))

clusters = []

for f in modality_files:
    modality = os.path.basename(f).split("report_")[-1].replace(".tsv", "").upper()
    df = pd.read_csv(f, sep="\t")
    df["Modality"] = modality
    df = df[df["Voxels"] > MIN_VOXELS]
    clusters.append(df)

all_clusters = pd.concat(clusters, ignore_index=True)
all_clusters["Cluster Key"] = all_clusters["Modality"] + "_" + all_clusters["Cluster Index"].astype(str)

# ====== BUILD CROSS-MODALITY OVERLAP MATRIX ======
rows = []

for idx1, row1 in all_clusters.iterrows():
    key1 = row1["Cluster Key"]
    mod1 = row1["Modality"]
    cog1 = np.array([row1["COG X (mm)"], row1["COG Y (mm)"], row1["COG Z (mm)"]])
    vox1 = row1["Voxels"]

    match_row = {
        "Cluster": key1,
        "Modality": mod1,
        "Voxels": vox1,
        "COG X": cog1[0],
        "COG Y": cog1[1],
        "COG Z": cog1[2]
    }

    for idx2, row2 in all_clusters.iterrows():
        key2 = row2["Cluster Key"]
        mod2 = row2["Modality"]
        if mod1 == mod2:
            continue

        cog2 = np.array([row2["COG X (mm)"], row2["COG Y (mm)"], row2["COG Z (mm)"]])
        vox2 = row2["Voxels"]
        dist = np.linalg.norm(cog1 - cog2)

        if dist <= THRESH_MM:
            match_row[f"Overlap_{mod2}"] = key2
            match_row[f"Distance_{mod2}"] = round(dist, 2)
            match_row[f"Overlap_{mod2}_Vox"] = min(vox1, vox2)
            match_row[f"Overlap_{mod2}_%"] = round(min(vox1, vox2) / vox1 * 100, 1)
        else:
            match_row[f"Overlap_{mod2}"] = None
            match_row[f"Distance_{mod2}"] = None
            match_row[f"Overlap_{mod2}_Vox"] = 0
            match_row[f"Overlap_{mod2}_%"] = 0.0

    rows.append(match_row)

# ====== SAVE ======
summary_df = pd.DataFrame(rows)
summary_df.to_csv(OUTPUT, index=False)
print(f"[✓] Saved: {OUTPUT}")
