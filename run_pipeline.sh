source ./00_environment_functions.sh

# Bias field correction for T1 image
process_n4_correction ../extracted/T1_MPRAGE_SAG_12.nii.gz

# Bias field correction for T2/FLAIR image
process_n4_correction ../extracted/T2_SPACE_FLAIR_Sag_CS_17.nii.gz

registration_flair_to_t1 ../extracted/T2_SPACE_FLAIR_Sag_CS_17.nii.gz ../extracted/T1_MPRAGE_SAG_12.nii.gz   ../mri_results/reg_

detect_hyperintensities ../extracted/T2_SPACE_FLAIR_Sag_CS_17.nii.gz ../mri_results/hyper_flair ../mri_results/reg_Warped.nii.gz



