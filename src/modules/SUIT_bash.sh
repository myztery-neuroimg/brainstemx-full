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

# Prefix for all outputs
PREFIX="suit2flair_"

echo "1) Registering SUIT→FLAIR with $THREADS threads..."
antsRegistrationSyN.sh \
  -d 3 \
  -f "$FIXED" \
  -m "${SUIT_DIR}/templates/T1_reorient.nii.gz" \
  -t s \
  -n "$THREADS" \
  -o "${PREFIX}"
  -p f -j \"$ANTS_THREADS\"

AFF=${PREFIX}0GenericAffine.mat
WARP=${PREFIX}1Warp.nii.gz

echo "2) Warping SUIT atlas labels into FLAIR space..."
antsApplyTransforms \
  -d 3 \
  -i "${SUIT_DIR}/templates/SUIT_reorient.nii.gz" \
  -r "$FIXED" \
  -o "${PREFIX}atlas_in_flair.nii.gz" \
  -t "$WARP" \
  -t "$AFF" \
  -n NearestNeighbor
  -p f -j \"$ANTS_THREADS\"

echo "3) Extracting Pons (label 147) as an intensity image..."
fslmaths "${PREFIX}atlas_in_flair.nii.gz" \
  -thr 146.5 -uthr 147.5 \
  "${PREFIX}pons_intensity.nii.gz"

echo "4) Extracting Pons (label 147) as a binary mask..."
fslmaths "${PREFIX}atlas_in_flair.nii.gz" \
  -thr 147 -uthr 147 -bin \
  "${PREFIX}pons_mask.nii.gz"

echo ""
echo "Done. Outputs written to:"
echo "  ${PREFIX}atlas_in_flair.nii.gz    # full warped label map"
echo "  ${PREFIX}pons_intensity.nii.gz    # voxels=147 only"
echo "  ${PREFIX}pons_mask.nii.gz         # binary pons mask"

