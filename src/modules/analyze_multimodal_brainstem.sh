#!/bin/bash
set -euo pipefail
# ===============================
# CONFIG
# ===============================
log() { echo "[$(date +'%H:%M:%S')] $*" >&2; }

# FLAIR
# $ fslstats ../mri_results/analysis_multimodal/FLAIR_brainstem.nii.gz -V -M -S -P 60 -P 75 -P 80 -P 85 -P 90 -P 95 -P 99
# 4707 4596.677246 184.306032 43.905525 199.326080 208.784561 212.264786 216.887192 222.689819 231.817749 255.387604 
# SWI
# T2_SWI_AX_8_to_FLAIR_brainstem.nii.gz -V -M -S -P 25 -P 50 -P 75
# 4707 4596.677246 95.770767 7.723324 92.000000 97.000000 101.000000
# DWI
# dwi_b1000_to_FLAIR.nii.gz -V -M -S -P 10 -P 20 -P 25 -P 30 -P 35 -P 50 -P 75 -P 90 -P 95 -P 99 -P 92 -P 96
# 5104741 4985096.000000 30.930867 36.512138 1.000000 3.000000 4.000000 5.000000 6.000000 11.000000 68.000000 92.000000 99.000000 112.000000 94.000000 101.000000 
# T1/MPRAGE
# analysis_multimodal/T1_MPRAGE_SAG_12_to_FLAIR_brainstem.nii.gz -V -M -S -P 10 -P 20 -P 35 -P 50 -P 60 -P 70 -P 75 -P 90 -P 95 -P 98 -P 99
# 4707 4596.677246 164.709369 31.651552 119.000000 153.000000 168.000000 174.000000 177.000000 180.000000 182.000000 190.000000 196.000000 203.000000 207.000000 


T1=../extracted/T1_MPRAGE_SAG_12.nii.gz
DWI_4D=../extracted/EPI_DWI_AX_5.nii.gz
SWI=../extracted/T2_SWI_AX_8.nii.gz
FLAIR=../mri_results/standardized/T2_SPACE_FLAIR_Sag_CS_17_n4_brain_std.nii.gz
BRAINSTEM_MASK=../mri_results/segmentation/brainstem/DiCOM_brainstem.nii.gz

OUTDIR=../mri_results/analysis_multimodal
mkdir -p "$OUTDIR"

# ===============================
# DWI: Extract b=1000
# ===============================
TMPDWI="$OUTDIR/dwi_b1000.nii.gz"
log "Extracting b=1000 from DWI series..."
fslroi "$DWI_4D" "$TMPDWI" 1 1

# ===============================
# Resample all to FLAIR space
# ===============================
log "Resampling T1, DWI, SWI, and brainstem mask to FLAIR space..."
for MOD in "$T1" "$TMPDWI" "$SWI"; do
  NAME=$(basename "$MOD" .nii.gz)
  flirt -in "$MOD" -ref "$FLAIR" -applyxfm -usesqform -out "$OUTDIR/${NAME}_to_FLAIR.nii.gz"
done

flirt -in "$BRAINSTEM_MASK" -ref "$FLAIR" -applyxfm -usesqform -interp nearestneighbour \
  -out "$OUTDIR/brainstem_mask_to_FLAIR.nii.gz"

# ===============================
# Apply brainstem mask to all
# ===============================
log "Applying brainstem mask..."
for MOD in T1_MPRAGE_SAG_12_to_FLAIR dwi_b1000_to_FLAIR T2_SWI_AX_8_to_FLAIR; do
  fslmaths "$OUTDIR/${MOD}.nii.gz" -mas "$OUTDIR/brainstem_mask_to_FLAIR.nii.gz" \
    "$OUTDIR/${MOD}_brainstem.nii.gz"
done

# ===============================
# Threshold + Cluster
# ===============================

# --- FLAIR ---
log "Clustering FLAIR hyperintensities..."
fslmaths "$FLAIR" -mas "$OUTDIR/brainstem_mask_to_FLAIR.nii.gz" "$OUTDIR/FLAIR_brainstem.nii.gz"
cluster --in="$OUTDIR/FLAIR_brainstem.nii.gz" --thresh=240  --connectivity=6 \
  --oindex="$OUTDIR/clusters_flair.nii.gz" --mm > "$OUTDIR/report_flair.tsv"

# --- FLAIR SUPER HYPERINTENSITIES ---
#log "Logging extreme FLAIR hyperintensities..."
#fslmaths "$FLAIR" -mas "$OUTDIR/brainstem_mask_to_FLAIR.nii.gz" "$OUTDIR/FLAIR_brainstem_232.nii.gz"
#cluster --in="$OUTDIR/FLAIR_brainstem_232.nii.gz" --thresh=232 --connectivity=6 \
#  --oindex="$OUTDIR/clusters_flair_232.nii.gz" --mm > "$OUTDIR/flair_232_reports.tsv"

