#!/usr/bin/env bash
# src/modules/hierarchical_joint_fusion_simplified.sh
# Simplified: Direct Talairach label extraction (no joint fusion voting)

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"
TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-1mm}"

execute_hierarchical_joint_fusion() {
    local input_file="$1"
    local output_prefix="$2"
    local temp_dir="$3"
    
    log_formatted "INFO" "=== SIMPLIFIED TALAIRACH LABEL EXTRACTION ==="
    log_message "Input: $input_file"
    log_message "Output prefix: $output_prefix"
    log_message "Template resolution: $TEMPLATE_RES"
    
    local fusion_workspace="${temp_dir}/joint_fusion"
    mkdir -p "${fusion_workspace}"/{atlases,registration,labels,results}
    
    # Step 1: Prepare atlas
    prepare_atlas_ensemble "$fusion_workspace" || return 1
    
    # Step 2: Register and extract labels
    extract_talairach_labels "$input_file" "$fusion_workspace" || return 1
    
    # Step 3: Generate final segmentation outputs
    generate_segmentation_outputs "$fusion_workspace" "$output_prefix" || return 1
    
    log_formatted "SUCCESS" "Label extraction completed successfully"
    return 0
}

prepare_atlas_ensemble() {
    local workspace="$1"
    
    log_message "Preparing Talairach atlas..."
    
    local talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-${TEMPLATE_RES}.nii.gz"
    
    if [[ ! -f "$talairach_atlas" ]]; then
        log_formatted "ERROR" "Talairach atlas not found: $talairach_atlas"
        return 1
    fi
    
    cp "$talairach_atlas" "${workspace}/atlases/talairach.nii.gz"
    
    log_formatted "SUCCESS" "Atlas prepared"
    return 0
}

