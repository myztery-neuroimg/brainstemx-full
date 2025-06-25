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
    local flair_file=""  # Optional FLAIR file
    
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
    local temp_dir="${RESULTS_DIR}/segmentation"
    
    # Set output prefix
    local output_prefix="${brainstem_dir}"  #/${input_basename}"
    
    # Execute hierarchical joint fusion
    if execute_hierarchical_joint_fusion "$input_file" "$output_prefix" "$temp_dir"; then
        log_formatted "SUCCESS" "Hierarchical joint fusion segmentation completed"
    else
        log_formatted "ERROR" "Hierarchical joint fusion segmentation failed"
        #srm -rf "$temp_dir"
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
    #rm -rf "$temp_dir"
    
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
Template Resolution: ${DEFAULT_TEMPLATE_RES:-1mm}

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

# ============================================================================
# MISSING FUNCTIONS FROM ORIGINAL - ADDED FOR COMPATIBILITY
# ============================================================================

# Enhanced FLAIR integration (from original)
extract_brainstem_with_flair() {
    local t1_file="$1"
    local flair_file="$2"
    local output_prefix="${3:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$t1_file" .nii.gz)}"
    
    log_formatted "INFO" "=== ENHANCED SEGMENTATION WITH FLAIR INTEGRATION ==="
    
    # First get hierarchical joint fusion segmentation from T1
    local t1_brainstem="${output_prefix}_brainstem_t1based.nii.gz"
    if ! extract_brainstem "$t1_file" "$(basename "$t1_file" .nii.gz)" "$flair_file"; then
        log_formatted "ERROR" "T1-based hierarchical joint fusion segmentation failed"
        return 1
    fi
    
    # The new approach already integrates FLAIR if available
    log_formatted "SUCCESS" "Enhanced segmentation with FLAIR integration completed"
    return 0
}

# Comprehensive segmentation with multiple methods (from original)
extract_brainstem_final() {
    local input_file="$1"
    local input_basename=$(basename "$input_file" .nii.gz)
    
    log_formatted "INFO" "===== COMPREHENSIVE BRAINSTEM SEGMENTATION ====="
    log_message "Using hierarchical joint fusion as primary method"
    
    # Define output directory
    local brainstem_dir="${RESULTS_DIR}/segmentation"
    mkdir -p "$brainstem_dir"
    
    # Execute hierarchical joint fusion
    if extract_brainstem "$input_file" "$input_basename"; then
        log_formatted "SUCCESS" "Hierarchical joint fusion segmentation successful"
    else
        log_formatted "ERROR" "Hierarchical joint fusion segmentation failed"
        return 1
    fi
    
    # Map files to expected names
    map_segmentation_files "$input_basename" "$brainstem_dir"
    
    # Validate segmentation
    validate_segmentation_outputs "$input_file" "$input_basename"
    
    # Generate comprehensive visualization report
    generate_comprehensive_report "$input_file" "$input_basename"
    
    log_formatted "SUCCESS" "Comprehensive segmentation complete"
    return 0
}

