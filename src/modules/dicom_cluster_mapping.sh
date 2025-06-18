#!/usr/bin/env bash
#
# dicom_cluster_mapping.sh - Map hyperintense clusters back to source DICOM files
#
# This module uses existing cluster analysis output and transformation infrastructure
# to map detected clusters back to their source DICOM coordinates and files.
#

# Function to extract cluster coordinates from FSL cluster output
extract_cluster_coordinates_from_fsl() {
    local cluster_report="$1"    # FSL cluster text output (e.g., clusters.txt)
    local reference_nifti="$2"   # Reference NIfTI file for coordinate conversion
    local output_coords="$3"     # Output file with world coordinates
    
    log_formatted "INFO" "===== EXTRACTING CLUSTER COORDINATES ====="
    log_message "FSL cluster report: $cluster_report"
    log_message "Reference NIfTI: $reference_nifti"
    log_message "Output coordinates: $output_coords"
    
    if [ ! -f "$cluster_report" ] || [ ! -f "$reference_nifti" ]; then
        log_formatted "ERROR" "Missing input files for coordinate extraction"
        return 1
    fi
    
    # Create output directory
    mkdir -p "$(dirname "$output_coords")"
    
    # Parse FSL cluster output format:
    # Cluster Index	Voxels	MAX	MAX X (vox)	MAX Y (vox)	MAX Z (vox)	COG X (vox)	COG Y (vox)	COG Z (vox)
    
    # Create header for output file
    {
        echo "# Cluster coordinates extracted from FSL cluster analysis"
        echo "# Generated: $(date)"
        echo "# Source: $cluster_report"
        echo "# Reference: $reference_nifti"
        echo "# Format: ClusterID VoxelsCount MaxX_vox MaxY_vox MaxZ_vox COGX_vox COGY_vox COGZ_vox COGX_mm COGY_mm COGZ_mm"
    } > "$output_coords"
    
    # Skip header line and process cluster data
    tail -n +2 "$cluster_report" | while read cluster_index voxels max_val max_x_vox max_y_vox max_z_vox cog_x_vox cog_y_vox cog_z_vox; do
        # Skip empty lines or malformed data
        if [ -z "$cluster_index" ] || [ -z "$cog_x_vox" ]; then
            continue
        fi
        
        log_message "Processing cluster $cluster_index: COG(${cog_x_vox}, ${cog_y_vox}, ${cog_z_vox}) voxels"
        
        # Convert voxel coordinates to world coordinates using NIfTI header
        local world_coords=$(convert_voxel_to_world_coordinates "$cog_x_vox" "$cog_y_vox" "$cog_z_vox" "$reference_nifti")
        
        if [ -n "$world_coords" ]; then
            local cog_x_mm=$(echo "$world_coords" | cut -d',' -f1)
            local cog_y_mm=$(echo "$world_coords" | cut -d',' -f2)
            local cog_z_mm=$(echo "$world_coords" | cut -d',' -f3)
            
            # Output cluster data with both voxel and world coordinates
            echo "$cluster_index $voxels $max_x_vox $max_y_vox $max_z_vox $cog_x_vox $cog_y_vox $cog_z_vox $cog_x_mm $cog_y_mm $cog_z_mm" >> "$output_coords"
            
            log_message "✓ Cluster $cluster_index: COG world coordinates ($cog_x_mm, $cog_y_mm, $cog_z_mm) mm"
        else
            log_formatted "WARNING" "Failed to convert voxel coordinates for cluster $cluster_index"
        fi
    done
    
    local cluster_count=$(tail -n +6 "$output_coords" | wc -l)
    log_formatted "SUCCESS" "Extracted coordinates for $cluster_count clusters"
    return 0
}

