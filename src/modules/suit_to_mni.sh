SUIT_TPL=$SUIT_DIR/templates/SUIT_reorient.nii.gz
DEF=$SUIT_DIR/templates/def_suit2mni.nii
REF_MNI=$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz

# 1) Extract pons (label 174) from the reoriented atlas
fslmaths "$SUIT_TPL" \
  -thr 173.5 -uthr 174.5 -bin \
  pons_mask_suit.nii.gz

# 2) Warp that pons mask into MNI space
antsApplyTransforms \
  -d 3 \
  -i pons_mask_suit.nii.gz \
  -r "$REF_MNI" \
  -o pons_mask_MNI.nii.gz \
  -t "$DEF" \
  -n NearestNeighbor

