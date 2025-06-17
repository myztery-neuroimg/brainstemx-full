#!/usr/bin/env bash
#
# segment_talairach.sh - Talairach atlas-based brainstem subdivision
#
# This module provides detailed brainstem anatomical subdivision using the Talairach atlas
# while respecting Harvard-Oxford brainstem boundaries as the gold standard.
#
# Key features:
# - Extracts pons, medulla, midbrain from Talairach atlas
# - Transforms from Talairach space → MNI space → subject space
# - Validates all subdivisions against Harvard-Oxford brainstem boundaries
# - Provides left/right subdivision capabilities
# - Maintains orientation consistency with main pipeline
#

# Talairach brainstem region indices (from atlasq summary talairach)
TALAIRACH_LEFT_MEDULLA=5      # Left Brainstem.Medulla
TALAIRACH_RIGHT_MEDULLA=6     # Right Brainstem.Medulla  
TALAIRACH_LEFT_PONS=71        # Left Brainstem.Pons
TALAIRACH_RIGHT_PONS=72       # Right Brainstem.Pons
TALAIRACH_LEFT_MIDBRAIN=215   # Left Brainstem.Midbrain
TALAIRACH_RIGHT_MIDBRAIN=216  # Right Brainstem.Midbrain

# Function to extract brainstem subdivisions using Talairach atlas with existing transform
extract_brainstem_talairach_with_transform() {
    local input_file="$1"
    local output_basename="$2"
    local harvard_brainstem_mask="$3"  # Harvard-Oxford boundary constraint
    local orientation_corrected_input="$4"  # Pre-corrected input file
    local ants_transform_matrix="$5"  # Existing ANTs transform matrix
    local orientation_corrected="$6"  # Whether orientation was corrected (true/false)
    
    log_formatted "INFO" "===== TALAIRACH ATLAS BRAINSTEM SUBDIVISION (REUSING TRANSFORM) ====="
    log_message "Input: $input_file"
    log_message "Output basename: $output_basename"
    log_message "Harvard-Oxford constraint: $harvard_brainstem_mask"
    log_message "Orientation-corrected input: $orientation_corrected_input"
    log_message "Reusing transform: $ants_transform_matrix"
    log_message "Orientation corrected: $orientation_corrected"
    
    # Validate inputs
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file not found: $input_file"
        return 1
    fi
    
    if [ ! -f "$orientation_corrected_input" ]; then
        log_formatted "ERROR" "Orientation-corrected input not found: $orientation_corrected_input"
        return 1
    fi
    
    if [ ! -f "$ants_transform_matrix" ]; then
        log_formatted "ERROR" "ANTs transform matrix not found: $ants_transform_matrix"
        return 1
    fi
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Set up output directories
    local pons_dir="${RESULTS_DIR}/segmentation/pons"
    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
    mkdir -p "$pons_dir" "$detailed_dir"
    
    # Determine template resolution
    local template_res="${DEFAULT_TEMPLATE_RES:-1mm}"
    if [ "${AUTO_DETECT_RESOLUTION:-true}" = "true" ]; then
        local voxel_size=$(fslinfo "$input_file" | grep "^pixdim1" | awk '{print $2}')
        if (( $(echo "$voxel_size > 1.5" | bc -l) )); then
            template_res="2mm"
        else
            template_res="1mm"
        fi
    fi
    
    # Find Talairach atlas
    local talairach_atlas=""
    local atlas_search_paths=(
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-${template_res}.nii.gz"
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-1mm.nii.gz"
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    )
    
    for atlas_file in "${atlas_search_paths[@]}"; do
        if [ -f "$atlas_file" ]; then
            talairach_atlas="$atlas_file"
            log_message "Found Talairach atlas: $atlas_file"
            break
        fi
    done
    
    if [ -z "$talairach_atlas" ]; then
        log_formatted "ERROR" "Talairach atlas not found in any expected location"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate Talairach atlas using atlasq
    log_message "Validating Talairach atlas structure..."
    if command -v atlasq &> /dev/null; then
        local atlas_summary=$(atlasq summary talairach 2>/dev/null | grep -i "brainstem\|pons" | head -5)
        if [ -n "$atlas_summary" ]; then
            log_formatted "SUCCESS" "✓ Talairach atlas contains brainstem structures:"
            echo "$atlas_summary" | while read line; do
                log_message "  $line"
            done
        else
            log_formatted "WARNING" "Could not validate Talairach brainstem structures with atlasq"
        fi
    fi
    
    # Skip registration - use provided transform instead
    log_message "Skipping duplicate registration - reusing Harvard-Oxford transform"
    
    # Transform entire Talairach atlas to subject space using existing composite transform
    log_message "Transforming Talairach atlas to subject native space using existing composite transform..."
    
    local atlas_in_subject="${temp_dir}/talairach_atlas_in_subject.nii.gz"
    
    # CRITICAL FIX: Use composite transforms - both warp and affine components
    # Composite transforms: replace -t "$transform" with -t "${out}_1Warp.nii.gz" -t "${out}_0GenericAffine.mat"
    local ants_prefix=$(dirname "$ants_transform_matrix")/$(basename "$ants_transform_matrix" 0GenericAffine.mat)
    local warp_component="${ants_prefix}1Warp.nii.gz"
    
    # Validate both transform components exist
    if [ ! -f "$ants_transform_matrix" ]; then
        log_formatted "ERROR" "Affine transform component not found: $ants_transform_matrix"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ ! -f "$warp_component" ]; then
        log_formatted "ERROR" "Warp transform component not found: $warp_component"
        log_formatted "ERROR" "Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "Using composite transforms: $ants_transform_matrix + $warp_component"
    
    antsApplyTransforms -d 3 \
        -i "$talairach_atlas" \
        -r "$orientation_corrected_input" \
        -o "$atlas_in_subject" \
        -t "[$ants_transform_matrix,1]" \
        -t "$warp_component" \
        -n GenericLabel
    
    # Check if atlas transformation was successful
    if [ ! -f "$atlas_in_subject" ]; then
        log_formatted "ERROR" "Failed to transform Talairach atlas to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "✓ Talairach atlas successfully transformed to subject native space (reused transform)"
    
    # Extract brainstem regions directly from atlas in subject space
    log_message "Extracting brainstem subdivisions from atlas in subject space..."
    
    # Extract individual regions from atlas in subject space
    extract_talairach_region() {
        local region_index="$1"
        local region_name="$2"
        local output_file="$3"
        
        log_message "Extracting $region_name (index $region_index) from subject-space atlas..."
        fslmaths "$atlas_in_subject" -thr $region_index -uthr $region_index -bin "$output_file"
        
        local voxel_count=$(fslstats "$output_file" -V | awk '{print $1}')
        if [ "$voxel_count" -gt 10 ]; then
            log_message "✓ $region_name: $voxel_count voxels in subject space"
            return 0
        else
            log_formatted "WARNING" "$region_name has insufficient voxels ($voxel_count) in subject space"
            return 1
        fi
    }
    
    # Extract all brainstem regions
    extract_talairach_region $TALAIRACH_LEFT_MEDULLA "left_medulla" "${detailed_dir}/${output_basename}_left_medulla.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_MEDULLA "right_medulla" "${detailed_dir}/${output_basename}_right_medulla.nii.gz"
    extract_talairach_region $TALAIRACH_LEFT_PONS "left_pons" "${detailed_dir}/${output_basename}_left_pons.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_PONS "right_pons" "${detailed_dir}/${output_basename}_right_pons.nii.gz"
    extract_talairach_region $TALAIRACH_LEFT_MIDBRAIN "left_midbrain" "${detailed_dir}/${output_basename}_left_midbrain.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_MIDBRAIN "right_midbrain" "${detailed_dir}/${output_basename}_right_midbrain.nii.gz"
    
    # Create combined pons mask (left + right)
    local combined_pons="${pons_dir}/${output_basename}_pons.nii.gz"
    log_message "Creating combined pons mask..."
    
    local left_pons="${detailed_dir}/${output_basename}_left_pons.nii.gz"
    local right_pons="${detailed_dir}/${output_basename}_right_pons.nii.gz"
    
    if [ -f "$left_pons" ] && [ -f "$right_pons" ]; then
        fslmaths "$left_pons" -add "$right_pons" -bin "$combined_pons"
    elif [ -f "$left_pons" ]; then
        cp "$left_pons" "$combined_pons"
    elif [ -f "$right_pons" ]; then
        cp "$right_pons" "$combined_pons"
    else
        log_formatted "WARNING" "No pons regions successfully extracted from Talairach"
        # Create empty pons for pipeline compatibility
        if [ -f "$input_file" ]; then
            fslmaths "$input_file" -mul 0 "$combined_pons"
        fi
    fi
    
    # Apply orientation correction to output masks if it was applied to input
    if [ "$orientation_corrected" = "true" ]; then
        log_message "Applying reverse orientation correction to Talairach output masks..."
        
        # Determine reverse correction needed
        local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
        local corrected_orient=$(fslorient -getorient "$orientation_corrected_input" 2>/dev/null || echo "UNKNOWN")
        
        apply_reverse_orientation() {
            local mask_file="$1"
            if [ -f "$mask_file" ]; then
                local temp_corrected="${temp_dir}/$(basename "$mask_file" .nii.gz)_corrected.nii.gz"
                
                if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$corrected_orient" = "RADIOLOGICAL" ]; then
                    # Convert back from RADIOLOGICAL to NEUROLOGICAL
                    fslswapdim "$mask_file" -x y z "$temp_corrected"
                    fslorient -forceneurological "$temp_corrected"
                elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$corrected_orient" = "NEUROLOGICAL" ]; then
                    # Convert back from NEUROLOGICAL to RADIOLOGICAL
                    fslswapdim "$mask_file" -x y z "$temp_corrected"
                    fslorient -forceradiological "$temp_corrected"
                else
                    # No correction needed
                    cp "$mask_file" "$temp_corrected"
                fi
                
                # Replace original with corrected version
                mv "$temp_corrected" "$mask_file"
            fi
        }
        
        # Apply reverse correction to all output files - only process original binary masks, not derivatives
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                # Skip files that are already intensity derivatives to prevent recursive processing
                local region_basename=$(basename "$region_file" .nii.gz)
                if [[ "$region_basename" == *"_intensity"* ]] || [[ "$region_basename" == *"_flair_"* ]] || [[ "$region_basename" == *"_clustered"* ]] || [[ "$region_basename" == *"_validated"* ]]; then
                    continue
                fi
                
                apply_reverse_orientation "$region_file"
            fi
        done
        
        log_message "✓ Reverse orientation correction applied to all Talairach outputs"
    fi
    
    # Validate against Harvard-Oxford brainstem boundaries
    if [ -n "$harvard_brainstem_mask" ] && [ -f "$harvard_brainstem_mask" ]; then
        log_message "Validating Talairach subdivisions against Harvard-Oxford boundaries..."
        
        # CRITICAL FIX: Apply the same orientation correction to Harvard-Oxford mask if needed
        local validation_harvard_mask="$harvard_brainstem_mask"
        if [ "$orientation_corrected" = "true" ]; then
            log_message "Applying same orientation correction to Harvard-Oxford mask for consistent validation..."
            local temp_harvard="${temp_dir}/harvard_orientation_corrected.nii.gz"
            
            # Determine input and corrected orientations
            local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
            local corrected_orient=$(fslorient -getorient "$orientation_corrected_input" 2>/dev/null || echo "UNKNOWN")
            
            if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$corrected_orient" = "RADIOLOGICAL" ]; then
                # Apply same correction as was applied to input
                fslswapdim "$harvard_brainstem_mask" -x y z "$temp_harvard"
                fslorient -forceradiological "$temp_harvard"
                validation_harvard_mask="$temp_harvard"
                log_message "✓ Applied NEUROLOGICAL→RADIOLOGICAL correction to Harvard-Oxford mask"
            elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$corrected_orient" = "NEUROLOGICAL" ]; then
                # Apply same correction as was applied to input
                fslswapdim "$harvard_brainstem_mask" -x y z "$temp_harvard"
                fslorient -forceneurological "$temp_harvard"
                validation_harvard_mask="$temp_harvard"
                log_message "✓ Applied RADIOLOGICAL→NEUROLOGICAL correction to Harvard-Oxford mask"
            else
                log_message "No additional orientation correction needed for Harvard-Oxford mask"
            fi
        else
            log_message "No orientation correction applied, using original Harvard-Oxford mask"
        fi
        
        validate_talairach_region() {
            local region_file="$1"
            local region_name="$2"
            
            if [ -f "$region_file" ]; then
                # Create intersection with orientation-consistent Harvard-Oxford brainstem
                local validated_file="${region_file%.nii.gz}_validated.nii.gz"
                
                # Check dimensions match before masking
                local region_dims=$(fslinfo "$region_file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                local harvard_dims=$(fslinfo "$validation_harvard_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                
                if [ "$region_dims" != "$harvard_dims" ]; then
                    log_formatted "WARNING" "$region_name: Dimension mismatch with Harvard-Oxford mask ($region_dims vs $harvard_dims)"
                    log_message "Skipping validation for $region_name due to dimension mismatch"
                    return
                fi
                
                fslmaths "$region_file" -mas "$validation_harvard_mask" "$validated_file"
                
                # Count voxels before and after validation
                local orig_voxels=$(fslstats "$region_file" -V | awk '{print $1}')
                local valid_voxels=$(fslstats "$validated_file" -V | awk '{print $1}')
                
                if [ "$orig_voxels" -gt 0 ]; then
                    local percentage=$(echo "scale=1; $valid_voxels * 100 / $orig_voxels" | bc)
                    log_message "$region_name: $valid_voxels of $orig_voxels voxels (${percentage}%) within Harvard-Oxford brainstem"
                    
                    # Replace with validated version if reasonable overlap
                    if (( $(echo "$percentage >= 70" | bc -l) )); then
                        mv "$validated_file" "$region_file"
                        log_message "✓ $region_name: Validated and constrained to Harvard-Oxford boundaries"
                    else
                        log_formatted "WARNING" "$region_name: Poor overlap (${percentage}%) with Harvard-Oxford brainstem"
                        rm -f "$validated_file"
                    fi
                else
                    rm -f "$validated_file"
                fi
            fi
        }
        
        # Validate all regions
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                local region_name=$(basename "$region_file" .nii.gz | sed "s/${output_basename}_//")
                validate_talairach_region "$region_file" "$region_name"
            fi
        done
        
        # Validate combined pons
        if [ -f "$combined_pons" ]; then
            validate_talairach_region "$combined_pons" "combined_pons"
        fi
    fi
    
    # Create intensity versions for QA compatibility
    log_message "Creating intensity versions for QA module compatibility..."
    log_message "Files being created for each Talairach segmentation:"
    
    # Only process original binary mask files, not intensity derivatives
    for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
        if [ -f "$region_file" ]; then
            # Skip files that are already intensity derivatives to prevent recursive processing
            local region_basename=$(basename "$region_file" .nii.gz)
            if [[ "$region_basename" == *"_intensity"* ]] || [[ "$region_basename" == *"_flair_"* ]] || [[ "$region_basename" == *"_clustered"* ]] || [[ "$region_basename" == *"_validated"* ]]; then
                continue
            fi
            
            local region_name=$(basename "$region_file" .nii.gz)
            local base_region_name=$(echo "$region_name" | sed "s/${output_basename}_//")
            
            log_message "=== $base_region_name FILES ==="
            
            # Log the mask file creation (already exists)
            log_message "✓ Binary mask: $(basename "$region_file")"
            
            # Create intensity version
            local intensity_file="${region_file%.nii.gz}_intensity.nii.gz"
            if fslmaths "$input_file" -mas "$region_file" "$intensity_file"; then
                log_message "✓ Intensity file: $(basename "$intensity_file")"
            else
                log_formatted "WARNING" "Failed to create intensity file for $base_region_name"
            fi
            
            # Also create T1 intensity version
            local t1_intensity_file="${region_file%.nii.gz}_t1_intensity.nii.gz"
            if fslmaths "$input_file" -mas "$region_file" "$t1_intensity_file"; then
                log_message "✓ T1 intensity file: $(basename "$t1_intensity_file")"
            else
                log_formatted "WARNING" "Failed to create T1 intensity file for $base_region_name"
            fi
            
            # Check for clustering if MIN_HYPERINTENSITY_SIZE is set
            if [ -n "${MIN_HYPERINTENSITY_SIZE:-}" ] && [ "${MIN_HYPERINTENSITY_SIZE}" -gt 0 ]; then
                local clustered_file="${region_file%.nii.gz}_clustered.nii.gz"
                log_message "✓ Clustering: Will apply MIN_HYPERINTENSITY_SIZE=${MIN_HYPERINTENSITY_SIZE} voxels in analysis"
                log_message "   Output file: $(basename "$clustered_file")"
            fi
            
            log_message ""
        fi
    done
    
    # Create FLAIR-space versions for hyperintensity analysis compatibility
    log_message "Creating FLAIR-space versions for hyperintensity analysis compatibility..."
    
    # Look for original FLAIR files
    local original_flair_files=()
    if [ -d "${RESULTS_DIR}/standardized" ]; then
        while IFS= read -r -d '' orig_flair; do
            original_flair_files+=("$orig_flair")
        done < <(find "${RESULTS_DIR}/standardized" -name "*FLAIR*_std.nii.gz" -o -name "*flair*_std.nii.gz" -print0 2>/dev/null)
    fi
    
    log_message "Found ${#original_flair_files[@]} FLAIR files for hyperintensity analysis"
    
    # Create FLAIR-space versions for each original FLAIR found
    for orig_flair in "${original_flair_files[@]}"; do
        if [ -f "$orig_flair" ]; then
            log_message "Creating FLAIR-space Talairach analysis versions from: $(basename "$orig_flair")"
            
            # Create output directory for FLAIR-space analysis files
            local flair_analysis_dir="${RESULTS_DIR}/comprehensive_analysis/original_space"
            mkdir -p "$flair_analysis_dir"
            
            # Process each Talairach region - only process original binary masks, not derivatives
            for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
                if [ -f "$region_file" ]; then
                    # Skip files that are already derivatives to prevent recursive processing
                    local region_basename=$(basename "$region_file" .nii.gz)
                    if [[ "$region_basename" == *"_intensity"* ]] || [[ "$region_basename" == *"_flair_"* ]] || [[ "$region_basename" == *"_clustered"* ]] || [[ "$region_basename" == *"_validated"* ]]; then
                        continue
                    fi
                    
                    local region_name=$(echo "$region_basename" | sed "s/${output_basename}_//")
                    
                    # Resample T1-space mask to FLAIR space
                    local flair_space_mask="${flair_analysis_dir}/${region_basename}_flair_space.nii.gz"
                    
                    # Use standardize_dimensions function from preprocessing module to resample mask to FLAIR grid
                    if command -v standardize_dimensions &> /dev/null; then
                        log_message "Resampling ${region_name} mask to FLAIR space..."
                        
                        # Use reference file mode for identical matrix dimensions
                        if standardize_dimensions "$region_file" "" "$orig_flair"; then
                            # standardize_dimensions creates output in standardized dir, so we need to find and move it
                            local std_output="${RESULTS_DIR}/standardized/$(basename "$region_file" .nii.gz)_std.nii.gz"
                            if [ -f "$std_output" ]; then
                                mv "$std_output" "$flair_space_mask"
                                log_message "✓ Moved resampled ${region_name} mask to FLAIR space"
                            else
                                # Fallback: use flirt
                                log_message "Using flirt fallback for ${region_name}..."
                                flirt -in "$region_file" -ref "$orig_flair" -out "$flair_space_mask" -applyxfm -usesqform -interp nearestneighbour
                            fi
                        else
                            # Fallback: use flirt
                            log_message "Using flirt fallback for ${region_name}..."
                            flirt -in "$region_file" -ref "$orig_flair" -out "$flair_space_mask" -applyxfm -usesqform -interp nearestneighbour
                        fi
                    else
                        # Fallback: use flirt
                        log_message "Using flirt for ${region_name} (standardize_dimensions not available)..."
                        flirt -in "$region_file" -ref "$orig_flair" -out "$flair_space_mask" -applyxfm -usesqform -interp nearestneighbour
                    fi
                    
                    # Create FLAIR-space intensity version
                    if [ -f "$flair_space_mask" ]; then
                        local flair_space_intensity="${flair_analysis_dir}/${region_basename}_flair_intensity.nii.gz"
                        
                        # Apply mask to original FLAIR to create intensity version
                        if fslmaths "$orig_flair" -mas "$flair_space_mask" "$flair_space_intensity"; then
                            log_message "✓ Created FLAIR-space ${region_name} intensity version"
                        else
                            log_formatted "WARNING" "Failed to create FLAIR-space ${region_name} intensity version"
                        fi
                        
                        # Create analysis-compatible binary mask with proper naming
                        # Analysis expects to find *pons*.nii.gz and Talairach subdivisions
                        local analysis_region_mask="${flair_analysis_dir}/${region_basename}.nii.gz"
                        if cp "$flair_space_mask" "$analysis_region_mask"; then
                            log_message "✓ Created analysis-compatible ${region_name} mask: $(basename "$analysis_region_mask")"
                        else
                            log_formatted "WARNING" "Failed to create analysis-compatible ${region_name} mask"
                        fi
                    fi
                fi
            done
            
            # Create the missing brainstem_location_check_intensity.nii.gz file that analysis expects
            log_message "Creating missing brainstem_location_check_intensity.nii.gz for analysis compatibility..."
            local combined_brainstem_mask="${flair_analysis_dir}/${output_basename}_combined_brainstem_flair_space.nii.gz"
            local brainstem_intensity="${flair_analysis_dir}/brainstem_location_check_intensity.nii.gz"
            
            # Combine all Talairach brainstem regions into one mask
            local first_region=""
            for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz; do
                if [ -f "$region_file" ]; then
                    local region_basename=$(basename "$region_file" .nii.gz)
                    local flair_space_mask="${flair_analysis_dir}/${region_basename}_flair_space.nii.gz"
                    
                    if [ -f "$flair_space_mask" ]; then
                        if [ -z "$first_region" ]; then
                            # First region - initialize the combined mask
                            cp "$flair_space_mask" "$combined_brainstem_mask"
                            first_region="true"
                        else
                            # Add subsequent regions
                            fslmaths "$combined_brainstem_mask" -add "$flair_space_mask" -bin "$combined_brainstem_mask"
                        fi
                    fi
                fi
            done
            
            # Create intensity version of combined brainstem
            if [ -f "$combined_brainstem_mask" ]; then
                if fslmaths "$orig_flair" -mas "$combined_brainstem_mask" "$brainstem_intensity"; then
                    log_message "✓ Created brainstem_location_check_intensity.nii.gz for analysis compatibility"
                else
                    log_formatted "WARNING" "Failed to create brainstem_location_check_intensity.nii.gz"
                fi
            fi
            
            # Only process the first FLAIR file
            break
        fi
    done
    
    if [ ${#original_flair_files[@]} -eq 0 ]; then
        log_message "No original FLAIR files found for FLAIR-space Talairach versions"
    fi
    
    # Generate summary report
    {
        echo "Talairach Brainstem Subdivision Report (Reused Transform)"
        echo "========================================================"
        echo "Date: $(date)"
        echo "Subject: $output_basename"
        echo "Transform source: Harvard-Oxford registration (SHARED)"
        echo ""
        echo "Successfully extracted regions:"
        
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                local region_name=$(basename "$region_file" .nii.gz | sed "s/${output_basename}_//")
                local voxels=$(fslstats "$region_file" -V | awk '{print $1}')
                local volume=$(fslstats "$region_file" -V | awk '{print $2}')
                echo "  $region_name: $voxels voxels ($volume mm³)"
            fi
        done
        
        echo ""
        echo "Combined regions:"
        if [ -f "$combined_pons" ]; then
            local pons_voxels=$(fslstats "$combined_pons" -V | awk '{print $1}')
            local pons_volume=$(fslstats "$combined_pons" -V | awk '{print $2}')
            echo "  Combined pons: $pons_voxels voxels ($pons_volume mm³)"
        fi
        
        echo ""
        echo "Files created in:"
        echo "  Detailed subdivisions: $detailed_dir"
        echo "  Combined pons: $pons_dir"
        echo ""
        echo "Performance: Registration SKIPPED - reused Harvard-Oxford transform"
        echo "Validation: All regions constrained to Harvard-Oxford brainstem boundaries"
        
    } > "${detailed_dir}/talairach_subdivision_report_shared_transform.txt"
    
    log_formatted "SUCCESS" "Talairach brainstem subdivision complete (reused transform - no duplicate registration)"
    log_message "Report: ${detailed_dir}/talairach_subdivision_report_shared_transform.txt"
    
    # Clean up
    rm -rf "$temp_dir"
    return 0
}

# Function to extract brainstem subdivisions using Talairach atlas (standalone)
extract_brainstem_talairach() {
    local input_file="$1"
    local output_basename="$2"
    local harvard_brainstem_mask="${3:-}"  # Optional Harvard-Oxford boundary constraint
    
    log_formatted "INFO" "===== TALAIRACH ATLAS BRAINSTEM SUBDIVISION (STANDALONE) ====="
    log_message "Input: $input_file"
    log_message "Output basename: $output_basename"
    log_message "Harvard-Oxford constraint: ${harvard_brainstem_mask:-none}"
    
    # Validate input
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file not found: $input_file"
        return 1
    fi
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Set up output directories
    local pons_dir="${RESULTS_DIR}/segmentation/pons"
    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
    mkdir -p "$pons_dir" "$detailed_dir"
    
    # Determine template resolution
    local template_res="${DEFAULT_TEMPLATE_RES:-1mm}"
    if [ "${AUTO_DETECT_RESOLUTION:-true}" = "true" ]; then
        local voxel_size=$(fslinfo "$input_file" | grep "^pixdim1" | awk '{print $2}')
        if (( $(echo "$voxel_size > 1.5" | bc -l) )); then
            template_res="2mm"
        else
            template_res="1mm"
        fi
    fi
    
    # Find Talairach atlas
    local talairach_atlas=""
    local atlas_search_paths=(
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-${template_res}.nii.gz"
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-1mm.nii.gz"
        "${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    )
    
    for atlas_file in "${atlas_search_paths[@]}"; do
        if [ -f "$atlas_file" ]; then
            talairach_atlas="$atlas_file"
            log_message "Found Talairach atlas: $atlas_file"
            break
        fi
    done
    
    if [ -z "$talairach_atlas" ]; then
        log_formatted "ERROR" "Talairach atlas not found in any expected location"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate Talairach atlas using atlasq
    log_message "Validating Talairach atlas structure..."
    if command -v atlasq &> /dev/null; then
        local atlas_summary=$(atlasq summary talairach 2>/dev/null | grep -i "brainstem\|pons" | head -5)
        if [ -n "$atlas_summary" ]; then
            log_formatted "SUCCESS" "✓ Talairach atlas contains brainstem structures:"
            echo "$atlas_summary" | while read line; do
                log_message "  $line"
            done
        else
            log_formatted "WARNING" "Could not validate Talairach brainstem structures with atlasq"
        fi
    fi
    
    # Set up MNI templates
    local mni_template="${TEMPLATE_DIR}/MNI152_T1_${template_res}.nii.gz"
    local mni_brain="${TEMPLATE_DIR}/MNI152_T1_${template_res}_brain.nii.gz"
    
    if [ ! -f "$mni_template" ] || [ ! -f "$mni_brain" ]; then
        log_formatted "ERROR" "MNI templates not found at resolution ${template_res}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Handle orientation correction (same as Harvard-Oxford module)
    log_message "Validating coordinate spaces for Talairach transformation..."
    local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
    local mni_orient=$(fslorient -getorient "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    
    log_message "Subject T1 orientation: $input_orient"
    log_message "MNI template orientation: $mni_orient"
    
    local orientation_corrected_input="$input_file"
    local orientation_corrected=false
    
    if [ "$input_orient" != "UNKNOWN" ] && [ "$mni_orient" != "UNKNOWN" ] && [ "$input_orient" != "$mni_orient" ]; then
        log_formatted "WARNING" "Orientation mismatch detected: Subject ($input_orient) vs MNI ($mni_orient)"
        log_formatted "INFO" "Applying orientation correction for Talairach processing"
        
        orientation_corrected_input="${temp_dir}/input_orientation_corrected.nii.gz"
        
        if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
            fslswapdim "$input_file" -x y z "$orientation_corrected_input"
            fslorient -forceradiological "$orientation_corrected_input"
            orientation_corrected=true
        elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
            fslswapdim "$input_file" -x y z "$orientation_corrected_input"
            fslorient -forceneurological "$orientation_corrected_input"
            orientation_corrected=true
        else
            log_message "Proceeding without orientation correction"
            cp "$input_file" "$orientation_corrected_input"
        fi
    else
        cp "$input_file" "${temp_dir}/input_orientation_corrected.nii.gz"
        orientation_corrected_input="${temp_dir}/input_orientation_corrected.nii.gz"
    fi
    
    # Set up ANTs registration parameters
    local ants_prefix="${temp_dir}/talairach_ants_to_mni_"
    
    # Register to MNI space to get transformation matrix
    log_message "Registering to MNI space to obtain transformation for atlas-to-subject mapping..."
    
    # CRITICAL FIX: Use full SyN registration (affine + warp) for proper composite transforms
    # Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)
    log_formatted "INFO" "Using composite SyN registration for Talairach (affine + nonlinear warp)"
    
    if [ "$orientation_corrected" = "true" ]; then
        execute_ants_command "talairach_to_mni_syn_registration" "Talairach: Full SyN registration to MNI template (orientation corrected)" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    else
        execute_ants_command "talairach_to_mni_syn_registration" "Talairach: Full SyN registration to MNI template" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    fi
    
    # Check composite registration success - both components required
    if [ ! -f "${ants_prefix}0GenericAffine.mat" ]; then
        log_formatted "ERROR" "Talairach ANTs registration failed - affine transform not created"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ ! -f "${ants_prefix}1Warp.nii.gz" ]; then
        log_formatted "ERROR" "Talairach ANTs registration failed - warp field not created"
        log_formatted "ERROR" "Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate transform files are non-empty and readable
    local affine_size=$(stat -f "%z" "${ants_prefix}0GenericAffine.mat" 2>/dev/null || stat --format="%s" "${ants_prefix}0GenericAffine.mat" 2>/dev/null || echo "0")
    local warp_size=$(stat -f "%z" "${ants_prefix}1Warp.nii.gz" 2>/dev/null || stat --format="%s" "${ants_prefix}1Warp.nii.gz" 2>/dev/null || echo "0")
    
    if [ "$affine_size" -lt 100 ]; then
        log_formatted "ERROR" "Talairach affine transform file is suspiciously small or empty: $affine_size bytes"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ "$warp_size" -lt 1000 ]; then
        log_formatted "ERROR" "Talairach warp field file is suspiciously small or empty: $warp_size bytes"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_formatted "SUCCESS" "Talairach composite registration completed successfully"
    log_message "  Affine component: ${ants_prefix}0GenericAffine.mat ($affine_size bytes)"
    log_message "  Warp component: ${ants_prefix}1Warp.nii.gz ($warp_size bytes)"
    
    # Transform entire Talairach atlas to subject space (preserving native resolution)
    log_message "Transforming Talairach atlas to subject native space..."
    
    local atlas_in_subject="${temp_dir}/talairach_atlas_in_subject.nii.gz"
    
    # CRITICAL FIX: Use composite transforms in correct order
    # Composite transforms: replace -t "$transform" with -t "${out}_1Warp.nii.gz" -t "${out}_0GenericAffine.mat"
    log_message "Applying composite transforms: warp field + affine (atlas→subject mapping)"
    
    antsApplyTransforms -d 3 \
        -i "$talairach_atlas" \
        -r "$orientation_corrected_input" \
        -o "$atlas_in_subject" \
        -t "[${ants_prefix}0GenericAffine.mat,1]" \
        -t "${ants_prefix}1Warp.nii.gz" \
        -n GenericLabel
    
    # Check if atlas transformation was successful
    if [ ! -f "$atlas_in_subject" ]; then
        log_formatted "ERROR" "Failed to transform Talairach atlas to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "✓ Talairach atlas successfully transformed to subject native space"
    
    # Extract brainstem regions directly from atlas in subject space
    log_message "Extracting brainstem subdivisions from atlas in subject space..."
    
    # Extract individual regions from atlas in subject space
    extract_talairach_region() {
        local region_index="$1"
        local region_name="$2"
        local output_file="$3"
        
        log_message "Extracting $region_name (index $region_index) from subject-space atlas..."
        fslmaths "$atlas_in_subject" -thr $region_index -uthr $region_index -bin "$output_file"
        
        local voxel_count=$(fslstats "$output_file" -V | awk '{print $1}')
        if [ "$voxel_count" -gt 10 ]; then
            log_message "✓ $region_name: $voxel_count voxels in subject space"
            return 0
        else
            log_formatted "WARNING" "$region_name has insufficient voxels ($voxel_count) in subject space"
            return 1
        fi
    }
    
    # Extract all brainstem regions
    extract_talairach_region $TALAIRACH_LEFT_MEDULLA "left_medulla" "${detailed_dir}/${output_basename}_left_medulla.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_MEDULLA "right_medulla" "${detailed_dir}/${output_basename}_right_medulla.nii.gz"
    extract_talairach_region $TALAIRACH_LEFT_PONS "left_pons" "${detailed_dir}/${output_basename}_left_pons.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_PONS "right_pons" "${detailed_dir}/${output_basename}_right_pons.nii.gz"
    extract_talairach_region $TALAIRACH_LEFT_MIDBRAIN "left_midbrain" "${detailed_dir}/${output_basename}_left_midbrain.nii.gz"
    extract_talairach_region $TALAIRACH_RIGHT_MIDBRAIN "right_midbrain" "${detailed_dir}/${output_basename}_right_midbrain.nii.gz"
    
    # Create combined pons mask (left + right)
    local combined_pons="${pons_dir}/${output_basename}_pons.nii.gz"
    log_message "Creating combined pons mask..."
    
    local left_pons="${detailed_dir}/${output_basename}_left_pons.nii.gz"
    local right_pons="${detailed_dir}/${output_basename}_right_pons.nii.gz"
    
    if [ -f "$left_pons" ] && [ -f "$right_pons" ]; then
        fslmaths "$left_pons" -add "$right_pons" -bin "$combined_pons"
    elif [ -f "$left_pons" ]; then
        cp "$left_pons" "$combined_pons"
    elif [ -f "$right_pons" ]; then
        cp "$right_pons" "$combined_pons"
    else
        log_formatted "WARNING" "No pons regions successfully extracted from Talairach"
        # Create empty pons for pipeline compatibility
        if [ -f "$input_file" ]; then
            fslmaths "$input_file" -mul 0 "$combined_pons"
        fi
    fi
    
    # Validate against Harvard-Oxford brainstem boundaries if provided
    if [ -n "$harvard_brainstem_mask" ] && [ -f "$harvard_brainstem_mask" ]; then
        log_message "Validating Talairach subdivisions against Harvard-Oxford boundaries..."
        
        # CRITICAL FIX: Apply the same orientation correction to Harvard-Oxford mask if needed
        local validation_harvard_mask="$harvard_brainstem_mask"
        if [ "$orientation_corrected" = "true" ]; then
            log_message "Applying same orientation correction to Harvard-Oxford mask for consistent validation..."
            local temp_harvard="${temp_dir}/harvard_orientation_corrected_standalone.nii.gz"
            
            # Determine input and corrected orientations
            local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
            local corrected_orient=$(fslorient -getorient "$orientation_corrected_input" 2>/dev/null || echo "UNKNOWN")
            
            if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$corrected_orient" = "RADIOLOGICAL" ]; then
                # Apply same correction as was applied to input
                fslswapdim "$harvard_brainstem_mask" -x y z "$temp_harvard"
                fslorient -forceradiological "$temp_harvard"
                validation_harvard_mask="$temp_harvard"
                log_message "✓ Applied NEUROLOGICAL→RADIOLOGICAL correction to Harvard-Oxford mask"
            elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$corrected_orient" = "NEUROLOGICAL" ]; then
                # Apply same correction as was applied to input
                fslswapdim "$harvard_brainstem_mask" -x y z "$temp_harvard"
                fslorient -forceneurological "$temp_harvard"
                validation_harvard_mask="$temp_harvard"
                log_message "✓ Applied RADIOLOGICAL→NEUROLOGICAL correction to Harvard-Oxford mask"
            else
                log_message "No additional orientation correction needed for Harvard-Oxford mask"
            fi
        else
            log_message "No orientation correction applied, using original Harvard-Oxford mask"
        fi
        
        validate_talairach_region() {
            local region_file="$1"
            local region_name="$2"
            
            if [ -f "$region_file" ]; then
                # Create intersection with orientation-consistent Harvard-Oxford brainstem
                local validated_file="${region_file%.nii.gz}_validated.nii.gz"
                
                # Check dimensions match before masking
                local region_dims=$(fslinfo "$region_file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                local harvard_dims=$(fslinfo "$validation_harvard_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                
                if [ "$region_dims" != "$harvard_dims" ]; then
                    log_formatted "WARNING" "$region_name: Dimension mismatch with Harvard-Oxford mask ($region_dims vs $harvard_dims)"
                    log_message "Skipping validation for $region_name due to dimension mismatch"
                    return
                fi
                
                fslmaths "$region_file" -mas "$validation_harvard_mask" "$validated_file"
                
                # Count voxels before and after validation
                local orig_voxels=$(fslstats "$region_file" -V | awk '{print $1}')
                local valid_voxels=$(fslstats "$validated_file" -V | awk '{print $1}')
                
                if [ "$orig_voxels" -gt 0 ]; then
                    local percentage=$(echo "scale=1; $valid_voxels * 100 / $orig_voxels" | bc)
                    log_message "$region_name: $valid_voxels of $orig_voxels voxels (${percentage}%) within Harvard-Oxford brainstem"
                    
                    # Replace with validated version if reasonable overlap
                    if (( $(echo "$percentage >= 70" | bc -l) )); then
                        mv "$validated_file" "$region_file"
                        log_message "✓ $region_name: Validated and constrained to Harvard-Oxford boundaries"
                    else
                        log_formatted "WARNING" "$region_name: Poor overlap (${percentage}%) with Harvard-Oxford brainstem"
                        rm -f "$validated_file"
                    fi
                else
                    rm -f "$validated_file"
                fi
            fi
        }
        
        # Validate all regions
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                local region_name=$(basename "$region_file" .nii.gz | sed "s/${output_basename}_//")
                validate_talairach_region "$region_file" "$region_name"
            fi
        done
        
        # Validate combined pons
        if [ -f "$combined_pons" ]; then
            validate_talairach_region "$combined_pons" "combined_pons"
        fi
    fi
    
    # Create intensity versions for QA compatibility
    log_message "Creating intensity versions for QA module compatibility..."
    log_message "Files being created for each Talairach segmentation:"
    
    # Only process original binary mask files, not intensity derivatives
    for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
        if [ -f "$region_file" ]; then
            # Skip files that are already intensity derivatives to prevent recursive processing
            local region_basename=$(basename "$region_file" .nii.gz)
            if [[ "$region_basename" == *"_intensity"* ]] || [[ "$region_basename" == *"_flair_"* ]] || [[ "$region_basename" == *"_clustered"* ]] || [[ "$region_basename" == *"_validated"* ]]; then
                continue
            fi
            
            local region_name=$(basename "$region_file" .nii.gz)
            local base_region_name=$(echo "$region_name" | sed "s/${output_basename}_//")
            
            log_message "=== $base_region_name FILES ==="
            
            # Log the mask file creation (already exists)
            log_message "✓ Binary mask: $(basename "$region_file")"
            
            # Create intensity version
            local intensity_file="${region_file%.nii.gz}_intensity.nii.gz"
            if fslmaths "$input_file" -mas "$region_file" "$intensity_file"; then
                log_message "✓ Intensity file: $(basename "$intensity_file")"
            else
                log_formatted "WARNING" "Failed to create intensity file for $base_region_name"
            fi
            
            # Also create T1 intensity version
            local t1_intensity_file="${region_file%.nii.gz}_t1_intensity.nii.gz"
            if fslmaths "$input_file" -mas "$region_file" "$t1_intensity_file"; then
                log_message "✓ T1 intensity file: $(basename "$t1_intensity_file")"
            else
                log_formatted "WARNING" "Failed to create T1 intensity file for $base_region_name"
            fi
            
            # Check for clustering if MIN_HYPERINTENSITY_SIZE is set
            if [ -n "${MIN_HYPERINTENSITY_SIZE:-}" ] && [ "${MIN_HYPERINTENSITY_SIZE}" -gt 0 ]; then
                local clustered_file="${region_file%.nii.gz}_clustered.nii.gz"
                log_message "✓ Clustering: Will apply MIN_HYPERINTENSITY_SIZE=${MIN_HYPERINTENSITY_SIZE} voxels in analysis"
                log_message "   Output file: $(basename "$clustered_file")"
            fi
            
            log_message ""
        fi
    done
    
    # Generate summary report
    {
        echo "Talairach Brainstem Subdivision Report"
        echo "====================================="
        echo "Date: $(date)"
        echo "Subject: $output_basename"
        echo ""
        echo "Successfully extracted regions:"
        
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                local region_name=$(basename "$region_file" .nii.gz | sed "s/${output_basename}_//")
                local voxels=$(fslstats "$region_file" -V | awk '{print $1}')
                local volume=$(fslstats "$region_file" -V | awk '{print $2}')
                echo "  $region_name: $voxels voxels ($volume mm³)"
            fi
        done
        
        echo ""
        echo "Combined regions:"
        if [ -f "$combined_pons" ]; then
            local pons_voxels=$(fslstats "$combined_pons" -V | awk '{print $1}')
            local pons_volume=$(fslstats "$combined_pons" -V | awk '{print $2}')
            echo "  Combined pons: $pons_voxels voxels ($pons_volume mm³)"
        fi
        
        echo ""
        echo "Files created in:"
        echo "  Detailed subdivisions: $detailed_dir"
        echo "  Combined pons: $pons_dir"
        
        if [ -n "$harvard_brainstem_mask" ]; then
            echo ""
            echo "Validation: All regions constrained to Harvard-Oxford brainstem boundaries"
        fi
        
    } > "${detailed_dir}/talairach_subdivision_report.txt"
    
    log_formatted "SUCCESS" "Talairach brainstem subdivision complete"
    log_message "Report: ${detailed_dir}/talairach_subdivision_report.txt"
    
    # Clean up
    rm -rf "$temp_dir"
    return 0
}

# Export functions
export -f extract_brainstem_talairach_with_transform
export -f extract_brainstem_talairach

log_message "Talairach atlas segmentation module loaded"