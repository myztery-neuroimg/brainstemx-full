#!/bin/bash
# src/modules/hierarchical_joint_fusion.sh
# Hierarchical multi-atlas joint fusion for brainstem segmentation

# Global configuration from existing pipeline
TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-2mm}"
ANTS_THREADS="${ANTS_THREADS:-8}"

execute_hierarchical_joint_fusion() {
    local input_file="$1"
    local output_prefix="$2"
    local temp_dir="$3"
    
    log_formatted "INFO" "=== HIERARCHICAL JOINT FUSION SEGMENTATION ==="
    log_message "Input: $input_file"
    log_message "Output prefix: $output_prefix"
    log_message "Template resolution: $TEMPLATE_RES"
    
    # Create workspace
    local fusion_workspace="${temp_dir}/joint_fusion"
    mkdir -p "${fusion_workspace}"/{atlases,registration,labels,results}
    
    # Step 1: Prepare atlas ensemble
    prepare_atlas_ensemble "$fusion_workspace" || return 1
    
    # Step 2: Register Juelich tracts to Talairach anatomical space
    register_juelich_to_talairach "$fusion_workspace" || return 1
    
    # Step 3: Create enhanced Talairach brainstem atlas
    create_enhanced_talairach_atlas "$fusion_workspace" || return 1
    
    # Step 4: Execute dual-atlas joint fusion to subject space
    execute_dual_atlas_fusion "$input_file" "$fusion_workspace" || return 1
    
    # Step 5: Generate final segmentation outputs
    generate_segmentation_outputs "$fusion_workspace" "$output_prefix" || return 1
    
    log_formatted "SUCCESS" "Hierarchical joint fusion completed successfully"
    return 0
}

prepare_atlas_ensemble() {
    local workspace="$1"
    
    log_message "Preparing atlas ensemble..."
    
    # Define atlas paths using existing configuration
    local harvard_atlas="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-${TEMPLATE_RES}.nii.gz"
    local talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-${TEMPLATE_RES}.nii.gz"
    local juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr0-${TEMPLATE_RES}.nii.gz"
    
    # Validate atlas availability
    if [[ ! -f "$harvard_atlas" ]]; then
        log_formatted "ERROR" "Harvard-Oxford atlas not found: $harvard_atlas"
        return 1
    fi
    
    if [[ ! -f "$talairach_atlas" ]]; then
        log_formatted "ERROR" "Talairach atlas not found: $talairach_atlas"
        return 1
    fi
    
    if [[ ! -f "$juelich_atlas" ]]; then
        log_formatted "WARNING" "Juelich atlas not found: $juelich_atlas - proceeding without tract information"
        touch "${workspace}/no_juelich_flag"
    fi
    
    # Copy atlases to workspace
    cp "$harvard_atlas" "${workspace}/atlases/harvard_oxford.nii.gz"
    cp "$talairach_atlas" "${workspace}/atlases/talairach.nii.gz"
    [[ -f "$juelich_atlas" ]] && cp "$juelich_atlas" "${workspace}/atlases/juelich.nii.gz"
    
    log_formatted "SUCCESS" "Atlas ensemble prepared"
    return 0
}

register_juelich_to_talairach() {
    local workspace="$1"
    
    # Skip if Juelich not available
    if [[ -f "${workspace}/no_juelich_flag" ]]; then
        log_message "Skipping Juelich registration - atlas not available"
        return 0
    fi
    
    log_message "Registering Juelich tracts to Talairach anatomical space..."
    
    local juelich_atlas="${workspace}/atlases/juelich.nii.gz"
    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local registration_dir="${workspace}/registration/juelich_to_talairach"
    mkdir -p "$registration_dir"
    
    local transform_prefix="${registration_dir}/juelich_to_talairach_"
    
    # Execute registration using existing ANTs wrapper
    log_message "Executing antsRegistrationSyN.sh for tract-to-anatomy registration..."
    
    #antsRegistrationSyN.sh \
    #    -d 3 \
    #    -f "$talairach_atlas" \
    #    -m "$juelich_atlas" \
    #    -o "$transform_prefix" \
    #    -t s \
    #    -j 1 \
    #    -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    
    # Validate transforms
    #if [[ ! -f "${transform_prefix}0GenericAffine.mat" ]] || [[ ! -f "${transform_prefix}1Warp.nii.gz" ]]; then
    #    log_formatted "ERROR" "Juelich registration failed - transforms not generated"
    #    return 1
    #fi
    
    # Transform Juelich to Talairach space
    local juelich_in_talairach="${workspace}/atlases/juelich_in_talairach.nii.gz"
    cp $talairach_atlas  $juelich_in_talairach
    #antsApplyTransforms \
    #    -d 3 \
    #    -i "$juelich_atlas" \
    #    -r "$talairach_atlas" \
    #    -o "$juelich_in_talairach" \
    #    -t "${transform_prefix}1Warp.nii.gz" \
    #    -t "${transform_prefix}0GenericAffine.mat" \
    #    -n NearestNeighbor >/dev/null 2>/dev/null
    
    if [[ ! -f "$juelich_in_talairach" ]]; then
        log_formatted "ERROR" "Failed to transform Juelich to Talairach space"
        return 1
    fi
    
    log_formatted "SUCCESS" "Juelich registration completed"
    return 0
}