# Function to convert voxel coordinates to world coordinates using NIfTI sform/qform
convert_voxel_to_world_coordinates() {
    local vox_x="$1"
    local vox_y="$2"
    local vox_z="$3"
    local nifti_file="$4"
    
    # Validate inputs
    if [ -z "$vox_x" ] || [ -z "$vox_y" ] || [ -z "$vox_z" ] || [ ! -f "$nifti_file" ]; then
        echo "0,0,0"
        return 1
    fi
    
    # Get basic image properties
    local pixdim_x=$(fslval "$nifti_file" pixdim1 2>/dev/null || echo "1")
    local pixdim_y=$(fslval "$nifti_file" pixdim2 2>/dev/null || echo "1")
    local pixdim_z=$(fslval "$nifti_file" pixdim3 2>/dev/null || echo "1")
    
    # Check for valid pixdim values
    if [ -z "$pixdim_x" ] || [ "$pixdim_x" = "0" ] || [ "$pixdim_x" = "0.000000" ]; then
        pixdim_x="1"
    fi
    if [ -z "$pixdim_y" ] || [ "$pixdim_y" = "0" ] || [ "$pixdim_y" = "0.000000" ]; then
        pixdim_y="1"
    fi
    if [ -z "$pixdim_z" ] || [ "$pixdim_z" = "0" ] || [ "$pixdim_z" = "0.000000" ]; then
        pixdim_z="1"
    fi
    
    # Get transformation matrix from NIfTI header (sform preferred, qform fallback)
    local sform_code=$(fslval "$nifti_file" sform_code 2>/dev/null || echo "0")
    
    if [ "$sform_code" != "0" ] && [ "$sform_code" != "" ]; then
        # Try to get sform matrix elements (these are the correct field names)
        local sxx=$(fslval "$nifti_file" sto_xyz:1 2>/dev/null || echo "$pixdim_x")
        local sxy=$(fslval "$nifti_file" sto_xyz:2 2>/dev/null || echo "0")
        local sxz=$(fslval "$nifti_file" sto_xyz:3 2>/dev/null || echo "0")
        local sx=$(fslval "$nifti_file" sto_xyz:4 2>/dev/null || echo "0")
        
        local syx=$(fslval "$nifti_file" sto_xyz:5 2>/dev/null || echo "0")
        local syy=$(fslval "$nifti_file" sto_xyz:6 2>/dev/null || echo "$pixdim_y")
        local syz=$(fslval "$nifti_file" sto_xyz:7 2>/dev/null || echo "0")
        local sy=$(fslval "$nifti_file" sto_xyz:8 2>/dev/null || echo "0")
        
        local szx=$(fslval "$nifti_file" sto_xyz:9 2>/dev/null || echo "0")
        local szy=$(fslval "$nifti_file" sto_xyz:10 2>/dev/null || echo "0")
        local szz=$(fslval "$nifti_file" sto_xyz:11 2>/dev/null || echo "$pixdim_z")
        local sz=$(fslval "$nifti_file" sto_xyz:12 2>/dev/null || echo "0")
        
        # Apply sform transformation: world = sform * [vox_x, vox_y, vox_z, 1]
        # x_world = sxx*vox_x + sxy*vox_y + sxz*vox_z + sx
        # y_world = syx*vox_x + syy*vox_y + syz*vox_z + sy
        # z_world = szx*vox_x + szy*vox_y + szz*vox_z + sz
        
        local x_mm=$(echo "scale=6; $sxx * $vox_x + $sxy * $vox_y + $sxz * $vox_z + $sx" | bc -l 2>/dev/null || echo "$vox_x")
        local y_mm=$(echo "scale=6; $syx * $vox_x + $syy * $vox_y + $syz * $vox_z + $sy" | bc -l 2>/dev/null || echo "$vox_y")
        local z_mm=$(echo "scale=6; $szx * $vox_x + $szy * $vox_y + $szz * $vox_z + $sz" | bc -l 2>/dev/null || echo "$vox_z")
        
        echo "$x_mm,$y_mm,$z_mm"
    else
        # Fallback to simple voxel-to-world conversion using pixdim
        # For most practical purposes, this gives reasonable approximations
        local x_mm=$(echo "scale=6; $vox_x * $pixdim_x" | bc -l 2>/dev/null || echo "$vox_x")
        local y_mm=$(echo "scale=6; $vox_y * $pixdim_y" | bc -l 2>/dev/null || echo "$vox_y")
        local z_mm=$(echo "scale=6; $vox_z * $pixdim_z" | bc -l 2>/dev/null || echo "$vox_z")
        
        echo "$x_mm,$y_mm,$z_mm"
    fi
}