extract_talairach_labels() {
    local input_file="$1"
    local workspace="$2"

    log_message "Extracting Talairach labels via MNI inverse-transform..."

    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local registration_dir="${workspace}/registration"
    local results_dir="${workspace}/results"

    mkdir -p "$registration_dir"

    # Register subject T1 → MNI template (intensity-to-intensity)
    # Then use the inverse transforms to bring atlas labels into subject space.
    # Direct atlas-to-subject registration is invalid because label images
    # (integer values 1-50+) have no meaningful intensity correspondence with T1.
    local mni_brain="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}_brain.nii.gz"
    if [[ ! -f "$mni_brain" ]]; then
        log_formatted "ERROR" "MNI template not found: $mni_brain"
        return 1
    fi

    log_message "Registering subject T1 to MNI template..."
    local reg_prefix="${registration_dir}/subject_to_mni_"

    antsRegistrationSyNQuick.sh \
        -d 3 \
        -f "$mni_brain" \
        -m "$input_file" \
        -o "$reg_prefix" \
        -t s \
        -n "${ANTS_THREADS:-1}"

    local reg_affine="${reg_prefix}0GenericAffine.mat"
    local reg_warp="${reg_prefix}1Warp.nii.gz"
    local reg_inverse_warp="${reg_prefix}1InverseWarp.nii.gz"

    if [[ ! -f "$reg_affine" ]] || [[ ! -f "$reg_warp" ]]; then
        log_formatted "ERROR" "Subject-to-MNI registration failed — missing transforms"
        return 1
    fi

    if [[ ! -f "$reg_inverse_warp" ]]; then
        log_formatted "ERROR" "Subject-to-MNI registration failed — missing inverse warp"
        return 1
    fi

    # Apply inverse transforms: MNI → subject space (atlas labels)
    # Transform order for inverse: [-t InverseWarp] [-t affine^-1]
    log_message "Warping Talairach atlas to subject space via inverse transforms..."
    local talairach_subject_space="${results_dir}/talairach_in_subject_space.nii.gz"
    antsApplyTransforms -d 3 \
        -i "$talairach_atlas" \
        -r "$input_file" \
        -o "$talairach_subject_space" \
        -t "$reg_inverse_warp" \
        -t "[$reg_affine,1]" \
        -n NearestNeighbor

    mkdir -p "$registration_dir" "$results_dir"

    # The Talairach atlas is in MNI space.  Registering a label image directly
    # to subject T1 intensities is meaningless (ANTs CC/MI compares intensities).
    # Correct approach:
    #   1. Register subject T1 → MNI T1 template (FLIRT, 12 DOF, ~1 min)
    #   2. Invert the transform
    #   3. Apply inverse to atlas labels with NearestNeighbor interpolation
    local mni_template="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}_brain.nii.gz"
    if [[ ! -f "$mni_template" ]]; then
        mni_template="${FSLDIR}/data/standard/MNI152_T1_1mm_brain.nii.gz"
    fi
    if [[ ! -f "$mni_template" ]]; then
        log_formatted "ERROR" "MNI152 T1 brain template not found under $FSLDIR/data/standard/"
        return 1
    fi
    log_message "MNI template: $mni_template"

    local t1_to_mni_mat="${registration_dir}/t1_to_mni.mat"
    local mni_to_t1_mat="${registration_dir}/mni_to_t1.mat"

    log_message "Registering subject T1 to MNI152 (FLIRT 12-DOF)..."
    if ! flirt -in "$input_file" \
               -ref "$mni_template" \
               -omat "$t1_to_mni_mat" \
               -dof 12 \
               -cost normmi \
               -searchrx -30 30 -searchry -30 30 -searchrz -30 30 \
               2>&1 | while IFS= read -r line; do log_message "  flirt: $line"; done; then
        log_formatted "ERROR" "FLIRT T1→MNI registration failed"
        return 1
    fi
    if [[ ! -f "$t1_to_mni_mat" ]]; then
        log_formatted "ERROR" "FLIRT did not produce transform: $t1_to_mni_mat"
        return 1
    fi

    log_message "Inverting transform (MNI→subject)..."
    convert_xfm -omat "$mni_to_t1_mat" -inverse "$t1_to_mni_mat"
    if [[ ! -f "$mni_to_t1_mat" ]]; then
        log_formatted "ERROR" "convert_xfm failed to invert transform"
        return 1
    fi

    # Warp atlas labels into subject space using the inverted linear transform
    log_message "Applying inverse transform to Talairach atlas labels..."
    local talairach_subject_space="${results_dir}/talairach_in_subject_space.nii.gz"
    flirt -in "$talairach_atlas" \
          -ref "$input_file" \
          -applyxfm -init "$mni_to_t1_mat" \
          -interp nearestneighbour \
          -out "$talairach_subject_space"

    if [[ ! -f "$talairach_subject_space" ]]; then
        log_formatted "ERROR" "Failed to apply inverse transform to atlas"
        return 1
    fi
    log_formatted "SUCCESS" "Talairach atlas in subject space: $talairach_subject_space"
    
    # Extract individual regions
    log_message "Extracting brainstem regions from warped atlas..."
    
    # Pons (indices 71-72)
    local pons_mask="${results_dir}/pons_mask.nii.gz"
    fslmaths "$talairach_subject_space" -thr 71 -uthr 72 -bin "$pons_mask"
    local pons_voxels=$(fslstats "$pons_mask" -V | awk '{print $1}')
    log_message "  ✓ Pons: ${pons_voxels} voxels"
    
    # Medulla (indices 5-6)
    local medulla_mask="${results_dir}/medulla_mask.nii.gz"
    fslmaths "$talairach_subject_space" -thr 5 -uthr 6 -bin "$medulla_mask"
    local medulla_voxels=$(fslstats "$medulla_mask" -V | awk '{print $1}')
    log_message "  ✓ Medulla: ${medulla_voxels} voxels"
    
    # Midbrain (indices 215-216)
    local midbrain_mask="${results_dir}/midbrain_mask.nii.gz"
    fslmaths "$talairach_subject_space" -thr 215 -uthr 216 -bin "$midbrain_mask"
    local midbrain_voxels=$(fslstats "$midbrain_mask" -V | awk '{print $1}')
    log_message "  ✓ Midbrain: ${midbrain_voxels} voxels"
    
    # Combined brainstem
    local brainstem_mask="${results_dir}/brainstem_mask.nii.gz"
    fslmaths "$pons_mask" -add "$medulla_mask" -add "$midbrain_mask" -bin "$brainstem_mask"
    local brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    log_message "  ✓ Combined brainstem: ${brainstem_voxels} voxels"
    
    # Create joint_fusion_labels for downstream compatibility
    cp "$brainstem_mask" "${results_dir}/joint_fusion_labels.nii.gz"
    
    log_formatted "SUCCESS" "Label extraction completed"
    return 0
}

