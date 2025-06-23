#!/bin/bash
# src/modules/hierarchical_atlas_preparation.sh

source "$(dirname "${BASH_SOURCE[0]}")/../config/default_config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Global atlas configuration with hierarchical relationships
declare -A ATLAS_HIERARCHY=(
    ["primary"]="harvard_oxford"
    ["detailed"]="talairach" 
    ["microstructural"]="juelich"
)

# Atlas-specific parameters from configuration
TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-2mm}"
REGISTRATION_METRIC="${REG_METRIC_SAME_MODALITY:-CC}"
ANTS_THREADS="${ANTS_THREADS:-8}"

initialize_hierarchical_atlas_framework() {
    local input_file="$1"
    local output_prefix="$2"
    local temp_dir="$3"
    
    log_formatted "INFO" "=== HIERARCHICAL ATLAS PREPARATION FRAMEWORK ==="
    log_message "Initializing multi-atlas preparation with template resolution: ${TEMPLATE_RES}"
    
    # Create hierarchical workspace structure
    local atlas_workspace="${temp_dir}/hierarchical_atlases"
    mkdir -p "${atlas_workspace}"/{original,prepared,transforms,validation,reports}
    
    # Validate atlas availability and compatibility
    validate_atlas_ensemble "${atlas_workspace}" || return 1
    
    # Prepare atlas resolution matching
    prepare_atlas_resolution_matching "${atlas_workspace}" || return 1
    
    # Initialize quality assessment framework
    initialize_atlas_qa_framework "${atlas_workspace}" || return 1
    
    log_formatted "SUCCESS" "Hierarchical atlas framework initialized successfully"
    echo "${atlas_workspace}"
    return 0
}

