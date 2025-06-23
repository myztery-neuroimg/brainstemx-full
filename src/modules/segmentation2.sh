#!/bin/bash
# src/modules/segmentation.sh - Updated to use hierarchical joint fusion

source "config/default_config.sh"
source "src/modules/environment.sh"

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/hierarchical_joint_fusion.sh"

# Main segmentation function - now using hierarchical joint fusion
extract_brainstem() {
    local input_file="$1"
    local input_basename="$2"
    local flair_file="$3"  # Optional FLAIR file
    
    log_formatted "INFO" "=== BRAINSTEM SEGMENTATION (HIERARCHICAL JOINT FUSION) ==="
    log_message "Processing: $input_file"
    log_message "Basename: $input_basename"
    [[ -n "$flair_file" ]] && log_message "FLAIR file: $flair_file"
    
    # Validate input file
    if [[ ! -f "$input_file" ]]; then
        log_formatted "ERROR" "Input file does not exist: $input_file"
        return 1
    fi
    
    # Create output directory structure
    local brainstem_dir="${RESULTS_DIR}/segmentation"
    mkdir -p "$brainstem_dir"
    
    # Create temporary workspace
    local temp_dir=$(mktemp -d -p "${RESULTS_DIR}" segmentation_XXXXXX)
    
    # Set output prefix
    local output_prefix="${brainstem_dir}/${input_basename}"
    
    # Execute hierarchical joint fusion
    if execute_hierarchical_joint_fusion "$input_file" "$output_prefix" "$temp_dir"; then
        log_formatted "SUCCESS" "Hierarchical joint fusion segmentation completed"
    else
        log_formatted "ERROR" "Hierarchical joint fusion segmentation failed"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Enhance with FLAIR data if available
    if [[ -n "$flair_file" ]] && [[ -f "$flair_file" ]]; then
        enhance_segmentation_with_flair "$output_prefix" "$flair_file" || {
            log_formatted "WARNING" "FLAIR enhancement failed, continuing with T1-based segmentation"
        }
    fi
    
    # Generate comprehensive segmentation report
    generate_segmentation_report "$output_prefix" "$input_file" "$flair_file" || {
        log_formatted "WARNING" "Report generation failed"
    }
    
    # Clean up temporary files
    rm -rf "$temp_dir"
    
    log_formatted "SUCCESS" "Brainstem segmentation completed successfully"
    return 0
}

