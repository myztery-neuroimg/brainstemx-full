if [ "$#" -ne 2 ]; then
  echo "Usage: $0 SUIT_DIR FIXED_IMAGE"
  echo "Example: $0 ~/Documents/workspace/2025/suit \\"
  echo "         ../mri_results/registered/t1_to_flairWarped.nii.gz"
  exit 1
fi

SUIT_DIR=$1
FIXED=$2

# Number of threads: picks up ANTS_NUM_THREADS or falls back to 1
THREADS=${ANTS_NUM_THREADS:28}

PREFIX="suit2flair_"

# 1) Register SUIT→FLAIR
echo "Registering SUIT template to FLAIR..."
antsRegistrationSyN.sh \
  -d 3 \
  -f "$FIXED" \
  -m "${SUIT_DIR}/templates/T1_reorient.nii.gz" \
  -t s \
  -n "$THREADS" \
  -j 0 \
  -o "${PREFIX}"

AFF="${PREFIX}0GenericAffine.mat"
WARP="${PREFIX}1Warp.nii.gz"

# 2) Warp SUIT atlas labels
echo "Warping SUIT atlas labels into FLAIR space..."
antsApplyTransforms \
  -d 3 \
  -i "${SUIT_DIR}/templates/SUIT_reorient.nii.gz" \
  -r "$FIXED" \
  -o "${PREFIX}atlas_in_flair.nii.gz" \
  -t "$WARP" \
  -t "$AFF" \
  -n NearestNeighbor

# 3) Extract pons label 174
echo "Extracting pons intensity (label 174)..."
fslmaths "${PREFIX}atlas_in_flair.nii.gz" \
  -thr 173.5 -uthr 174.5 \
  "${PREFIX}pons_intensity.nii.gz"

# 4) Extract pons label 174 (binary mask)
echo "Extracting pons binary mask..."
fslmaths "${PREFIX}atlas_in_flair.nii.gz" \
  -thr 173.9 -uthr 174.5 -bin \
  "${PREFIX}pons_mask.nii.gz"