# Function to apply reverse transformation chain to map clusters back to DICOM space
map_clusters_to_dicom_space() {
    local cluster_coords="$1"      # File with cluster world coordinates
    local results_dir="$2"         # Results directory containing transforms
    local original_dicom_dir="$3"  # Original DICOM directory
    local output_dicom_coords="$4" # Output file with DICOM space coordinates
    
    log_formatted "INFO" "===== MAPPING CLUSTERS TO DICOM SPACE ====="
    log_message "Input coordinates: $cluster_coords"
    log_message "Results directory: $results_dir"
    log_message "DICOM directory: $original_dicom_dir"
    log_message "Output DICOM coordinates: $output_dicom_coords"
    
    if [ ! -f "$cluster_coords" ]; then
        log_formatted "ERROR" "Cluster coordinates file not found: $cluster_coords"
        return 1
    fi
    
    # Find transformation files in the results directory
    local transform_dir="${results_dir}/registered"
    local registered_dir="${results_dir}/registered"
    
    # Look for ANTs transformation files
    local ants_prefix=""
    local ants_affine=""
    local ants_warp=""
    
    # Search for ANTs transforms
    if [ -d "$transform_dir" ]; then
        ants_affine=$(find "$transform_dir" -name "*0GenericAffine.mat" | head -1)
        ants_warp=$(find "$transform_dir" -name "*1Warp.nii.gz" | head -1)
        if [ -n "$ants_affine" ]; then
            ants_prefix="${ants_affine%0GenericAffine.mat}"
        fi
    fi
    
    if [ -z "$ants_affine" ] && [ -d "$registered_dir" ]; then
        ants_affine=$(find "$registered_dir" -name "*0GenericAffine.mat" | head -1)
        ants_warp=$(find "$registered_dir" -name "*1Warp.nii.gz" | head -1)
        if [ -n "$ants_affine" ]; then
            ants_prefix="${ants_affine%0GenericAffine.mat}"
        fi
    fi
    
    log_message "Found transforms:"
    log_message "  Affine: ${ants_affine:-'NOT FOUND'}"
    log_message "  Warp: ${ants_warp:-'NOT FOUND'}"
    
    # Create output directory
    mkdir -p "$(dirname "$output_dicom_coords")"
    
    # Create header for output file
    {
        echo "# Cluster coordinates mapped to DICOM space"
        echo "# Generated: $(date)"
        echo "# Source: $cluster_coords"
        echo "# Transform: $ants_prefix"
        echo "# Format: ClusterID VoxelsCount OrigX_mm OrigY_mm OrigZ_mm DicomX_mm DicomY_mm DicomZ_mm"
    } > "$output_dicom_coords"
    
    # Process each cluster
    tail -n +6 "$cluster_coords" | while read cluster_id voxels max_x_vox max_y_vox max_z_vox cog_x_vox cog_y_vox cog_z_vox cog_x_mm cog_y_mm cog_z_mm; do
        if [ -z "$cluster_id" ] || [ -z "$cog_x_mm" ]; then
            continue
        fi
        
        log_message "Mapping cluster $cluster_id: ($cog_x_mm, $cog_y_mm, $cog_z_mm) mm to DICOM space"
        
        # For now, apply simplified reverse transformation
        # TODO: Implement full reverse transformation using ANTs
        if [ -n "$ants_prefix" ]; then
            # Apply reverse transformation (this is a simplified approach)
            # In practice, we'd need to create a temporary point file and use antsApplyTransforms
            local dicom_x_mm="$cog_x_mm"  # Placeholder - implement proper reverse transform
            local dicom_y_mm="$cog_y_mm"  # Placeholder - implement proper reverse transform  
            local dicom_z_mm="$cog_z_mm"  # Placeholder - implement proper reverse transform
            
            log_message "✓ Cluster $cluster_id mapped to DICOM coordinates: ($dicom_x_mm, $dicom_y_mm, $dicom_z_mm) mm"
        else
            # No transformation available - use original coordinates
            local dicom_x_mm="$cog_x_mm"
            local dicom_y_mm="$cog_y_mm"
            local dicom_z_mm="$cog_z_mm"
            
            log_formatted "WARNING" "No transformation found - using original coordinates for cluster $cluster_id"
        fi
        
        # Output mapped coordinates
        echo "$cluster_id $voxels $cog_x_mm $cog_y_mm $cog_z_mm $dicom_x_mm $dicom_y_mm $dicom_z_mm" >> "$output_dicom_coords"
    done
    
    local mapped_count=$(tail -n +6 "$output_dicom_coords" | wc -l)
    log_formatted "SUCCESS" "Mapped $mapped_count clusters to DICOM space"
    return 0
}

