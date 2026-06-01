#!/bin/bash
# src/modules/hierarchical_joint_fusion.sh - SIMPLIFIED
# Harvard-Oxford brainstem extraction with optional Talairach subdivisions

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"
source ./config/default_config.sh
TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-1mm}"

execute_hierarchical_joint_fusion() {
    local input_file="$1"
    local output_prefix="$2"
    local temp_dir="$3"
    
    log_formatted "INFO" "=== HARVARD-OXFORD BRAINSTEM EXTRACTION ==="
    log_message "Input: $input_file"
    log_message "Output prefix: $output_prefix"
    log_message "Template resolution: $TEMPLATE_RES"
    
    local fusion_workspace="${temp_dir}/joint_fusion"
    mkdir -p "${fusion_workspace}"/{atlases,registration,labels,results}
    
    prepare_atlas_ensemble "$fusion_workspace" || return 1
    extract_harvard_oxford_brainstem "$input_file" "$fusion_workspace" || return 1
    generate_segmentation_outputs "$fusion_workspace" "$output_prefix" "$input_file" || return 1
    
    log_formatted "SUCCESS" "Label extraction completed successfully"
    return 0
}

prepare_atlas_ensemble() {
    local workspace="$1"
    log_message "Preparing Harvard-Oxford and Talairach atlases..."
    
    local talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-${TEMPLATE_RES}.nii.gz"
    local harvard_oxford_atlas="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-${TEMPLATE_RES}.nii.gz"
    
    if [[ ! -f "$talairach_atlas" ]]; then
        log_formatted "ERROR" "Talairach atlas not found: $talairach_atlas"
        return 1
    fi
    if [[ ! -f "$harvard_oxford_atlas" ]]; then
        log_formatted "ERROR" "Harvard-Oxford subcortical atlas not found: $harvard_oxford_atlas"
        return 1
    fi
    
    cp "$talairach_atlas" "${workspace}/atlases/talairach.nii.gz"
    cp "$harvard_oxford_atlas" "${workspace}/atlases/harvard_oxford_subcortical.nii.gz"
    log_formatted "SUCCESS" "Atlases prepared"
    return 0
}

extract_harvard_oxford_brainstem() {
    local input_file="$1"
    local workspace="$2"
    
    log_message "Registering and extracting Harvard-Oxford brainstem label..."
    
    local harvard_oxford_atlas="${workspace}/atlases/harvard_oxford_subcortical.nii.gz"
    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local mni_template="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}_brain.nii.gz"
    local registration_dir="${workspace}/registration"
    local results_dir="${workspace}/results"
    
    mkdir -p "$registration_dir"

    if [[ ! -f "$mni_template" ]]; then
        mni_template="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}.nii.gz"
    fi
    if [[ ! -f "$mni_template" ]]; then
        log_formatted "ERROR" "MNI template not found for Talairach registration"
        return 1
    fi
    
    log_message "Registering MNI template to subject space..."
    log_message "Template: $mni_template"
    local atlas_prefix="${registration_dir}/mni_to_subject_"
    
    antsRegistrationSyN.sh \
        -d 3 \
        -f "$input_file" \
        -m "$mni_template" \
        -o "$atlas_prefix" \
        -t s \
        -j 1 \
        -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    
    local atlas_affine="${atlas_prefix}0GenericAffine.mat"
    local atlas_warp="${atlas_prefix}1Warp.nii.gz"
    
    if [[ ! -f "$atlas_affine" ]] || [[ ! -f "$atlas_warp" ]]; then
        log_formatted "ERROR" "MNI-to-subject registration failed"
        return 1
    fi
    
    log_message "Warping Harvard-Oxford atlas to subject space..."
    local harvard_subject_space="${results_dir}/harvard_oxford_in_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$harvard_oxford_atlas" -r "$input_file" \
        -o "$harvard_subject_space" \
        -t "$atlas_warp" -t "$atlas_affine" -n NearestNeighbor
    
    if [[ ! -f "$harvard_subject_space" ]]; then
        log_formatted "ERROR" "Failed to warp Harvard-Oxford atlas to subject space"
        return 1
    fi

    # Harvard-Oxford XML label index 7 is Brain-Stem; maxprob image stores index+1.
    local brainstem_mask="${results_dir}/brainstem_mask.nii.gz"
    fslmaths "$harvard_subject_space" -thr 8 -uthr 8 -bin "$brainstem_mask"
    local brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    log_message "  ✓ Harvard-Oxford Brain-Stem: ${brainstem_voxels} voxels"

    if [[ "$brainstem_voxels" -lt 1000 ]]; then
        log_formatted "ERROR" "Harvard-Oxford brainstem mask is implausibly small: ${brainstem_voxels} voxels"
        return 1
    fi

    # Keep Talairach only as optional coarse subdivisions; do not use it as the
    # primary brainstem mask.
    log_message "Warping Talairach atlas for optional subdivisions..."
    local talairach_subject_space="${results_dir}/talairach_in_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$talairach_atlas" -r "$input_file" \
        -o "$talairach_subject_space" \
        -t "$atlas_warp" -t "$atlas_affine" -n NearestNeighbor

    log_message "Extracting optional Talairach coarse subdivisions..."
    
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
    
    # Create joint_fusion_labels for downstream compatibility
    cp "$brainstem_mask" "${results_dir}/joint_fusion_labels.nii.gz"
    
    log_formatted "SUCCESS" "Harvard-Oxford brainstem extraction completed"
    return 0
}