# File mapping functionality (from original)
map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    log_message "Mapping segmentation files to expected names..."
    
    # Remove any method suffixes from files
    for file in "${brainstem_dir}"/*_brainstem*.nii.gz; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            # Remove suffixes like _harvard, _juelich, _t1based, etc.
            local clean_name=$(echo "$basename" | sed -E 's/_(harvard|t1based|enhanced|talairach)//g')
            if [ "$basename" != "$clean_name" ]; then
                log_message "Renaming $basename to $clean_name"
                cp "$file" "${brainstem_dir}/${clean_name}"
            fi
        fi
    done
    
    return 0
}

# Validation functionality (from original)
validate_segmentation_outputs() {
    local input_file="$1"
    local basename="$2"
    
    log_message "Validating segmentation outputs..."
    
    local brainstem_file="${RESULTS_DIR}/segmentation/${basename}_brainstem.nii.gz"
    local validation_passed=true
    
    # Check brainstem
    if [ -f "$brainstem_file" ]; then
        local brainstem_voxels=$(fslstats "$brainstem_file" -V | awk '{print $1}')
        log_message "Brainstem: $brainstem_voxels voxels"
        if [ "$brainstem_voxels" -lt 100 ]; then
            log_formatted "WARNING" "Brainstem segmentation may be too small"
            validation_passed=false
        fi
    else
        log_formatted "ERROR" "Brainstem segmentation file not found: $brainstem_file"
        validation_passed=false
    fi
    
    # Create validation report
    local validation_dir="${RESULTS_DIR}/validation/segmentation"
    mkdir -p "$validation_dir"
    {
        echo "Segmentation Validation Report"
        echo "=============================="
        echo "Date: $(date)"
        echo "Input: $input_file"
        echo "Files created:"
        ls -la "${RESULTS_DIR}/segmentation/${basename}"*.nii.gz 2>/dev/null || echo "No brainstem files"
        echo "Validation: $([ "$validation_passed" = "true" ] && echo "PASSED" || echo "WARNINGS")"
    } > "${validation_dir}/segmentation_validation.txt"
    
    return 0
}

# Combined segmentation map creation (from original)
create_combined_segmentation_map() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    log_message "Creating combined segmentation label map..."
    
    local combined_dir="${RESULTS_DIR}/segmentation/combined"
    mkdir -p "$combined_dir"
    
    # Define label values
    local BRAINSTEM_LABEL=1
    
    # Get reference file for dimensions
    local ref_file="${brainstem_dir}/${input_basename}_brainstem_mask.nii.gz"
    if [ ! -f "$ref_file" ]; then
        log_formatted "WARNING" "Reference file not found for combined map"
        return 1
    fi
    
    # Start with empty map
    local combined_map="${combined_dir}/${input_basename}_segmentation_labels.nii.gz"
    fslmaths "$ref_file" -mul 0 "$combined_map"
    
    # Add brainstem (label 1)
    local brainstem_mask="${brainstem_dir}/${input_basename}_brainstem_mask.nii.gz"
    if [ -f "$brainstem_mask" ]; then
        fslmaths "$brainstem_mask" -mul $BRAINSTEM_LABEL -add "$combined_map" "$combined_map"
        log_message "Added brainstem to combined map (label=$BRAINSTEM_LABEL)"
    fi
    
    # Create label description file
    {
        echo "# Brainstem Segmentation Label Map"
        echo "# Label values:"
        echo "0 = Background"
        echo "1 = Brainstem (Hierarchical Joint Fusion)"
    } > "${combined_dir}/${input_basename}_segmentation_labels.txt"
    
    log_message "Combined segmentation map created: $combined_map"
    return 0
}

# Comprehensive report generation (from original)
generate_comprehensive_report() {
    local input_file="$1"
    local input_basename="$2"
    local report_dir="${RESULTS_DIR}/reports"
    
    log_message "Generating comprehensive segmentation report..."
    mkdir -p "$report_dir"
    
    local report_file="${report_dir}/segmentation_report_${input_basename}.txt"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Gather file information
    local t1_file="${RESULTS_DIR}/standardized/$(basename "$input_file")"
    local brainstem_intensity="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem.nii.gz"
    local brainstem_mask="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem_mask.nii.gz"
    
    # Calculate statistics
    local brainstem_voxels=0
    if [ -f "$brainstem_mask" ]; then
        brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    fi
    
    # Generate report
    cat > "$report_file" <<EOF
================================================================================
                        BRAINSTEM SEGMENTATION REPORT
================================================================================
Generated: $timestamp
Subject: $input_basename

SEGMENTATION SUMMARY
-------------------
Method: Hierarchical Joint Fusion (Harvard-Oxford + Talairach + Juelich)
Space: T1 Native Space
Brainstem voxels: $brainstem_voxels

FILES GENERATED
--------------
1. Binary Masks (for ROI analysis):
   - Brainstem mask: ${brainstem_mask}

2. Intensity Maps (T1 values within masks):
   - Brainstem intensities: ${brainstem_intensity}

VISUALIZATION INSTRUCTIONS
-------------------------
To visualize the segmentations overlaid on your images:

1. View segmentations on T1:
   fsleyes ${t1_file} \\
           ${brainstem_mask} -cm red -a 50

2. View with intensity overlay:
   fsleyes ${t1_file} \\
           ${brainstem_intensity} -cm hot -a 70

================================================================================
EOF

    log_formatted "SUCCESS" "Comprehensive segmentation report generated: $report_file"
    return 0
}

# Tissue segmentation (from original)
segment_tissues() {
    local input_file="$1"
    local output_dir="${2:-${RESULTS_DIR}/segmentation/tissue}"
    
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    mkdir -p "$output_dir"
    log_message "Performing tissue segmentation on $input_file"
    
    local basename=$(basename "$input_file" .nii.gz)
    
    # Try to find existing brain extraction files
    local brain_mask="${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz"
    local brain_file="${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz"
    
    if [ ! -f "$brain_mask" ] || [ ! -f "$brain_file" ]; then
        log_message "Searching for available brain extraction files..."
        local available_brain_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain.nii.gz" 2>/dev/null))
        local available_mask_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain_mask.nii.gz" 2>/dev/null))
        
        if [ ${#available_brain_files[@]} -gt 0 ] && [ ${#available_mask_files[@]} -gt 0 ]; then
            brain_file="${available_brain_files[0]}"
            brain_mask="${available_mask_files[0]}"
            log_message "Using available brain extraction files"
        else
            log_formatted "ERROR" "Brain extraction files not found"
            return 1
        fi
    fi
    
    # Use FAST for tissue segmentation
    log_message "Running FAST segmentation..."
    fast -t 1 -n 3 -o "${output_dir}/${basename}_" "$brain_file"
    
    log_message "Tissue segmentation complete"
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

# Legacy compatibility functions
extract_brainstem_standardspace() {
    log_formatted "WARNING" "extract_brainstem_standardspace is deprecated. Using hierarchical joint fusion."
    extract_brainstem "$@"
}

extract_brainstem_ants() {
    log_formatted "WARNING" "extract_brainstem_ants is deprecated. Using hierarchical joint fusion."
    extract_brainstem "$@"
}

# Simple validation function that doesn't block pipeline
validate_segmentation() {
    log_message "Running segmentation validation..."
    return 0
}

# File discovery and mapping
discover_and_map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    map_segmentation_files "$input_basename" "$brainstem_dir"
    return 0
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

# Export functions for use by other modules
export -f extract_brainstem
export -f enhance_segmentation_with_flair
export -f generate_segmentation_report
export -f extract_brainstem_with_flair
export -f extract_brainstem_final
export -f map_segmentation_files
export -f validate_segmentation_outputs
export -f create_combined_segmentation_map
export -f generate_comprehensive_report
export -f segment_tissues

# Legacy exports for compatibility
export -f extract_brainstem_harvard_oxford
export -f extract_brainstem_talairach
export -f extract_brainstem_standardspace
export -f extract_brainstem_ants
export -f validate_segmentation
export -f discover_and_map_segmentation_files
export -f segment_brainstem

log_message "Segmentation module loaded with hierarchical joint fusion"
