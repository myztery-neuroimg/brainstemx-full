import matplotlib.pyplot as plt
from matplotlib_venn import venn3
import seaborn as sns

# === Raw voxel counts ===
voxels = {
    "DWI_2": 1676,
    "FLAIR_68": 1535,
    "T1_68": 1170,
    "SWI_59": 994
}

# === Overlaps (from TPS table) ===
overlap = {
    ("DWI_2", "FLAIR_68"): 602,
    ("DWI_2", "T1_68"): 40,
    ("DWI_2", "SWI_59"): 42,
    ("FLAIR_68", "T1_68"): 405,
    ("FLAIR_68", "SWI_59"): 216,
    ("T1_68", "SWI_59"): 568,
}

# === 1. Venn3 plot (primary modalities)
venn_counts = {
    '100': voxels["DWI_2"] - overlap[("DWI_2", "FLAIR_68")] - overlap[("DWI_2", "T1_68")],
    '010': voxels["FLAIR_68"] - overlap[("DWI_2", "FLAIR_68")] - overlap[("FLAIR_68", "T1_68")],
    '001': voxels["T1_68"] - overlap[("DWI_2", "T1_68")] - overlap[("FLAIR_68", "T1_68")],
    '110': overlap[("DWI_2", "FLAIR_68")],
    '101': overlap[("DWI_2", "T1_68")],
    '011': overlap[("FLAIR_68", "T1_68")],
    '111': 0  # unknown
}

plt.figure(figsize=(8, 6))
venn3(subsets=venn_counts, set_labels=('DWI_2', 'FLAIR_68', 'T1_68'))
plt.title("Voxel Overlap Between DWI_2, FLAIR_68, and T1_68")
plt.tight_layout()
plt.savefig("venn_dwi_flair_t1.png")
plt.close()

# === 2. SWI relationship heatmap
import pandas as pd
import seaborn as sns

# Build matrix of pairwise SWI overlaps
matrix = pd.DataFrame(index=["SWI_59"], columns=["DWI_2", "FLAIR_68", "T1_68"])
matrix.loc["SWI_59", "DWI_2"] = overlap[("DWI_2", "SWI_59")]
matrix.loc["SWI_59", "FLAIR_68"] = overlap[("FLAIR_68", "SWI_59")]
matrix.loc["SWI_59", "T1_68"] = overlap[("T1_68", "SWI_59")]

# Normalize by SWI volume
matrix = matrix.astype(float) / voxels["SWI_59"] * 100

plt.figure(figsize=(6, 2))
sns.heatmap(matrix, annot=True, fmt=".1f", cmap="Blues", cbar_kws={"label": "% of SWI_59"})
plt.title("SWI_59 Overlap with DWI_2 / FLAIR_68 / T1_68")
plt.tight_layout()
plt.savefig("swi59_overlap_matrix.png")
plt.close()

print("✅ Saved: venn_dwi_flair_t1.png, swi59_overlap_matrix.png")