generate_segmentation_outputs() {
    local workspace="$1"
    local output_prefix="$2"
    local input_file="${3:-}"

    log_message "Generating final segmentation outputs..."

    local joint_fusion_labels="${workspace}/results/joint_fusion_labels.nii.gz"
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"

    fslmaths "$joint_fusion_labels" -bin "$brainstem_mask"

    # Generate FLAIR intensity mask if available
    local flair_file=$(find "$(dirname "$output_prefix")" -name "*FLAIR*" -o -name "*flair*" | head -1)
    if [[ -f "$flair_file" ]]; then
        local brainstem_flair_intensity="${output_prefix}_brainstem_flair_intensity.nii.gz"
        fslmaths "$flair_file" -mul "$brainstem_mask" "$brainstem_flair_intensity"
        log_message "  ✓ FLAIR intensity mask: $brainstem_flair_intensity"
    fi

    # Generate region subdivisions (non-fatal — these are optional detail masks)
    generate_talairach_subdivisions "$workspace" "$output_prefix" "$input_file" || {
        log_formatted "WARNING" "Talairach subdivision generation failed, continuing without subdivisions"
    }

    # Generate hemisphere masks
    generate_hemisphere_masks "$brainstem_mask" "$output_prefix" || return 1
    validate_brainstem_mask_geometry "$brainstem_mask" "$output_prefix" || return 1
    
    log_message "  ✓ Primary brainstem mask: $brainstem_mask"
    
    log_formatted "SUCCESS" "Segmentation outputs generated successfully"
    return 0
}

validate_brainstem_mask_geometry() {
    local brainstem_mask="$1"
    local output_prefix="$2"
    local qa_file="${output_prefix}_brainstem_geometry_qa.txt"

    log_message "Validating brainstem mask geometry..."

    local voxel_stats
    voxel_stats=$(fslstats "$brainstem_mask" -V)
    local voxels=$(echo "$voxel_stats" | awk '{print $1}')
    local volume_mm3=$(echo "$voxel_stats" | awk '{print $2}')
    local center_of_mass
    center_of_mass=$(fslstats "$brainstem_mask" -C)
    local dims
    dims="$(fslval "$brainstem_mask" dim1) $(fslval "$brainstem_mask" dim2) $(fslval "$brainstem_mask" dim3)"

    {
        echo "Brainstem Geometry QA"
        echo "====================="
        echo "Mask: $brainstem_mask"
        echo "Voxels: $voxels"
        echo "Volume_mm3: $volume_mm3"
        echo "CenterOfMass_vox: $center_of_mass"
        echo "Dimensions: $dims"
    } > "$qa_file"

    if [[ "$voxels" -lt 1000 ]]; then
        echo "Status: FAIL_TOO_SMALL" >> "$qa_file"
        log_formatted "ERROR" "Brainstem mask too small: $voxels voxels"
        return 1
    fi

    echo "Status: PASS" >> "$qa_file"
    log_message "  ✓ Brainstem geometry QA: $qa_file"
    return 0
}

generate_talairach_subdivisions() {
    local workspace="$1"
    local output_prefix="$2"
    local input_file="${3:-}"

    log_message "Generating Talairach subdivision masks..."

    if [[ -z "$input_file" ]] || [[ ! -f "$input_file" ]]; then
        log_formatted "WARNING" "No input file provided for Talairach subdivisions, skipping"
        return 1
    fi

    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local talairach_affine="${workspace}/registration/mni_to_subject_0GenericAffine.mat"
    local talairach_warp="${workspace}/registration/mni_to_subject_1Warp.nii.gz"
    
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
        
        fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin "$temp_region"
        
        antsApplyTransforms -d 3 -i "$temp_region" -r "$input_file" \
            -o "$region_mask" \
            -t "$talairach_warp" -t "$talairach_affine" \
            -n NearestNeighbor 2>/dev/null
        
        local voxels=$(fslstats "$region_mask" -V 2>/dev/null | awk '{print $1}')
        if [[ -z "$voxels" ]]; then voxels=0; fi
        
        if [[ "$voxels" -gt 0 ]]; then
            log_message "  ✓ ${region}: ${voxels} voxels"
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
export -f extract_harvard_oxford_brainstem
export -f generate_segmentation_outputs
export -f generate_talairach_subdivisions
export -f generate_hemisphere_masks
export -f validate_brainstem_mask_geometry

log_message "Hierarchical joint fusion module loaded (simplified)"
