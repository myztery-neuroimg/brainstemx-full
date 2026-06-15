#!/usr/bin/env bash
# src/modules/hierarchical_joint_fusion.sh
#
# Harvard-Oxford gross brainstem extraction (single-atlas SyN warp).
#
# NOTE ON NAMING: despite the historical "joint fusion" name, this module does
# NOT run antsJointFusion. It performs a SINGLE antsRegistrationSyN.sh warp of
# the MNI template into subject space and applies that transform to the
# Harvard-Oxford subcortical atlas to recover the gross Brain-Stem extent. The
# public entry point keeps the legacy name (execute_hierarchical_joint_fusion)
# for backward compatibility with segmentation.sh callers; treat it as
# "extract_harvard_oxford_gross_brainstem".
#
# The midbrain / pons / medulla / SCP subdivisions are NO LONGER derived here.
# Talairach has been removed entirely (single 1988 post-mortem brain, largest
# MNI-mapping error inferiorly/posteriorly — worst exactly in the brainstem).
# Subdivisions come from FreeSurfer (brainstem_freesurfer.sh) when available.
# This module produces ONLY the gross Brain-Stem mask.
set -e -u -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"
source ./config/default_config.sh
TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-1mm}"

# HarvardOxford subcortical maxprob probability threshold. thr25 is tighter than
# thr0 (the most dilated variant) and avoids low-probability fringe voxels at
# the brainstem boundary. The maxprob label index is independent of the
# probability threshold, so the Brain-Stem index (8, see below) is unchanged.
HO_SUB_MAXPROB_THR="${HO_SUB_MAXPROB_THR:-thr25}"

execute_hierarchical_joint_fusion() {
    local input_file="$1"
    local output_prefix="$2"
    local temp_dir="$3"

    log_formatted "INFO" "=== HARVARD-OXFORD GROSS BRAINSTEM EXTRACTION ==="
    log_message "Input: $input_file"
    log_message "Output prefix: $output_prefix"
    log_message "Template resolution: $TEMPLATE_RES"

    # Workspace dir name kept as joint_fusion for path stability with existing runs.
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
    log_message "Preparing Harvard-Oxford subcortical atlas (${HO_SUB_MAXPROB_THR})..."

    local harvard_oxford_atlas="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-${HO_SUB_MAXPROB_THR}-${TEMPLATE_RES}.nii.gz"

    if [[ ! -f "$harvard_oxford_atlas" ]]; then
        log_formatted "ERROR" "Harvard-Oxford subcortical atlas not found: $harvard_oxford_atlas"
        return 1
    fi

    cp "$harvard_oxford_atlas" "${workspace}/atlases/harvard_oxford_subcortical.nii.gz"
    log_formatted "SUCCESS" "Atlas prepared"
    return 0
}

# Seed a destination transform prefix from the orchestrator's shared MNI->subject
# warp (SEG_SHARED_MNI_REG_PREFIX) when it is present. Copies (does not symlink)
# the 0GenericAffine.mat + 1Warp.nii.gz so the destination is self-contained.
# Returns 0 only when both transform files are in place at <dest_prefix>; returns
# 1 (caller computes its own warp) when no usable shared warp is available.
_hojf_seed_from_shared_warp() {
    local dest_prefix="$1"
    local shared_prefix="${SEG_SHARED_MNI_REG_PREFIX:-}"
    [ -n "$shared_prefix" ] || return 1

    local src_affine="${shared_prefix}0GenericAffine.mat"
    local src_warp="${shared_prefix}1Warp.nii.gz"
    [ -f "$src_affine" ] && [ -f "$src_warp" ] || return 1

    local dest_affine="${dest_prefix}0GenericAffine.mat"
    local dest_warp="${dest_prefix}1Warp.nii.gz"
    # Already seeded (idempotent / resumable).
    if [ -f "$dest_affine" ] && [ -f "$dest_warp" ]; then
        return 0
    fi
    cp -f "$src_affine" "$dest_affine" 2>/dev/null || return 1
    cp -f "$src_warp" "$dest_warp" 2>/dev/null || return 1
    # The inverse warp is optional here (HO only applies the forward chain) but
    # copy it through when present so the workspace mirrors a full registration.
    [ -f "${shared_prefix}1InverseWarp.nii.gz" ] && \
        cp -f "${shared_prefix}1InverseWarp.nii.gz" "${dest_prefix}1InverseWarp.nii.gz" 2>/dev/null || true
    return 0
}

