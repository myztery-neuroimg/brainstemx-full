fslswapdim \
  $SUIT_DIR/templates/T1.nii \
   -x y z \
  $SUIT_DIR/templates/T1_reorient.nii.gz

# 2) SUIT label atlas
fslswapdim \
  $SUIT_DIR/templates/SUIT.nii \
   -x y z \
  $SUIT_DIR/templates/SUIT_reorient.nii.gz

# 3) SUIT priors
fslswapdim $SUIT_DIR/priors/white_cereb.nii  x -y z  $SUIT_DIR/priors/white_cereb_reorient.nii.gz
fslswapdim $SUIT_DIR/priors/csf_cereb.nii  x -y z   $SUIT_DIR/priors/csf_cereb_reorient.nii.gz