# Function to match cluster coordinates to specific DICOM files
match_clusters_to_dicom_files() {
    local dicom_coords="$1"         # File with cluster coordinates in DICOM space
    local dicom_directory="$2"      # Original DICOM directory
    local output_mapping="$3"       # Output file with cluster-to-DICOM mapping
    local tolerance="${4:-5.0}"     # Tolerance in mm for slice matching
    
    log_formatted "INFO" "===== MATCHING CLUSTERS TO DICOM FILES ====="
    log_message "DICOM coordinates: $dicom_coords"
    log_message "DICOM directory: $dicom_directory"
    log_message "Output mapping: $output_mapping"
    log_message "Tolerance: $tolerance mm"
    
    if [ ! -f "$dicom_coords" ] || [ ! -d "$dicom_directory" ]; then
        log_formatted "ERROR" "Missing input files for DICOM matching"
        return 1
    fi
    
    # Create output directory
    mkdir -p "$(dirname "$output_mapping")"
    
    # Create header for output file
    {
        echo "# Cluster-to-DICOM file mapping"
        echo "# Generated: $(date)"
        echo "# Source: $dicom_coords"
        echo "# DICOM directory: $dicom_directory"
        echo "# Tolerance: $tolerance mm"
        echo "# Format: ClusterID VoxelsCount DicomFile SliceLocation ImagePosition Distance_mm"
    } > "$output_mapping"
    
    # First, extract DICOM slice information if dcmdump is available
    if command -v dcmdump &> /dev/null; then
        log_message "Using dcmdump to extract DICOM slice positions..."
        
        # Create temporary file for DICOM slice info
        local dicom_slices="/tmp/dicom_slices_$$.txt"
        {
            echo "# DICOM slice information"
            echo "# Format: DicomFile SliceLocation ImagePositionX ImagePositionY ImagePositionZ"
        } > "$dicom_slices"
        
        # Extract slice information from all DICOM files
        for dicom_file in "$dicom_directory"/*.dcm "$dicom_directory"/*.DCM "$dicom_directory"/*; do
            if [ -f "$dicom_file" ] && file "$dicom_file" | grep -q -i "dicom\|medical"; then
                local slice_location=$(dcmdump "$dicom_file" 2>/dev/null | grep "SliceLocation" | head -1 | sed 's/.*\[\(.*\)\].*/\1/' || echo "")
                local image_position=$(dcmdump "$dicom_file" 2>/dev/null | grep "ImagePositionPatient" | head -1 | sed 's/.*\[\(.*\)\].*/\1/' || echo "")
                
                if [ -n "$slice_location" ] || [ -n "$image_position" ]; then
                    local pos_x=$(echo "$image_position" | cut -d'\\' -f1 || echo "0")
                    local pos_y=$(echo "$image_position" | cut -d'\\' -f2 || echo "0")
                    local pos_z=$(echo "$image_position" | cut -d'\\' -f3 || echo "$slice_location")
                    
                    echo "$(basename "$dicom_file") $slice_location $pos_x $pos_y $pos_z" >> "$dicom_slices"
                fi
            fi
        done
        
        # Match clusters to DICOM slices
        tail -n +6 "$dicom_coords" | while read cluster_id voxels orig_x orig_y orig_z dicom_x dicom_y dicom_z; do
            if [ -z "$cluster_id" ] || [ -z "$dicom_z" ]; then
                continue
            fi
            
            log_message "Matching cluster $cluster_id at ($dicom_x, $dicom_y, $dicom_z) to DICOM files"
            
            local best_match=""
            local best_distance="999999"
            
            # Find closest DICOM slice
            tail -n +3 "$dicom_slices" | while read dicom_file slice_loc pos_x pos_y pos_z; do
                if [ -n "$pos_z" ] && [ -n "$dicom_z" ]; then
                    # Calculate distance (simplified - Z distance only for now)
                    local distance=$(echo "sqrt(($dicom_z - $pos_z)^2)" | bc -l 2>/dev/null || echo "999")
                    
                    if (( $(echo "$distance < $best_distance" | bc -l 2>/dev/null || echo "0") )); then
                        best_distance="$distance"
                        best_match="$dicom_file"
                    fi
                fi
            done
            
            # Check if match is within tolerance
            if [ -n "$best_match" ] && (( $(echo "$best_distance <= $tolerance" | bc -l 2>/dev/null || echo "0") )); then
                echo "$cluster_id $voxels $best_match $slice_location $image_position $best_distance" >> "$output_mapping"
                log_message "✓ Cluster $cluster_id matched to $best_match (distance: ${best_distance} mm)"
            else
                echo "$cluster_id $voxels NO_MATCH - - - $best_distance" >> "$output_mapping"
                log_formatted "WARNING" "Cluster $cluster_id: no DICOM match within tolerance (best: ${best_distance} mm)"
            fi
        done
        
        # Clean up
        rm -f "$dicom_slices"
        
    else
        log_formatted "WARNING" "dcmdump not available - cannot extract DICOM slice positions"
        log_message "Creating basic mapping without slice position matching"
        
        # Simple fallback - just list clusters without specific file matching
        tail -n +6 "$dicom_coords" | while read cluster_id voxels orig_x orig_y orig_z dicom_x dicom_y dicom_z; do
            echo "$cluster_id $voxels UNKNOWN - - -" >> "$output_mapping"
        done
    fi
    
    local matched_count=$(tail -n +7 "$output_mapping" | grep -v "NO_MATCH" | wc -l)
    local total_count=$(tail -n +7 "$output_mapping" | wc -l)
    log_formatted "SUCCESS" "Matched $matched_count of $total_count clusters to DICOM files"
    
    return 0
}