# --- DWI ---
log "Clustering DWI restriction..."
cluster --in="$OUTDIR/dwi_b1000_to_FLAIR_brainstem.nii.gz" --thresh=104 --connectivity=6 \
  --oindex="$OUTDIR/clusters_dwi.nii.gz" --mm > "$OUTDIR/report_dwi.tsv"

# --- T1 ---
log "Clustering T1 hypointensities..."
fslmaths "$OUTDIR/T1_MPRAGE_SAG_12_to_FLAIR_brainstem.nii.gz" -uthr 110 -bin "$OUTDIR/t1_hypo_mask.nii.gz"
cluster --in="$OUTDIR/t1_hypo_mask.nii.gz" --thresh=0.01 --connectivity=6 \
  --oindex="$OUTDIR/clusters_t1.nii.gz" --mm > "$OUTDIR/report_t1.tsv"

# --- SWI ---
log "Clustering SWI hypointensities..."
fslmaths "$OUTDIR/T2_SWI_AX_8_to_FLAIR_brainstem.nii.gz" -uthr 60 -bin "$OUTDIR/swi_hypo_mask.nii.gz" 
cluster --in="$OUTDIR/swi_hypo_mask.nii.gz" --thresh=0.01 --connectivity=6 \
  --oindex="$OUTDIR/clusters_swi.nii.gz" --mm > "$OUTDIR/report_swi.tsv"

# ===============================
# TPS REPORT FUSION (via Python)
# ===============================
log "Generating TPS Reports..."

python3 <<EOF
import pandas as pd
import numpy as np
from pathlib import Path
from glob import glob

tps_out = Path("$OUTDIR/cluster_overlap_summary_12mm.csv")
threshold_mm = 20.0
min_voxels = 10 

reports = {}
for file in glob("$OUTDIR/report_*.tsv"):
    mod = Path(file).stem.replace("report_", "").upper()
    df = pd.read_csv(file, sep="\t")
    df["Modality"] = mod
    df = df[df["Voxels"] > min_voxels]
    reports[mod] = df

rows = []
import nibabel as nib

# Load cluster label maps
label_maps = {
    "FLAIR": nib.load("../mri_results/analysis_multimodal/clusters_flair.nii.gz").get_fdata(),
    "DWI": nib.load("../mri_results/analysis_multimodal/clusters_dwi.nii.gz").get_fdata(),
    "T1": nib.load("../mri_results/analysis_multimodal/clusters_t1.nii.gz").get_fdata(),
    "SWI": nib.load("../mri_results/analysis_multimodal/clusters_swi.nii.gz").get_fdata(),
}

rows = []

for mod1, df1 in reports.items():
    for _, row1 in df1.iterrows():
        label1 = int(row1["Cluster Index"])
        vox1 = row1["Voxels"]
        mask1 = (label_maps[mod1] == label1)

        row_out = {
            "ID": f"{mod1}_{label1}",
            "Modality": mod1,
            "Voxels (cubic volume)": vox1,
            "Centre-of-gravity (X-axis)": row1["COG X (mm)"],
            "COG Y-axis": row1["COG Y (mm)"],
            "COG Z-axis": row1["COG Z (mm)"]
        }

        for mod2 in label_maps:
            if mod2 == mod1:
                continue
            overlaps = []
            for _, row2 in reports[mod2].iterrows():
                label2 = int(row2["Cluster Index"])
                mask2 = (label_maps[mod2] == label2)

                intersection = np.logical_and(mask1, mask2)
                n_overlap = int(np.sum(intersection))

                if n_overlap > 0:
                    percent_self = n_overlap / vox1 * 100
                    percent_other = n_overlap / row2["Voxels"] * 100
                    overlaps.append((f"{mod2}_{label2}", n_overlap, percent_self, percent_other))

            # pick top overlap if any
            if overlaps:
                top = sorted(overlaps, key=lambda x: -x[1])[0]
                row_out[f"{mod2}_match"] = top[0]
                row_out[f"{mod2}_vox_overlap"] = top[1]
                row_out[f"{mod2}_%_self"] = round(top[2], 1)
                row_out[f"{mod2}_%_other"] = round(top[3], 1)
            else:
                row_out[f"{mod2}_match"] = None
                row_out[f"{mod2}_vox_overlap"] = 0
                row_out[f"{mod2}_%_self"] = 0.0
                row_out[f"{mod2}_%_other"] = 0.0

        rows.append(row_out)

pd.DataFrame(rows).to_csv(tps_out, index=False)
EOF

log "✅ TPS Reports and all clustering outputs complete."
log "📂 Everything saved in: $OUTDIR"