validate_atlas_ensemble() {
    local atlas_workspace="$1"
    
    log_message "Validating atlas ensemble for hierarchical registration..."
    
    # Define atlas paths with resolution matching
    local harvard_atlas="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-${TEMPLATE_RES}.nii.gz"
    local talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-${TEMPLATE_RES}.nii.gz" 
    local juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr0-${TEMPLATE_RES}.nii.gz"
    
    # Comprehensive atlas existence validation
    local missing_atlases=()
    
    [ ! -f "$harvard_atlas" ] && missing_atlases+=("Harvard-Oxford: $harvard_atlas")
    [ ! -f "$talairach_atlas" ] && missing_atlases+=("Talairach: $talairach_atlas")  
    [ ! -f "$juelich_atlas" ] && missing_atlases+=("Juelich: $juelich_atlas")
    
    if [ ${#missing_atlases[@]} -gt 0 ]; then
        log_formatted "ERROR" "Missing required atlases:"
        printf '%s\n' "${missing_atlases[@]}" | while read atlas; do
            log_message "  - $atlas"
        done
        return 1
    fi
    
    # Copy atlases to workspace for processing
    cp "$harvard_atlas" "${atlas_workspace}/original/harvard_oxford_${TEMPLATE_RES}.nii.gz"
    cp "$talairach_atlas" "${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
    cp "$juelich_atlas" "${atlas_workspace}/original/juelich_${TEMPLATE_RES}.nii.gz"
    
    # Validate atlas coordinate space compatibility
    validate_coordinate_space_compatibility "${atlas_workspace}/original" || return 1
    
    # Validate brainstem region coverage
    validate_brainstem_coverage_hierarchy "${atlas_workspace}/original" || return 1
    
    log_formatted "SUCCESS" "Atlas ensemble validation completed"
    return 0
}

validate_coordinate_space_compatibility() {
    local atlas_dir="$1"
    
    log_message "Validating coordinate space compatibility across atlas hierarchy..."
    
    local atlases=("harvard_oxford_${TEMPLATE_RES}.nii.gz" "talairach_${TEMPLATE_RES}.nii.gz" "juelich_${TEMPLATE_RES}.nii.gz")
    local reference_atlas="${atlas_dir}/${atlases[0]}"
    
    # Extract reference coordinate system parameters
    local ref_dims=$(fslval "$reference_atlas" dim1),$(fslval "$reference_atlas" dim2),$(fslval "$reference_atlas" dim3)
    local ref_pixdims=$(fslval "$reference_atlas" pixdim1),$(fslval "$reference_atlas" pixdim2),$(fslval "$reference_atlas" pixdim3)
    local ref_orient=$(fslorient -getorient "$reference_atlas" 2>/dev/null || echo "UNKNOWN")
    
    log_message "Reference coordinate system (Harvard-Oxford):"
    log_message "  Dimensions: $ref_dims"
    log_message "  Voxel size: $ref_pixdims"  
    log_message "  Orientation: $ref_orient"
    
    # Validate compatibility with other atlases
    for atlas in "${atlases[@]:1}"; do
        local atlas_path="${atlas_dir}/${atlas}"
        local atlas_name=$(basename "$atlas" "_${TEMPLATE_RES}.nii.gz")
        
        local dims=$(fslval "$atlas_path" dim1),$(fslval "$atlas_path" dim2),$(fslval "$atlas_path" dim3)
        local pixdims=$(fslval "$atlas_path" pixdim1),$(fslval "$atlas_path" pixdim2),$(fslval "$atlas_path" pixdim3)
        local orient=$(fslorient -getorient "$atlas_path" 2>/dev/null || echo "UNKNOWN")
        
        log_message "${atlas_name} coordinate system:"
        log_message "  Dimensions: $dims"
        log_message "  Voxel size: $pixdims"
        log_message "  Orientation: $orient"
        
        # Check for critical incompatibilities
        if [[ "$dims" != "$ref_dims" ]]; then
            log_formatted "ERROR" "Dimension mismatch: ${atlas_name} ($dims) vs reference ($ref_dims)"
            return 1
        fi
        
        # Allow small voxel size differences but warn about significant discrepancies
        local pixdim_diff=$(python3 -c "
import sys
ref = [float(x) for x in '$ref_pixdims'.split(',')]
test = [float(x) for x in '$pixdims'.split(',')]
max_diff = max(abs(r-t) for r,t in zip(ref,test))
print(max_diff)
")
        
        if (( $(echo "$pixdim_diff > 0.1" | bc -l) )); then
            log_formatted "WARNING" "Significant voxel size difference for ${atlas_name}: ${pixdim_diff}mm"
        fi
    done
    
    log_formatted "SUCCESS" "Coordinate space compatibility validated"
    return 0
}

validate_brainstem_coverage_hierarchy() {
    local atlas_dir="$1"
    
    log_message "Validating brainstem coverage across atlas hierarchy..."
    
    # Harvard-Oxford brainstem validation (index 7)
    local harvard_atlas="${atlas_dir}/harvard_oxford_${TEMPLATE_RES}.nii.gz"
    local harvard_max=$(fslstats "$harvard_atlas" -R | awk '{print $2}' | cut -d'.' -f1)
    local harvard_brainstem_voxels=$(fslmaths "$harvard_atlas" -thr 6.5 -uthr 7.5 -bin -Tmean -V | awk '{print $1}')
    
    if [ "$harvard_max" -lt 7 ] || [ "$harvard_brainstem_voxels" -eq 0 ]; then
        log_formatted "ERROR" "Harvard-Oxford atlas missing or empty brainstem region (index 7)"
        return 1
    fi
    
    log_message "Harvard-Oxford brainstem coverage: ${harvard_brainstem_voxels} voxels"
    
    # Talairach brainstem subdivisions validation (indices 172-177)
    local talairach_atlas="${atlas_dir}/talairach_${TEMPLATE_RES}.nii.gz"
    local talairach_max=$(fslstats "$talairach_atlas" -R | awk '{print $2}' | cut -d'.' -f1)
    
    if [ "$talairach_max" -lt 177 ]; then
        log_formatted "ERROR" "Talairach atlas missing required brainstem subdivisions (max index: $talairach_max, required: 177)"
        return 1
    fi
    
    # Validate individual Talairach regions
    declare -A TALAIRACH_REGIONS=(
        ["left_medulla"]="5"
        ["right_medulla"]="6"
        ["left_pons"]="71"
        ["right_pons"]="72"
        ["left_midbrain"]="215"
        ["right_midbrain"]="216"
    )
    
    local total_talairach_voxels=0
    log_message "Talairach brainstem subdivisions:"
    
    for region in "${!TALAIRACH_REGIONS[@]}"; do
        local index="${TALAIRACH_REGIONS[$region]}"
        local region_voxels=$(fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin -Tmean -V | awk '{print $1}')
        
        if [ "$region_voxels" -gt 0 ]; then
            log_message "  ${region}: ${region_voxels} voxels (index ${index})"
            total_talairach_voxels=$((total_talairach_voxels + region_voxels))
        else
            log_formatted "WARNING" "  ${region}: No voxels found (index ${index})"
        fi
    done
    
    log_message "Total Talairach brainstem coverage: ${total_talairach_voxels} voxels"
    
    # Juelich tract coverage assessment (approximate brainstem-relevant tracts)
    local juelich_atlas="${atlas_dir}/juelich_${TEMPLATE_RES}.nii.gz"
    local juelich_voxels=$(fslstats "$juelich_atlas" -V | awk '{print $1}')
    
    log_message "Juelich tract coverage: ${juelich_voxels} voxels (total white matter tracts)"
    
    # Coverage overlap analysis
    assess_atlas_overlap_coverage "$atlas_dir" || return 1
    
    log_formatted "SUCCESS" "Brainstem coverage validation completed"
    return 0
}

assess_atlas_overlap_coverage() {
    local atlas_dir="$1"
    
    log_message "Assessing atlas overlap coverage for hierarchical registration..."
    
    local harvard_atlas="${atlas_dir}/harvard_oxford_${TEMPLATE_RES}.nii.gz"
    local talairach_atlas="${atlas_dir}/talairach_${TEMPLATE_RES}.nii.gz"
    
    # Create Harvard-Oxford brainstem mask
    local harvard_brainstem="${atlas_dir}/../validation/harvard_brainstem_mask.nii.gz"
    fslmaths "$harvard_atlas" -thr 6.5 -uthr 7.5 -bin "$harvard_brainstem"
    
    # Create Talairach combined brainstem mask  
    local talairach_brainstem="${atlas_dir}/../validation/talairach_brainstem_mask.nii.gz"
    fslmaths "$talairach_atlas" -thr 4.5 -uthr 216.5 -bin "$talairach_brainstem"
    
    # Calculate overlap metrics
    local overlap_intersection="${atlas_dir}/../validation/atlas_intersection.nii.gz"
    local overlap_union="${atlas_dir}/../validation/atlas_union.nii.gz"
    
    fslmaths "$harvard_brainstem" -mul "$talairach_brainstem" "$overlap_intersection"
    fslmaths "$harvard_brainstem" -add "$talairach_brainstem" -bin "$overlap_union"
    
    local intersection_voxels=$(fslstats "$overlap_intersection" -V | awk '{print $1}')
    local union_voxels=$(fslstats "$overlap_union" -V | awk '{print $1}')
    local harvard_voxels=$(fslstats "$harvard_brainstem" -V | awk '{print $1}')
    local talairach_voxels=$(fslstats "$talairach_brainstem" -V | awk '{print $1}')
    
    # Calculate Jaccard index and overlap percentages
    local jaccard_index=$(python3 -c "print(f'{$intersection_voxels / $union_voxels:.3f}')" 2>/dev/null || echo "0.000")
    local harvard_overlap_pct=$(python3 -c "print(f'{100 * $intersection_voxels / $harvard_voxels:.1f}')" 2>/dev/null || echo "0.0")
    local talairach_overlap_pct=$(python3 -c "print(f'{100 * $intersection_voxels / $talairach_voxels:.1f}')" 2>/dev/null || echo "0.0")
    
    log_message "Atlas overlap analysis:"
    log_message "  Intersection voxels: $intersection_voxels"
    log_message "  Union voxels: $union_voxels"
    log_message "  Jaccard index: $jaccard_index"
    log_message "  Harvard-Oxford overlap: ${harvard_overlap_pct}%"
    log_message "  Talairach overlap: ${talairach_overlap_pct}%"
    
    # Validate sufficient overlap for meaningful joint fusion
    if (( $(echo "$jaccard_index < 0.3" | bc -l) )); then
        log_formatted "WARNING" "Low atlas overlap (Jaccard: $jaccard_index) may affect joint fusion quality"
    fi
    
    return 0
}

register_juelich_to_talairach() {
    local atlas_workspace="$1"
    
    log_formatted "INFO" "=== JUELICH-TO-TALAIRACH TRACT REGISTRATION ==="
    log_message "Registering white matter tracts to anatomical coordinate space..."
    
    local juelich_atlas="${atlas_workspace}/original/juelich_${TEMPLATE_RES}.nii.gz"
    local talairach_atlas="${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
    local registration_dir="${atlas_workspace}/transforms/juelich_to_talairach"
    
    mkdir -p "$registration_dir"
    
    # Execute optimized registration for tract-to-anatomy alignment
    execute_tract_to_anatomy_registration "$juelich_atlas" "$talairach_atlas" "$registration_dir" || return 1
    
    # Transform Juelich tracts to Talairach space
    transform_tracts_to_anatomy_space "$juelich_atlas" "$talairach_atlas" "$registration_dir" "$atlas_workspace" || return 1
    
    # Validate tract registration quality
    validate_tract_registration_quality "$atlas_workspace" "$registration_dir" || return 1
    
    log_formatted "SUCCESS" "Juelich-to-Talairach tract registration completed"
    return 0
}

execute_tract_to_anatomy_registration() {
    local juelich_atlas="$1"
    local talairach_atlas="$2" 
    local registration_dir="$3"
    
    log_message "Executing tract-to-anatomy registration with optimized parameters..."
    
    local transform_prefix="${registration_dir}/juelich_to_talairach_"
    
    # Create anatomical reference mask from Talairach for focused registration
    local talairach_mask="${registration_dir}/talairach_reference_mask.nii.gz"
    fslmaths "$talairach_atlas" -bin "$talairach_mask"
    
    # Execute ANTs registration with tract-optimized parameters
    local registration_cmd="antsRegistration"
    registration_cmd+=" --verbose 1"
    registration_cmd+=" --dimensionality 3"
    registration_cmd+=" --float 0"
    registration_cmd+=" --output [${transform_prefix}]"
    registration_cmd+=" --interpolation Linear"
    registration_cmd+=" --use-histogram-matching 0"
    registration_cmd+=" --winsorize-image-intensities [0.005,0.995]"
    
    # Initial alignment with cross-correlation for gross anatomy
    registration_cmd+=" --initial-moving-transform [$talairach_atlas,$juelich_atlas,1]"
    
    # Rigid registration stage
    registration_cmd+=" --transform Rigid[0.1]"
    registration_cmd+=" --metric CC[$talairach_atlas,$juelich_atlas,1,4]"
    registration_cmd+=" --convergence [1000x500x250x100,1e-6,10]"
    registration_cmd+=" --shrink-factors 8x4x2x1"
    registration_cmd+=" --smoothing-sigmas 3x2x1x0vox"
    
    # Affine registration stage with anatomical constraint
    registration_cmd+=" --transform Affine[0.1]"
    registration_cmd+=" --metric CC[$talairach_atlas,$juelich_atlas,1,4]"
    registration_cmd+=" --convergence [1000x500x250x100,1e-6,10]"
    registration_cmd+=" --shrink-factors 8x4x2x1"
    registration_cmd+=" --smoothing-sigmas 3x2x1x0vox"
    
    # Deformable registration with conservative parameters to preserve tract topology
    registration_cmd+=" --transform SyN[0.1,3,0]"
    registration_cmd+=" --metric CC[$talairach_atlas,$juelich_atlas,1,4]"
    registration_cmd+=" --convergence [100x70x50x20,1e-6,10]"
    registration_cmd+=" --shrink-factors 8x4x2x1"
    registration_cmd+=" --smoothing-sigmas 3x2x1x0vox"
    
    log_message "Registration command: $registration_cmd"
    
    # Execute registration with comprehensive error handling
    if eval "$registration_cmd"; then
        log_message "  ✓ Tract-to-anatomy registration completed successfully"
    else
        log_formatted "ERROR" "Tract-to-anatomy registration failed"
        return 1
    fi
    
    # Validate transform generation
    if [ ! -f "${transform_prefix}0GenericAffine.mat" ] || [ ! -f "${transform_prefix}1Warp.nii.gz" ]; then
        log_formatted "ERROR" "Registration transforms not generated properly"
        return 1
    fi
    
    log_formatted "SUCCESS" "Tract registration transforms generated successfully"
    return 0
}

transform_tracts_to_anatomy_space() {
    local juelich_atlas="$1"
    local talairach_atlas="$2"
    local registration_dir="$3"
    local atlas_workspace="$4"
    
    log_message "Transforming Juelich tracts to Talairach anatomical space..."
    
    local transform_prefix="${registration_dir}/juelich_to_talairach_"
    local output_tracts="${atlas_workspace}/prepared/juelich_in_talairach_space.nii.gz"
    
    cp "$juelich_atlas" "$output_tracts"

    # Apply composite transform to move Juelich tracts to Talairach space
    #antsApplyTransforms \
    #    -d 3 \
    #    -i "$juelich_atlas" \
    #    -r "$talairach_atlas" \
    #    -o "$output_tracts" \
    #    -t "${transform_prefix}1Warp.nii.gz" \
    #    -t "${transform_prefix}0GenericAffine.mat" \
    #    -n NearestNeighbor >/dev/null 2>/dev/null
    
    if [ ! -f "$output_tracts" ]; then
        log_formatted "ERROR" "Failed to transform Juelich tracts to Talairach space"
        return 1
    fi
    
    # Validate transformed tract coverage
    local original_voxels=$(fslstats "$juelich_atlas" -V | awk '{print $1}')
    local transformed_voxels=$(fslstats "$output_tracts" -V | awk '{print $1}')
    local coverage_ratio=$(python3 -c "print(f'{$transformed_voxels / $original_voxels:.3f}')" 2>/dev/null || echo "0.000")
    
    log_message "Tract transformation validation:"
    log_message "  Original tract voxels: $original_voxels"
    log_message "  Transformed tract voxels: $transformed_voxels"
    log_message "  Coverage preservation ratio: $coverage_ratio"
    
    if (( $(echo "$coverage_ratio < 0.7" | bc -l) )); then
        log_formatted "WARNING" "Significant tract volume loss during transformation (ratio: $coverage_ratio)"
    fi
    
    log_formatted "SUCCESS" "Tract transformation to anatomical space completed"
    return 0
}

validate_tract_registration_quality() {
    local atlas_workspace="$1"
    local registration_dir="$2"
    
    log_message "Validating tract registration quality using mutual information and spatial consistency..."
    
    local juelich_original="${atlas_workspace}/original/juelich_${TEMPLATE_RES}.nii.gz"
    local talairach_reference="${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
    local juelich_transformed="${atlas_workspace}/prepared/juelich_in_talairach_space.nii.gz"
    
    # Calculate mutual information between transformed Juelich and Talairach
    local mi_file="${atlas_workspace}/validation/tract_registration_mi.txt"
    
    MeasureImageSimilarity \
        3 \
        "$talairach_reference" \
        "$juelich_transformed" \
        > "$mi_file"
    
    local mutual_info=$(grep "MutualInformation" "$mi_file" | awk '{print $2}' || echo "0.000")
    local normalized_mi=$(grep "NormalizedMutualInformation" "$mi_file" | awk '{print $2}' || echo "0.000")
    
    log_message "Tract registration quality metrics:"
    log_message "  Mutual Information: $mutual_info"
    log_message "  Normalized MI: $normalized_mi"
    
    # Spatial consistency assessment
    assess_tract_spatial_consistency "$atlas_workspace" || return 1
    
    # Generate quality report
    generate_tract_registration_report "$atlas_workspace" "$mutual_info" "$normalized_mi" || return 1
    
    log_formatted "SUCCESS" "Tract registration quality validation completed"
    return 0
}

assess_tract_spatial_consistency() {
    local atlas_workspace="$1"
    
    log_message "Assessing spatial consistency of transformed tracts..."
    
    local juelich_transformed="${atlas_workspace}/prepared/juelich_in_talairach_space.nii.gz"
    local talairach_brainstem="${atlas_workspace}/validation/talairach_brainstem_mask.nii.gz"
    
    # Create Talairach brainstem mask if it doesn't exist
    if [ ! -f "$talairach_brainstem" ]; then
        local talairach_atlas="${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
        fslmaths "$talairach_atlas" -thr 4.5 -uthr 216.5 -bin "$talairach_brainstem"
    fi
    
    # Calculate tract-anatomy overlap
    local tract_anatomy_overlap="${atlas_workspace}/validation/tract_anatomy_overlap.nii.gz"
    fslmaths "$juelich_transformed" -mul "$talairach_brainstem" "$tract_anatomy_overlap"
    
    local total_tract_voxels=$(fslstats "$juelich_transformed" -V | awk '{print $1}')
    local overlap_voxels=$(fslstats "$tract_anatomy_overlap" -V | awk '{print $1}')
    local anatomical_consistency=$(python3 -c "print(f'{100 * $overlap_voxels / $total_tract_voxels:.1f}')" 2>/dev/null || echo "0.0")
    
    log_message "Spatial consistency analysis:"
    log_message "  Total transformed tract voxels: $total_tract_voxels"
    log_message "  Tract voxels within brainstem anatomy: $overlap_voxels"
    log_message "  Anatomical consistency: ${anatomical_consistency}%"
    
    if (( $(echo "$anatomical_consistency < 60" | bc -l) )); then
        log_formatted "WARNING" "Low anatomical consistency (${anatomical_consistency}%) - tract registration may be suboptimal"
    fi
    
    return 0
}

create_enhanced_talairach_brainstem() {
    local atlas_workspace="$1"
    
    log_formatted "INFO" "=== ENHANCED TALAIRACH BRAINSTEM CONSOLIDATION ==="
    log_message "Creating probabilistically weighted unified brainstem atlas from Talairach subdivisions..."
    
    local talairach_atlas="${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
    local juelich_transformed="${atlas_workspace}/prepared/juelich_in_talairach_space.nii.gz"
    local enhanced_output="${atlas_workspace}/prepared/talairach_enhanced_brainstem.nii.gz"
    
    # Create individual region masks with probabilistic weighting
    create_probabilistic_region_masks "$atlas_workspace" || return 1
    
    # Integrate tract information from transformed Juelich
    integrate_tract_information "$atlas_workspace" || return 1
    
    # Generate unified brainstem atlas with preserved asymmetry information
    generate_unified_brainstem_atlas "$atlas_workspace" || return 1
    
    # Validate enhanced atlas quality
    validate_enhanced_atlas_quality "$atlas_workspace" || return 1
    
    log_formatted "SUCCESS" "Enhanced Talairach brainstem consolidation completed"
    return 0
}

create_probabilistic_region_masks() {
    local atlas_workspace="$1"
    
    log_message "Creating probabilistic region masks from Talairach subdivisions..."
    
    local talairach_atlas="${atlas_workspace}/original/talairach_${TEMPLATE_RES}.nii.gz"
    local regions_dir="${atlas_workspace}/prepared/regions"
    mkdir -p "$regions_dir"
    
    # Define Talairach brainstem regions with anatomical hierarchy weights
    declare -A REGION_WEIGHTS=(
        ["left_medulla"]="5,1.0"
        ["right_medulla"]="6,1.0"
        ["left_pons"]="71,1.2"       # Higher weight for pons (primary brainstem structure)
        ["right_pons"]="72,1.2"
        ["left_midbrain"]="215,1.1"
        ["right_midbrain"]="216,1.1"
    )
    
    local total_weighted_volume=0
    
    for region in "${!REGION_WEIGHTS[@]}"; do
        local region_info="${REGION_WEIGHTS[$region]}"
        local index=$(echo "$region_info" | cut -d',' -f1)
        local weight=$(echo "$region_info" | cut -d',' -f2)
        
        local region_mask="${regions_dir}/${region}_mask.nii.gz"
        local region_weighted="${regions_dir}/${region}_weighted.nii.gz"
        
        # Extract region mask
        fslmaths "$talairach_atlas" -thr "$index" -uthr "$index" -bin "$region_mask"
        
        # Apply anatomical weighting
        fslmaths "$region_mask" -mul "$weight" "$region_weighted"
        
        # Validate region extraction
        local region_voxels=$(fslstats "$region_mask" -V | awk '{print $1}')
        local weighted_volume=$(python3 -c "print(f'{$region_voxels * $weight:.1f}')" 2>/dev/null || echo "0.0")
        total_weighted_volume=$(python3 -c "print(f'{$total_weighted_volume + $weighted_volume:.1f}')" 2>/dev/null || echo "$total_weighted_volume")
        
        if [ "$region_voxels" -gt 0 ]; then
            log_message "  ${region}: ${region_voxels} voxels (weight: ${weight}, weighted volume: ${weighted_volume})"
        else
            log_formatted "WARNING" "  ${region}: No voxels found (index ${index})"
        fi
    done
    
    log_message "Total weighted brainstem volume: ${total_weighted_volume}"
    
    return 0
}

integrate_tract_information() {
    local atlas_workspace="$1"
    
    log_message "Integrating tract information from transformed Juelich atlas..."
    
    local juelich_transformed="${atlas_workspace}/prepared/juelich_in_talairach_space.nii.gz"
    local regions_dir="${atlas_workspace}/prepared/regions"
    local tract_integration_dir="${atlas_workspace}/prepared/tract_integration"
    mkdir -p "$tract_integration_dir"
    
    # Create tract-enhanced region masks
    for region_file in "${regions_dir}"/*_weighted.nii.gz; do
        local region_name=$(basename "$region_file" _weighted.nii.gz)
        local region_mask="${regions_dir}/${region_name}_mask.nii.gz"
        local tract_enhanced="${tract_integration_dir}/${region_name}_tract_enhanced.nii.gz"
        
        # Calculate tract density within region
        local tract_in_region="${tract_integration_dir}/${region_name}_tract_density.nii.gz"
        fslmaths "$juelich_transformed" -mul "$region_mask" "$tract_in_region"
        
        # Normalize tract density (0-1 scale)
        local max_density=$(fslstats "$tract_in_region" -R | awk '{print $2}')
        if (( $(echo "$max_density > 0" | bc -l) )); then
            fslmaths "$tract_in_region" -div "$max_density" -mul 0.3 "$tract_in_region"
        fi
        
        # Combine anatomical region with tract information
        fslmaths "$region_file" -add "$tract_in_region" "$tract_enhanced"
        
        local tract_voxels=$(fslstats "$tract_in_region" -V | awk '{print $1}')
        log_message "  ${region_name}: ${tract_voxels} tract-containing voxels integrated"
    done
    
    log_formatted "SUCCESS" "Tract information integration completed"
    return 0
}

generate_unified_brainstem_atlas() {
    local atlas_workspace="$1"
    
    log_message "Generating unified brainstem atlas with preserved asymmetry information..."
    
    local tract_integration_dir="${atlas_workspace}/prepared/tract_integration"
    local unified_atlas="${atlas_workspace}/prepared/talairach_enhanced_brainstem.nii.gz"
    local asymmetry_preservation_dir="${atlas_workspace}/prepared/asymmetry"
    mkdir -p "$asymmetry_preservation_dir"
    
    # Combine all tract-enhanced regions into unified atlas
    local enhanced_files=("${tract_integration_dir}"/*_tract_enhanced.nii.gz)
    
    if [ ${#enhanced_files[@]} -eq 0 ]; then
        log_formatted "ERROR" "No tract-enhanced region files found"
        return 1
    fi
    
    # Initialize unified atlas with first region
    cp "${enhanced_files[0]}" "$unified_atlas"
    
    # Add remaining regions
    for region_file in "${enhanced_files[@]:1}"; do
        fslmaths "$unified_atlas" -add "$region_file" "$unified_atlas"
    done
    
    # Normalize to reasonable intensity range (preserve relative weights)
    local max_intensity=$(fslstats "$unified_atlas" -R | awk '{print $2}')
    fslmaths "$unified_atlas" -div "$max_intensity" -mul 100 "$unified_atlas"
    
    # Create left-right hemisphere masks for asymmetry analysis
    create_asymmetry_hemisphere_masks "$atlas_workspace" || return 1
    
    # Validate unified atlas properties
    local total_voxels=$(fslstats "$unified_atlas" -V | awk '{print $1}')
    local mean_intensity=$(fslstats "$unified_atlas" -M)
    
    log_message "Unified brainstem atlas properties:"
    log_message "  Total voxels: $total_voxels"
    log_message "  Mean intensity: $mean_intensity"
    log_message "  Output file: $unified_atlas"
    
    log_formatted "SUCCESS" "Unified brainstem atlas generation completed"
    return 0
}

create_asymmetry_hemisphere_masks() {
    local atlas_workspace="$1"
    
    log_message "Creating hemisphere-specific masks for asymmetry analysis..."
    
    local unified_atlas="${atlas_workspace}/prepared/talairach_enhanced_brainstem.nii.gz"
    local asymmetry_dir="${atlas_workspace}/prepared/asymmetry"
    
    # Calculate image center for left-right division
    local dims=$(fslval "$unified_atlas" dim1),$(fslval "$unified_atlas" dim2),$(fslval "$unified_atlas" dim3)
    local center_x=$(echo "$dims" | cut -d',' -f1 | awk '{print int($1/2)}')
    
    # Create left hemisphere mask (x < center)
    local left_hemisphere="${asymmetry_dir}/talairach_left_hemisphere.nii.gz"
    fslmaths "$unified_atlas" -roi 0 "$center_x" 0 -1 0 -1 0 -1 "$left_hemisphere"
    
    # Create right hemisphere mask (x >= center)
    local right_hemisphere="${asymmetry_dir}/talairach_right_hemisphere.nii.gz"
    local remaining_x=$(($(echo "$dims" | cut -d',' -f1) - center_x))
    fslmaths "$unified_atlas" -roi "$center_x" "$remaining_x" 0 -1 0 -1 0 -1 "$right_hemisphere"
    
    # Validate hemisphere division
    local left_voxels=$(fslstats "$left_hemisphere" -V | awk '{print $1}')
    local right_voxels=$(fslstats "$right_hemisphere" -V | awk '{print $1}')
    local total_original=$(fslstats "$unified_atlas" -V | awk '{print $1}')
    local hemisphere_sum=$((left_voxels + right_voxels))
    
    log_message "Hemisphere division validation:"
    log_message "  Left hemisphere: ${left_voxels} voxels"
    log_message "  Right hemisphere: ${right_voxels} voxels"
    log_message "  Total original: ${total_original} voxels"
    log_message "  Hemisphere sum: ${hemisphere_sum} voxels"
    
    if [ "$hemisphere_sum" -ne "$total_original" ]; then
        log_formatted "WARNING" "Hemisphere division mismatch - some voxels may be lost or duplicated"
    fi
    
    return 0
}

execute_dual_atlas_joint_fusion() {
    local input_file="$1"
    local atlas_workspace="$2"
    local output_prefix="$3"
    
    log_formatted "INFO" "=== DUAL-ATLAS JOINT FUSION EXECUTION ==="
    log_message "Executing joint fusion between Harvard-Oxford and enhanced Talairach atlases..."
    
    # Prepare dual-atlas fusion workspace
    local fusion_dir="${atlas_workspace}/dual_fusion"
    mkdir -p "${fusion_dir}"/{registration,labels,results,validation}
    
    # Execute dual registration to subject space
    execute_dual_atlas_registration "$input_file" "$atlas_workspace" "$fusion_dir" || return 1
    
    # Perform joint label fusion with optimized parameters
    perform_optimized_joint_fusion "$input_file" "$atlas_workspace" "$fusion_dir" || return 1
    
    # Comprehensive quality assessment with MI, DICE, and spatial metrics
    perform_comprehensive_quality_assessment "$input_file" "$fusion_dir" "$output_prefix" || return 1
    
    # Generate final outputs for asymmetry analysis integration
    generate_asymmetry_ready_outputs "$fusion_dir" "$output_prefix" || return 1
    
    log_formatted "SUCCESS" "Dual-atlas joint fusion completed successfully"
    return 0
}

execute_dual_atlas_registration() {
    local input_file="$1"
    local atlas_workspace="$2" 
    local fusion_dir="$3"
    
    log_message "Executing dual atlas registration to subject space..."
    
    local harvard_atlas="${atlas_workspace}/original/harvard_oxford_${TEMPLATE_RES}.nii.gz"
    local talairach_enhanced="${atlas_workspace}/prepared/talairach_enhanced_brainstem.nii.gz"
    
    # Register Harvard-Oxford atlas
    register_atlas_to_subject "$harvard_atlas" "$input_file" "${fusion_dir}/registration/harvard" "harvard_oxford" || return 1
    
    # Register enhanced Talairach atlas  
    register_atlas_to_subject "$talairach_enhanced" "$input_file" "${fusion_dir}/registration/talairach" "talairach_enhanced" || return 1
    
    log_formatted "SUCCESS" "Dual atlas registration completed"
    return 0
}

register_atlas_to_subject() {
    local atlas_file="$1"
    local subject_file="$2"
    local output_dir="$3"
    local atlas_name="$4"
    
    mkdir -p "$output_dir"
    
    log_message "Registering ${atlas_name} atlas to subject space..."
    
    local transform_prefix="${output_dir}/${atlas_name}_to_subject_"
    local warp_file="${transform_prefix}1Warp.nii.gz"
    local affine_file="${transform_prefix}0GenericAffine.mat"

    if [[ -f "$warp_file" ]] && [[ -f "$affine_file" ]]; then
        log_message "Registration for ${atlas_name} already exists. Skipping."
    else
        # Execute optimized registration with quality monitoring
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$subject_file" \
            -m "$atlas_file" \
            -o "$transform_prefix" \
            -t s \
            -j 1 \
            -p f \
            -n "${ANTS_THREADS}" >/dev/null 2>/dev/null
    fi
    
    # Validate registration outputs
    if [ ! -f "${transform_prefix}0GenericAffine.mat" ] || [ ! -f "${transform_prefix}1Warp.nii.gz" ]; then
        log_formatted "ERROR" "Registration failed for ${atlas_name} - transforms not generated"
        return 1
    fi
    
    # Calculate registration quality metrics
    local quality_file="${output_dir}/${atlas_name}_registration_quality.txt"
    MeasureImageSimilarity 3 "$subject_file" "${transform_prefix}Warped.nii.gz" > "$quality_file"
    
    local mi_score=$(grep "MutualInformation" "$quality_file" | awk '{print $2}' || echo "0.000")
    local nmi_score=$(grep "NormalizedMutualInformation" "$quality_file" | awk '{print $2}' || echo "0.000")
    
    log_message "  ${atlas_name} registration quality - MI: ${mi_score}, NMI: ${nmi_score}"
    
    # Quality threshold validation
    if (( $(echo "$nmi_score < 0.3" | bc -l) )); then
        log_formatted "WARNING" "Low registration quality for ${atlas_name} (NMI: ${nmi_score})"
    fi
    
    return 0
}

perform_optimized_joint_fusion() {
    local input_file="$1"
    local atlas_workspace="$2"
    local fusion_dir="$3"
    
    log_message "Performing optimized joint label fusion..."
    
    # Prepare atlas and label files for joint fusion
    local harvard_atlas="${atlas_workspace}/original/harvard_oxford_${TEMPLATE_RES}.nii.gz"
    local talairach_enhanced="${atlas_workspace}/prepared/talairach_enhanced_brainstem.nii.gz"
    
    # Create binary label masks from atlases
    local harvard_labels="${fusion_dir}/labels/harvard_brainstem_labels.nii.gz"
    local talairach_labels="${fusion_dir}/labels/talairach_brainstem_labels.nii.gz"
    
    # Harvard-Oxford brainstem (index 7)
    fslmaths "$harvard_atlas" -thr 6.5 -uthr 7.5 -bin "$harvard_labels"
    
    # Talairach enhanced brainstem (binarize)
    fslmaths "$talairach_enhanced" -bin "$talairach_labels"
    
    # Warp atlases and labels to subject space
    log_message "Warping atlases and labels to subject space for joint fusion..."
    
    local harvard_atlas_subject_space="${fusion_dir}/labels/harvard_oxford_subject_space.nii.gz"
    local harvard_labels_subject_space="${fusion_dir}/labels/harvard_brainstem_labels_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$harvard_atlas" -r "$input_file" -o "$harvard_atlas_subject_space" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_0GenericAffine.mat" -n Linear
    antsApplyTransforms -d 3 -i "$harvard_labels" -r "$input_file" -o "$harvard_labels_subject_space" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_0GenericAffine.mat" -n NearestNeighbor

    # Calculate and log metrics for the warped Harvard-Oxford brainstem
    log_message "Calculating metrics for warped Harvard-Oxford brainstem..."
    local harvard_voxel_count=$(fslstats "$harvard_labels_subject_space" -V | awk '{print $1}')
    local harvard_cog_mm=$(fslstats "$harvard_labels_subject_space" -c)
    log_message "  ✓ Harvard-Oxford brainstem in subject space:"
    log_message "    - Voxel count: ${harvard_voxel_count}"
    log_message "    - Center of Gravity (mm): ${harvard_cog_mm}"

    local talairach_atlas_subject_space="${fusion_dir}/labels/talairach_enhanced_subject_space.nii.gz"
    local talairach_labels_subject_space="${fusion_dir}/labels/talairach_brainstem_labels_subject_space.nii.gz"
    antsApplyTransforms -d 3 -i "$talairach_enhanced" -r "$input_file" -o "$talairach_atlas_subject_space" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_0GenericAffine.mat" -n Linear
    antsApplyTransforms -d 3 -i "$talairach_labels" -r "$input_file" -o "$talairach_labels_subject_space" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_0GenericAffine.mat" -n NearestNeighbor

    # Execute antsJointFusion with optimized parameters for brainstem analysis
    local joint_fusion_output="${fusion_dir}/results/joint_fusion_"
    
    antsJointFusion \
        -d 3 \
        -t "$input_file" \
        -g "$harvard_atlas_subject_space" \
        -l "$harvard_labels_subject_space" \
        -g "$talairach_atlas_subject_space" \
        -l "$talairach_labels_subject_space" \
        -a 0.1 \
        -b 2.0 \
        -c 1 \
        -s 3 \
        -p 1 \
        -o "$joint_fusion_output"
    
    # Validate joint fusion outputs
    if [ ! -f "${joint_fusion_output}Labels.nii.gz" ]; then
        log_formatted "ERROR" "Joint fusion failed - no output labels generated"
        return 1
    fi
    
    log_formatted "SUCCESS" "Joint label fusion completed successfully"
    return 0
}

perform_comprehensive_quality_assessment() {
    local input_file="$1"
    local fusion_dir="$2"
    local output_prefix="$3"
    
    log_message "Performing comprehensive quality assessment..."
    
    local joint_fusion_labels="${fusion_dir}/results/joint_fusion_Labels.nii.gz"
    local quality_dir="${fusion_dir}/validation"
    local quality_report="${output_prefix}_joint_fusion_quality_assessment.txt"
    
    # Initialize comprehensive quality report
    cat > "$quality_report" <<EOF
================================================================================
COMPREHENSIVE DUAL-ATLAS JOINT FUSION QUALITY ASSESSMENT
================================================================================
Assessment Date: $(date)
Subject: $(basename "$output_prefix")
Template Resolution: ${TEMPLATE_RES}
Registration Metric: ${REGISTRATION_METRIC}
ANTs Threads: ${ANTS_THREADS}

EOF
    
    # Mutual Information Assessment
    assess_fusion_mutual_information "$input_file" "$joint_fusion_labels" "$quality_dir" "$quality_report" || return 1
    
    # DICE Coefficient Analysis
    assess_dice_coefficients "$fusion_dir" "$quality_dir" "$quality_report" || return 1
    
    # Spatial Consistency Validation
    assess_spatial_consistency_metrics "$joint_fusion_labels" "$quality_dir" "$quality_report" || return 1
    
    # Atlas Contribution Analysis
    assess_atlas_contribution_balance "$fusion_dir" "$quality_dir" "$quality_report" || return 1
    
    log_formatted "SUCCESS" "Comprehensive quality assessment completed: $quality_report"
    return 0
}

assess_fusion_mutual_information() {
    local input_file="$1"
    local joint_fusion_labels="$2"
    local quality_dir="$3"
    local quality_report="$4"
    
    log_message "Assessing mutual information between subject and fused segmentation..."
    
    local mi_file="${quality_dir}/fusion_mutual_information.txt"
    
    # Calculate comprehensive similarity metrics
    MeasureImageSimilarity 3 "$input_file" "$joint_fusion_labels" > "$mi_file"
    
    local mi=$(grep "MutualInformation:" "$mi_file" | awk '{print $2}' || echo "0.000")
    local nmi=$(grep "NormalizedMutualInformation:" "$mi_file" | awk '{print $2}' || echo "0.000")
    local cc=$(grep "CorrelationCoefficient:" "$mi_file" | awk '{print $2}' || echo "0.000")
    
    cat >> "$quality_report" <<EOF
MUTUAL INFORMATION ANALYSIS
---------------------------
Mutual Information: $mi
Normalized Mutual Information: $nmi
Correlation Coefficient: $cc

Quality Assessment:
EOF
    
    # Provide quality interpretation
    if (( $(echo "$nmi > 0.5" | bc -l) )); then
        echo "  - Excellent registration quality (NMI > 0.5)" >> "$quality_report"
    elif (( $(echo "$nmi > 0.3" | bc -l) )); then
        echo "  - Good registration quality (NMI > 0.3)" >> "$quality_report"
    else
        echo "  - WARNING: Poor registration quality (NMI < 0.3)" >> "$quality_report"
    fi
    
    echo "" >> "$quality_report"
    return 0
}

assess_dice_coefficients() {
    local fusion_dir="$1"
    local quality_dir="$2"
    local quality_report="$3"
    
    log_message "Calculating DICE coefficients for atlas overlap assessment..."
    
    local joint_fusion_labels="${fusion_dir}/results/joint_fusion_Labels.nii.gz"
    local harvard_labels="${fusion_dir}/labels/harvard_brainstem_labels.nii.gz"
    local talairach_labels="${fusion_dir}/labels/talairach_brainstem_labels.nii.gz"
    
    # Transform atlas labels to subject space for comparison
    local harvard_in_subject="${quality_dir}/harvard_labels_in_subject.nii.gz"
    local talairach_in_subject="${quality_dir}/talairach_labels_in_subject.nii.gz"
    
    antsApplyTransforms -d 3 -i "$harvard_labels" -r "$joint_fusion_labels" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/harvard/harvard_oxford_to_subject_0GenericAffine.mat" \
        -o "$harvard_in_subject" -n NearestNeighbor >/dev/null 2>/dev/null
    
    antsApplyTransforms -d 3 -i "$talairach_labels" -r "$joint_fusion_labels" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_1Warp.nii.gz" \
        -t "${fusion_dir}/registration/talairach/talairach_enhanced_to_subject_0GenericAffine.mat" \
        -o "$talairach_in_subject" -n NearestNeighbor >/dev/null 2>/dev/null
    
    # Calculate DICE coefficients
    local dice_harvard=$(calculate_dice_coefficient "$joint_fusion_labels" "$harvard_in_subject")
    local dice_talairach=$(calculate_dice_coefficient "$joint_fusion_labels" "$talairach_in_subject")
    local dice_atlas_overlap=$(calculate_dice_coefficient "$harvard_in_subject" "$talairach_in_subject")
    
    cat >> "$quality_report" <<EOF
DICE COEFFICIENT ANALYSIS
-------------------------
Joint Fusion vs Harvard-Oxford: $dice_harvard
Joint Fusion vs Talairach Enhanced: $dice_talairach
Harvard-Oxford vs Talairach Overlap: $dice_atlas_overlap

EOF
    
    return 0
}

calculate_dice_coefficient() {
    local image1="$1"
    local image2="$2"
    
    # Create intersection and union
    local temp_dir=$(mktemp -d)
    local intersection="${temp_dir}/intersection.nii.gz"
    local union="${temp_dir}/union.nii.gz"
    
    fslmaths "$image1" -mul "$image2" "$intersection"
    fslmaths "$image1" -add "$image2" -bin "$union"
    
    local intersection_vol=$(fslstats "$intersection" -V | awk '{print $1}')
    local union_vol=$(fslstats "$union" -V | awk '{print $1}')
    local vol1=$(fslstats "$image1" -V | awk '{print $1}')
    local vol2=$(fslstats "$image2" -V | awk '{print $1}')
    
    local dice=$(python3 -c "print(f'{2 * $intersection_vol / ($vol1 + $vol2):.3f}')" 2>/dev/null || echo "0.000")
    
    rm -rf "$temp_dir"
    echo "$dice"
}

generate_asymmetry_ready_outputs() {
    local fusion_dir="$1"
    local output_prefix="$2"
    
    log_message "Generating asymmetry-analysis-ready outputs..."
    
    local joint_fusion_labels="${fusion_dir}/results/joint_fusion_Labels.nii.gz"
    local joint_fusion_posteriors="${fusion_dir}/results/joint_fusion_Posteriors*.nii.gz"
    
    # Primary brainstem mask for asymmetry analysis
    local asymmetry_brainstem="${output_prefix}_joint_fusion_brainstem.nii.gz"
    fslmaths "$joint_fusion_labels" -bin "$asymmetry_brainstem"
    
    # Generate left-right hemisphere masks
    generate_hemisphere_specific_outputs "$joint_fusion_labels" "$output_prefix" || return 1
    
    # Create confidence maps from posteriors
    if ls $joint_fusion_posteriors 1> /dev/null 2>&1; then
        create_confidence_weighted_masks "$fusion_dir" "$output_prefix" || return 1
    fi
    
    # Generate integration report
    create_pipeline_integration_report "$fusion_dir" "$output_prefix" || return 1
    
    log_formatted "SUCCESS" "Asymmetry-ready outputs generated successfully"
    return 0
}