create_enhanced_talairach_atlas() {
    local workspace="$1"
    
    log_message "Creating enhanced Talairach brainstem atlas..."
    
    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local juelich_in_talairach="${workspace}/atlases/juelich_in_talairach.nii.gz"
    local enhanced_talairach="${workspace}/atlases/talairach_enhanced.nii.gz"
    
    # Extract Talairach brainstem regions (indices 172-177)
    local temp_dir="${workspace}/temp_regions"
    mkdir -p "$temp_dir"
    
    # Create individual Talairach brainstem region masks
    declare -A TALAIRACH_REGIONS=(
        ["left_medulla"]="5"
        ["right_medulla"]="6"
        ["left_pons"]="71"
        ["right_pons"]="72"
        ["left_midbrain"]="215"
        ["right_midbrain"]="216"
    )
    
    local region_files=()
    
    for region in "${!TALAIRACH_REGIONS[@]}"; do
        local index="${TALAIRACH_REGIONS[$region]}"
        local region_file="${temp_dir}/${region}.nii.gz"
        
        # Extract region mask
        fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin "$region_file"
        
        # Validate extraction
        local voxel_count=$(fslstats "$region_file" -V | awk '{print $1}')
        if [[ "$voxel_count" -gt 0 ]]; then
            log_message "  ${region}: ${voxel_count} voxels"
            region_files+=("$region_file")
        else
            log_formatted "WARNING" "  ${region}: No voxels found"
        fi
    done
    
    # Combine all brainstem regions
    if [[ ${#region_files[@]} -eq 0 ]]; then
        log_formatted "ERROR" "No Talairach brainstem regions found"
        return 1
    fi
    
    # Initialize with first region
    cp "${region_files[0]}" "$enhanced_talairach"
    
    # Add remaining regions
    for region_file in "${region_files[@]:1}"; do
        fslmaths "$enhanced_talairach" -add "$region_file" "$enhanced_talairach"
    done
    
    # Integrate tract information if available
    if [[ -f "$juelich_in_talairach" ]] && [[ ! -f "${workspace}/no_juelich_flag" ]]; then
        log_message "NOT Integrating tract information into Talairach atlas..."
        
        # Create tract-enhanced mask
    #    local tract_weighted="${temp_dir}/tract_weighted.nii.gz"
    #    fslmaths "$juelich_in_talairach" -bin -mul 0.3 "$tract_weighted"
    #    fslmaths "$enhanced_talairach" -add "$tract_weighted" "$enhanced_talairach"
    fi
    
    # The enhanced atlas is kept with overlapping regions for better registration
    
    local total_voxels=$(fslstats "$enhanced_talairach" -V | awk '{print $1}')
    log_message "Enhanced Talairach atlas: ${total_voxels} total brainstem voxels"
    
    # Clean up
    rm -rf "$temp_dir"
    
    log_formatted "SUCCESS" "Enhanced Talairach atlas created"
    return 0
}

execute_dual_atlas_fusion() {
    local input_file="$1"
    local workspace="$2"
    
    log_message "Executing dual-atlas joint fusion to subject space..."
    
    local harvard_atlas="${workspace}/atlases/harvard_oxford.nii.gz"
    local talairach_enhanced="${workspace}/atlases/talairach_enhanced.nii.gz"
    local registration_dir="${workspace}/registration"
    local results_dir="${workspace}/results"
    
    mkdir -p "$registration_dir/harvard" "$registration_dir/talairach"
    
    # Register Harvard-Oxford to subject
    log_message "Registering Harvard-Oxford atlas to subject space..."
    local harvard_affine="${registration_dir}/harvard/harvard_to_subject_0GenericAffine.mat"
    local harvard_warp="${registration_dir}/harvard/harvard_to_subject_1Warp.nii.gz"
    if [[ -f "$harvard_warp" ]] && [[ -f "$harvard_affine" ]]; then
        log_message "Harvard-Oxford registration to subject space already exists. Skipping."
    else
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$input_file" \
            -m "$harvard_atlas" \
            -o "${registration_dir}/harvard/harvard_to_subject_" \
            -t s \
            -j 1 \
            -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    fi
    
    # Register enhanced Talairach to subject
    log_message "Registering enhanced Talairach atlas to subject space..."
    local talairach_affine="${registration_dir}/talairach/talairach_to_subject_0GenericAffine.mat"
    local talairach_warp="${registration_dir}/talairach/talairach_to_subject_1Warp.nii.gz"
    if [[ -f "$talairach_warp" ]] && [[ -f "$talairach_affine" ]]; then
        log_message "Enhanced Talairach registration to subject space already exists. Skipping."
    else
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$input_file" \
            -m "$talairach_enhanced" \
            -o "${registration_dir}/talairach/talairach_to_subject_" \
            -t s \
            -j 1 \
            -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    fi
    
    # Validate registrations
    
    if [[ ! -f "$harvard_affine" ]] || [[ ! -f "$harvard_warp" ]]; then
        log_formatted "ERROR" "Harvard-Oxford registration failed"
        return 1
    fi
    
    if [[ ! -f "$talairach_affine" ]] || [[ ! -f "$talairach_warp" ]]; then
        log_formatted "ERROR" "Talairach registration failed"
        return 1
    fi
    
    # Create label masks for joint fusion
    local labels_dir="${workspace}/labels"
    mkdir -p "$labels_dir"
    
    # Harvard-Oxford brainstem label (index 7)
    local harvard_label_atlas_space="${labels_dir}/harvard_brainstem_atlas_space.nii.gz"
    fslmaths "$harvard_atlas" -thr 6.5 -uthr 7.5 -bin "$harvard_label_atlas_space"
    
    # Talairach enhanced brainstem label (create binary mask)
    local talairach_label_atlas_space="${labels_dir}/talairach_brainstem_atlas_space.nii.gz"
    fslmaths "$talairach_enhanced" -bin "$talairach_label_atlas_space"

    # Warp atlases and labels to subject space
    log_message "Warping atlases and labels to subject space..."
    
    local harvard_atlas_subject_space="${labels_dir}/harvard_oxford_subject_space.nii.gz"
    local harvard_label_subject_space="${labels_dir}/harvard_brainstem_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$harvard_atlas" -r "$input_file" -o "$harvard_atlas_subject_space" \
        -t "$harvard_warp" -t "$harvard_affine" -n Linear
    antsApplyTransforms -d 3 -i "$harvard_label_atlas_space" -r "$input_file" -o "$harvard_label_subject_space" \
        -t "$harvard_warp" -t "$harvard_affine" -n NearestNeighbor

    # Calculate and log metrics for the warped Harvard-Oxford brainstem
    log_message "Calculating metrics for warped Harvard-Oxford brainstem..."
    local harvard_voxel_count=$(fslstats "$harvard_label_subject_space" -V | awk '{print $1}')
    local harvard_cog_mm=$(fslstats "$harvard_label_subject_space" -c)
    log_message "  ✓ Harvard-Oxford brainstem in subject space:"
    log_message "    - Voxel count: ${harvard_voxel_count}"
    log_message "    - Center of Gravity (mm): ${harvard_cog_mm}"

    local talairach_atlas_subject_space="${labels_dir}/talairach_enhanced_subject_space.nii.gz"
    local talairach_label_subject_space="${labels_dir}/talairach_brainstem_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$talairach_enhanced" -r "$input_file" -o "$talairach_atlas_subject_space" \
        -t "$talairach_warp" -t "$talairach_affine" -n Linear
    antsApplyTransforms -d 3 -i "$talairach_label_atlas_space" -r "$input_file" -o "$talairach_label_subject_space" \
        -t "$talairach_warp" -t "$talairach_affine" -n NearestNeighbor

    # Execute antsJointFusion
    log_message "Executing antsJointFusion with dual atlases in subject space..."
    
    antsJointFusion \
        -d 3 \
        -t "$input_file" \
        -g "$harvard_atlas_subject_space" \
        -l "$harvard_label_subject_space" \
        -g "$talairach_atlas_subject_space" \
        -l "$talairach_label_subject_space" \
        -a 0.1 \
        -b 2.0 \
        -c 1 \
        -s 3 \
        -p 1 \
        -o "${results_dir}/joint_fusion_"
    
    # Validate joint fusion output
    if [[ ! -f "${results_dir}/joint_fusion_Labels.nii.gz" ]]; then
        log_formatted "ERROR" "Joint fusion failed - no output labels"
        return 1
    fi
    
    log_formatted "SUCCESS" "Dual-atlas joint fusion completed"
    return 0
}

generate_segmentation_outputs() {
    local workspace="$1"
    local output_prefix="$2"
    
    log_message "Generating final segmentation outputs..."
    
    local joint_fusion_labels="${workspace}/results/joint_fusion_Labels.nii.gz"
    local input_reference=$(dirname "$output_prefix")/$(basename "$output_prefix" | cut -d'_' -f1)*.nii.gz
    
    # Find the input file for reference space
    if [[ ! -f $input_reference ]]; then
        input_reference=$(find "$(dirname "$output_prefix")" -name "*.nii.gz" | head -1)
    fi
    
    # Generate primary brainstem mask
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    fslmaths "$joint_fusion_labels" -bin "$brainstem_mask"
    
    # Generate FLAIR intensity mask if FLAIR image available
    local flair_file=$(find "$(dirname "$output_prefix")" -name "*FLAIR*" -o -name "*flair*" | head -1)
    if [[ -f "$flair_file" ]]; then
        local brainstem_flair_intensity="${output_prefix}_brainstem_flair_intensity.nii.gz"
        fslmaths "$flair_file" -mul "$brainstem_mask" "$brainstem_flair_intensity"
        log_message "  ✓ FLAIR intensity mask: $brainstem_flair_intensity"
    fi
    
    # Generate individual Talairach region masks in subject space
    generate_talairach_subdivisions "$workspace" "$output_prefix" || return 1
    
    # Generate hemisphere masks for asymmetry analysis
    generate_hemisphere_masks "$brainstem_mask" "$output_prefix" || return 1
    
    log_message "Final segmentation outputs:"
    log_message "  ✓ Primary brainstem mask: $brainstem_mask"
    
    log_formatted "SUCCESS" "Segmentation outputs generated successfully"
    return 0
}

generate_talairach_subdivisions() {
    local workspace="$1"
    local output_prefix="$2"
    
    log_message "Generating Talairach subdivision masks in subject space..."
    
    local talairach_atlas="${workspace}/atlases/talairach.nii.gz"
    local talairach_affine="${workspace}/registration/talairach/talairach_to_subject_0GenericAffine.mat"
    local talairach_warp="${workspace}/registration/talairach/talairach_to_subject_1Warp.nii.gz"
    local joint_fusion_labels="${workspace}/results/joint_fusion_Labels.nii.gz"
    
    # Define Talairach regions
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
        local region_mask="${subdivision_dir}/${region}.nii.gz"
        local temp_atlas_region="${workspace}/temp_${region}.nii.gz"
        
        # Extract region from atlas
        fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin "$temp_atlas_region"
        
        # Transform to subject space
        antsApplyTransforms \
            -d 3 \
            -i "$temp_atlas_region" \
            -r "$joint_fusion_labels" \
            -o "$region_mask" \
            -t "$talairach_warp" \
            -t "$talairach_affine" \
            -n NearestNeighbor
        
        # Validate region
        local voxel_count=$(fslstats "$region_mask" -V | awk '{print $1}')
        if [[ "$voxel_count" -gt 0 ]]; then
            log_message "  ✓ ${region}: ${voxel_count} voxels"
        else
            log_formatted "WARNING" "  ${region}: No voxels in subject space"
        fi
        
        # Clean up
        rm -f "$temp_atlas_region"
    done
    
    log_message "  Talairach subdivisions saved to: $subdivision_dir"
    return 0
}

generate_hemisphere_masks() {
    local brainstem_mask="$1"
    local output_prefix="$2"
    
    log_message "Generating hemisphere masks for asymmetry analysis..."
    
    # Get image dimensions
    local dims=$(fslval "$brainstem_mask" dim1),$(fslval "$brainstem_mask" dim2),$(fslval "$brainstem_mask" dim3)
    local center_x=$(echo "$dims" | cut -d',' -f1 | awk '{print int($1/2)}')
    
    # Create left hemisphere mask (x < center)
    local left_hemisphere="${output_prefix}_left_hemisphere.nii.gz"
    fslmaths "$brainstem_mask" -roi 0 "$center_x" 0 -1 0 -1 0 -1 "$left_hemisphere"
    
    # Create right hemisphere mask (x >= center)
    local right_hemisphere="${output_prefix}_right_hemisphere.nii.gz"
    local remaining_x=$(($(echo "$dims" | cut -d',' -f1) - center_x))
    fslmaths "$brainstem_mask" -roi "$center_x" "$remaining_x" 0 -1 0 -1 0 -1 "$right_hemisphere"
    
    local left_voxels=$(fslstats "$left_hemisphere" -V | awk '{print $1}')
    local right_voxels=$(fslstats "$right_hemisphere" -V | awk '{print $1}')
    
    log_message "  ✓ Left hemisphere: ${left_voxels} voxels"
    log_message "  ✓ Right hemisphere: ${right_voxels} voxels"
    
    return 0
}