extract_harvard_oxford_brainstem() {
    local input_file="$1"
    local workspace="$2"

    log_message "Registering and extracting Harvard-Oxford brainstem label..."

    local harvard_oxford_atlas="${workspace}/atlases/harvard_oxford_subcortical.nii.gz"
    local mni_template="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}_brain.nii.gz"
    local registration_dir="${workspace}/registration"
    local results_dir="${workspace}/results"

    mkdir -p "$registration_dir"

    if [[ ! -f "$mni_template" ]]; then
        mni_template="${FSLDIR}/data/standard/MNI152_T1_${TEMPLATE_RES}.nii.gz"
    fi
    if [[ ! -f "$mni_template" ]]; then
        log_formatted "ERROR" "MNI template not found for Harvard-Oxford registration"
        return 1
    fi

    local atlas_prefix="${registration_dir}/mni_to_subject_"
    local atlas_affine="${atlas_prefix}0GenericAffine.mat"
    local atlas_warp="${atlas_prefix}1Warp.nii.gz"

    # Concurrency-safe shared warp: in 'all' mode the orchestrator computes the
    # MNI->subject SyN warp ONCE up front (before the parallel fan-out) and
    # exports SEG_SHARED_MNI_REG_PREFIX. Seed this workspace from that cached
    # transform instead of recomputing it — both the HO and multi-atlas paths
    # reuse the SAME warp, so two background jobs never race on (or duplicate) the
    # expensive registration. When the shared prefix is absent (single-method
    # runs) we fall back to computing the warp here as before.
    if _hojf_seed_from_shared_warp "$atlas_prefix"; then
        log_message "Reusing pre-computed shared MNI->subject warp: ${SEG_SHARED_MNI_REG_PREFIX}"
    else
        log_message "Registering MNI template to subject space (single SyN warp)..."
        log_message "Template: $mni_template"
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$input_file" \
            -m "$mni_template" \
            -o "$atlas_prefix" \
            -t s \
            -j 1 \
            -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    fi

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

    # Harvard-Oxford-Subcortical XML label index 7 is Brain-Stem; the maxprob
    # image stores index+1, so the Brain-Stem voxel value is 8. This index is
    # independent of the probability threshold (thr0/thr25/thr50), so it is
    # unchanged by tightening HO_SUB_MAXPROB_THR.
    local brainstem_mask="${results_dir}/brainstem_mask.nii.gz"
    fslmaths "$harvard_subject_space" -thr 8 -uthr 8 -bin "$brainstem_mask"
    local brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    log_message "  ✓ Harvard-Oxford Brain-Stem: ${brainstem_voxels} voxels"

    if [[ "$brainstem_voxels" -lt 1000 ]]; then
        log_formatted "ERROR" "Harvard-Oxford brainstem mask is implausibly small: ${brainstem_voxels} voxels"
        return 1
    fi

    # Gross brainstem mask only. Midbrain/pons/medulla/SCP subdivisions come
    # from FreeSurfer (brainstem_freesurfer.sh), not from this atlas warp.
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

    # Generate hemisphere masks (gross brainstem only).
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
export -f _hojf_seed_from_shared_warp
export -f extract_harvard_oxford_brainstem
export -f generate_segmentation_outputs
export -f generate_hemisphere_masks
export -f validate_brainstem_mask_geometry

log_message "Harvard-Oxford gross brainstem extraction module loaded"