enhance_segmentation_with_flair() {
    local output_prefix="$1"
    local flair_file="$2"
    
    log_message "Enhancing segmentation with FLAIR intensity information..."
    
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    local flair_intensity="${output_prefix}_brainstem_flair_intensity.nii.gz"
    
    if [[ ! -f "$brainstem_mask" ]]; then
        log_formatted "ERROR" "Brainstem mask not found for FLAIR enhancement"
        return 1
    fi
    
    # Create FLAIR intensity mask
    fslmaths "$flair_file" -mul "$brainstem_mask" "$flair_intensity"
    
    # Enhance Talairach subdivisions with FLAIR
    local subdivision_dir="$(dirname "$output_prefix")/talairach_subdivisions"
    if [[ -d "$subdivision_dir" ]]; then
        local flair_subdivision_dir="${subdivision_dir}_flair"
        mkdir -p "$flair_subdivision_dir"
        
        for region_mask in "$subdivision_dir"/*.nii.gz; do
            local region_name=$(basename "$region_mask" .nii.gz)
            local flair_region="${flair_subdivision_dir}/${region_name}_flair.nii.gz"
            fslmaths "$flair_file" -mul "$region_mask" "$flair_region"
        done
        
        log_message "  ✓ FLAIR-enhanced subdivisions: $flair_subdivision_dir"
    fi
    
    log_message "  ✓ FLAIR intensity enhancement completed"
    return 0
}

generate_segmentation_report() {
    local output_prefix="$1"
    local input_file="$2"
    local flair_file="$3"
    
    log_message "Generating comprehensive segmentation report..."
    
    local report_file="${output_prefix}_segmentation_report.txt"
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    
    cat > "$report_file" <<EOF
================================================================================
HIERARCHICAL JOINT FUSION SEGMENTATION REPORT
================================================================================
Generated: $(date)
Subject: $(basename "$output_prefix")
Template Resolution: ${DEFAULT_TEMPLATE_RES:-2mm}

INPUT FILES
-----------
T1 Image: $input_file
$([ -n "$flair_file" ] && echo "FLAIR Image: $flair_file")

PRIMARY OUTPUTS
---------------
1. Unified Brainstem Mask: $brainstem_mask

2. Hemisphere Masks (for asymmetry analysis):
   - Left hemisphere: ${output_prefix}_left_hemisphere.nii.gz
   - Right hemisphere: ${output_prefix}_right_hemisphere.nii.gz

3. Talairach Subdivisions:
   Directory: $(dirname "$output_prefix")/talairach_subdivisions/
   Regions: left_medulla, right_medulla, left_pons, right_pons, 
            left_midbrain, right_midbrain

$([ -n "$flair_file" ] && echo "4. FLAIR-Enhanced Outputs:
   - FLAIR intensity mask: ${output_prefix}_brainstem_flair_intensity.nii.gz
   - FLAIR subdivisions: $(dirname "$output_prefix")/talairach_subdivisions_flair/")

SEGMENTATION STATISTICS
-----------------------
EOF
    
    # Add volume statistics
    if [[ -f "$brainstem_mask" ]]; then
        local total_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
        local voxel_volume=$(fslval "$brainstem_mask" pixdim1)
        voxel_volume=$(echo "$voxel_volume * $(fslval "$brainstem_mask" pixdim2) * $(fslval "$brainstem_mask" pixdim3)" | bc -l)
        local total_volume_mm3=$(echo "$total_voxels * $voxel_volume" | bc -l)
        
        echo "Total brainstem voxels: $total_voxels" >> "$report_file"
        echo "Estimated volume (mm³): $(printf "%.1f" "$total_volume_mm3")" >> "$report_file"
        echo "" >> "$report_file"
    fi
    
    # Add subdivision statistics
    local subdivision_dir="$(dirname "$output_prefix")/talairach_subdivisions"
    if [[ -d "$subdivision_dir" ]]; then
        echo "TALAIRACH SUBDIVISION STATISTICS" >> "$report_file"
        echo "--------------------------------" >> "$report_file"
        
        for region_file in "$subdivision_dir"/*.nii.gz; do
            local region_name=$(basename "$region_file" .nii.gz)
            local region_voxels=$(fslstats "$region_file" -V | awk '{print $1}')
            echo "  ${region_name}: ${region_voxels} voxels" >> "$report_file"
        done
        echo "" >> "$report_file"
    fi
    
    cat >> "$report_file" <<EOF
VISUALIZATION COMMANDS
----------------------
To view the segmentation results:

# Primary brainstem on T1:
fsleyes $input_file $brainstem_mask -cm red -a 0.5

$([ -n "$flair_file" ] && echo "# Primary brainstem on FLAIR:
fsleyes $flair_file $brainstem_mask -cm red -a 0.5")

# Talairach subdivisions:
fsleyes $input_file $(dirname "$output_prefix")/talairach_subdivisions/*.nii.gz -cm random -a 0.6

================================================================================
EOF
    
    log_message "  ✓ Segmentation report: $report_file"
    return 0
}

# Legacy function wrappers for backward compatibility
extract_brainstem_harvard_oxford() {
    log_formatted "INFO" "Using hierarchical joint fusion (Harvard-Oxford component)"
    extract_brainstem "$@"
}

extract_brainstem_talairach() {
    log_formatted "INFO" "Using hierarchical joint fusion (includes Talairach subdivisions)"
    extract_brainstem "$@"
}

# Main segmentation entry point called by pipeline
segment_brainstem() {
    local input_file="$1"
    local input_basename="$2"
    local flair_file="${3:-}"
    
    log_formatted "INFO" "=== BRAINSTEM SEGMENTATION MODULE ==="
    
    # Execute comprehensive brainstem segmentation
    extract_brainstem "$input_file" "$input_basename" "$flair_file"
}