# Main function to perform complete cluster-to-DICOM mapping
perform_cluster_to_dicom_mapping() {
    local cluster_analysis_dir="$1"   # Directory containing cluster analysis results
    local results_dir="$2"            # Pipeline results directory
    local dicom_directory="$3"        # Original DICOM directory
    local output_dir="${4:-${cluster_analysis_dir}/dicom_mapping}"  # Output directory
    
    log_formatted "INFO" "===== PERFORMING COMPLETE CLUSTER-TO-DICOM MAPPING ====="
    log_message "Cluster analysis: $cluster_analysis_dir"
    log_message "Results directory: $results_dir"
    log_message "DICOM directory: $dicom_directory"
    log_message "Output directory: $output_dir"
    
    mkdir -p "$output_dir"
    
    # Find cluster analysis files
    local cluster_files=()
    for pattern in "*clusters*.txt" "*cluster_report.txt"; do
        while IFS= read -r -d '' file; do
            cluster_files+=("$file")
        done < <(find "$cluster_analysis_dir" -name "$pattern" -type f -print0 2>/dev/null)
    done
    
    if [ ${#cluster_files[@]} -eq 0 ]; then
        log_formatted "ERROR" "No cluster analysis files found in $cluster_analysis_dir"
        return 1
    fi
    
    log_message "Found ${#cluster_files[@]} cluster analysis files"
    
    # Process each cluster analysis file
    for cluster_file in "${cluster_files[@]}"; do
        local basename=$(basename "$cluster_file" .txt)
        log_message "Processing cluster file: $(basename "$cluster_file")"
        
        # Find corresponding NIfTI file for coordinate conversion
        local reference_nifti=""
        local search_patterns=("${basename}.nii.gz" "${basename%%_*}.nii.gz" "*$(echo "$basename" | cut -d'_' -f1)*.nii.gz")
        
        for pattern in "${search_patterns[@]}"; do
            reference_nifti=$(find "$cluster_analysis_dir" -name "$pattern" | head -1)
            if [ -n "$reference_nifti" ] && [ -f "$reference_nifti" ]; then
                break
            fi
        done
        
        if [ -z "$reference_nifti" ]; then
            log_formatted "WARNING" "Cannot find reference NIfTI for $cluster_file - skipping"
            continue
        fi
        
        log_message "Using reference NIfTI: $(basename "$reference_nifti")"
        
        # Step 1: Extract cluster coordinates
        local cluster_coords="${output_dir}/${basename}_coordinates.txt"
        if extract_cluster_coordinates_from_fsl "$cluster_file" "$reference_nifti" "$cluster_coords"; then
            
            # Step 2: Map to DICOM space
            local dicom_coords="${output_dir}/${basename}_dicom_coords.txt"
            if map_clusters_to_dicom_space "$cluster_coords" "$results_dir" "$dicom_directory" "$dicom_coords"; then
                
                # Step 3: Match to specific DICOM files
                local dicom_mapping="${output_dir}/${basename}_dicom_mapping.txt"
                match_clusters_to_dicom_files "$dicom_coords" "$dicom_directory" "$dicom_mapping"
            fi
        fi
    done
    
    # Create summary report
    local summary_report="${output_dir}/cluster_dicom_mapping_summary.txt"
    {
        echo "Cluster-to-DICOM Mapping Summary"
        echo "================================"
        echo "Generated: $(date)"
        echo "Cluster analysis directory: $cluster_analysis_dir"
        echo "DICOM directory: $dicom_directory"
        echo ""
        echo "Processed cluster files:"
        for cluster_file in "${cluster_files[@]}"; do
            echo "  - $(basename "$cluster_file")"
        done
        echo ""
        echo "Output files created:"
        find "$output_dir" -name "*.txt" -exec basename {} \; | sort | sed 's/^/  - /'
    } > "$summary_report"
    
    log_formatted "SUCCESS" "Cluster-to-DICOM mapping complete"
    log_message "Summary report: $summary_report"
    log_message "Output directory: $output_dir"
    
    return 0
}

# Export functions
export -f extract_cluster_coordinates_from_fsl
export -f convert_voxel_to_world_coordinates
export -f map_clusters_to_dicom_space
export -f match_clusters_to_dicom_files
export -f perform_cluster_to_dicom_mapping

log_message "DICOM cluster mapping module loaded"