generate_segmentation_outputs() {
    local workspace="$1"
    local output_prefix="$2"
    
    log_message "Generating final segmentation outputs..."
    
    local joint_fusion_labels="${workspace}/results/joint_fusion_labels.nii.gz"
    
    # Generate primary brainstem mask
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    fslmaths "$joint_fusion_labels" -bin "$brainstem_mask"
    
    # Generate FLAIR intensity mask if available
    local flair_file=$(find "$(dirname "$output_prefix")" -name "*FLAIR*" -o -name "*flair*" | head -1)
    if [[ -f "$flair_file" ]]; then
        local brainstem_flair_intensity="${output_prefix}_brainstem_flair_intensity.nii.gz"
        fslmaths "$flair_file" -mul "$brainstem_mask" "$brainstem_flair_intensity"
        log_message "  ✓ FLAIR intensity mask: $brainstem_flair_intensity"
    fi
    
    # Generate region subdivisions
    generate_talairach_subdivisions "$workspace" "$output_prefix" || return 1
    
    # Generate hemisphere masks
    generate_hemisphere_masks "$brainstem_mask" "$output_prefix" || return 1
    
    log_message "  ✓ Primary brainstem mask: $brainstem_mask"
    
    log_formatted "SUCCESS" "Segmentation outputs generated successfully"
    return 0
}

generate_talairach_subdivisions() {
    local workspace="$1"
    local output_prefix="$2"
    
    log_message "Generating Talairach subdivision masks..."
    
    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local reg_affine="${workspace}/registration/subject_to_mni_0GenericAffine.mat"
    local reg_inverse_warp="${workspace}/registration/subject_to_mni_1InverseWarp.nii.gz"
    local input_file
    input_file=$(find "$(dirname "$output_prefix")" -maxdepth 2 -name "*_std.nii.gz" | head -1)

    declare -A TALAIRACH_REGIONS=(
        ["left_medulla"]="5"
        ["right_medulla"]="6"
        ["left_pons"]="71"
        ["right_pons"]="72"
        ["left_midbrain"]="215"
        ["right_midbrain"]="216"
    )

    local subdivision_dir="$(dirname "$output_prefix")/talairach_subdivisions"
    mkdir -p "$subdivision_dir"

    for region in "${!TALAIRACH_REGIONS[@]}"; do
        local index="${TALAIRACH_REGIONS[$region]}"
        local temp_region="${workspace}/temp_${region}.nii.gz"
        local region_mask="${subdivision_dir}/${region}.nii.gz"

        # Extract from atlas in MNI space
        fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin "$temp_region"

        # Apply inverse transforms: MNI → subject space
        antsApplyTransforms -d 3 -i "$temp_region" -r "$input_file" \
            -o "$region_mask" \
            -t "$reg_inverse_warp" -t "[$reg_affine,1]" \
            -n NearestNeighbor

        local voxels
        voxels=$(fslstats "$region_mask" -V 2>/dev/null | awk '{print $1}')
        if [[ -z "$voxels" ]]; then voxels=0; fi

        if [[ "$voxels" -gt 0 ]]; then
            log_message "  ${region}: ${voxels} voxels"
        else
            log_formatted "WARNING" "  ${region}: No voxels"
        fi

        rm -f "$temp_region"
    done
    
    return 0
}

generate_hemisphere_masks() {
    local brainstem_mask="$1"
    local output_prefix="$2"
    
    log_message "Generating hemisphere masks..."
    
    local dims=$(fslval "$brainstem_mask" dim1)
    local center_x=$(echo "$dims" | awk '{print int($1/2)}')
    
    local left_hemisphere="${output_prefix}_left_hemisphere.nii.gz"
    fslmaths "$brainstem_mask" -roi 0 "$center_x" 0 -1 0 -1 0 -1 "$left_hemisphere"
    
    local right_hemisphere="${output_prefix}_right_hemisphere.nii.gz"
    local remaining_x=$((dims - center_x))
    fslmaths "$brainstem_mask" -roi "$center_x" "$remaining_x" 0 -1 0 -1 0 -1 "$right_hemisphere"
    
    local left_voxels=$(fslstats "$left_hemisphere" -V | awk '{print $1}')
    local right_voxels=$(fslstats "$right_hemisphere" -V | awk '{print $1}')
    
    log_message "  ✓ Left hemisphere: ${left_voxels} voxels"
    log_message "  ✓ Right hemisphere: ${right_voxels} voxels"
    
    return 0
}

export -f execute_hierarchical_joint_fusion
export -f prepare_atlas_ensemble
export -f extract_talairach_labels
export -f generate_segmentation_outputs
export -f generate_talairach_subdivisions
export -f generate_hemisphere_masks

log_message "Hierarchical joint fusion module loaded (simplified version)"
