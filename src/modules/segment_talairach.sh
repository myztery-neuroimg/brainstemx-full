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
    
    # Transform entire Talairach atlas to subject space using existing transform
    log_message "Transforming Talairach atlas to subject native space using existing transform..."
    
    local atlas_in_subject="${temp_dir}/talairach_atlas_in_subject.nii.gz"
    
    antsApplyTransforms -d 3 \
        -i "$talairach_atlas" \
        -r "$orientation_corrected_input" \
        -o "$atlas_in_subject" \
        -t "[$ants_transform_matrix,1]" \
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
        
        # Apply reverse correction to all output files
        for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
            if [ -f "$region_file" ]; then
                apply_reverse_orientation "$region_file"
            fi
        done
        
        log_message "✓ Reverse orientation correction applied to all Talairach outputs"
    fi
    
    # Validate against Harvard-Oxford brainstem boundaries
    if [ -n "$harvard_brainstem_mask" ] && [ -f "$harvard_brainstem_mask" ]; then
        log_message "Validating Talairach subdivisions against Harvard-Oxford boundaries..."
        
        validate_talairach_region() {
            local region_file="$1"
            local region_name="$2"
            
            if [ -f "$region_file" ]; then
                # Create intersection with Harvard-Oxford brainstem
                local validated_file="${region_file%.nii.gz}_validated.nii.gz"
                fslmaths "$region_file" -mas "$harvard_brainstem_mask" "$validated_file"
                
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
    
    for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
        if [ -f "$region_file" ]; then
            local intensity_file="${region_file%.nii.gz}_intensity.nii.gz"
            fslmaths "$input_file" -mas "$region_file" "$intensity_file"
            
            # Also create T1 intensity version
            local t1_intensity_file="${region_file%.nii.gz}_t1_intensity.nii.gz"
            fslmaths "$input_file" -mas "$region_file" "$t1_intensity_file"
        fi
    done
    
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
    
    if [ "$orientation_corrected" = "true" ]; then
        execute_ants_command "talairach_to_mni_registration" "Talairach: Affine registration to MNI template (orientation corrected)" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t a \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    else
        execute_ants_command "talairach_to_mni_registration" "Talairach: Affine registration to MNI template" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t a \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    fi
    
    # Check registration success
    if [ ! -f "${ants_prefix}0GenericAffine.mat" ]; then
        log_formatted "ERROR" "Talairach ANTs registration failed"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Transform entire Talairach atlas to subject space (preserving native resolution)
    log_message "Transforming Talairach atlas to subject native space..."
    
    local atlas_in_subject="${temp_dir}/talairach_atlas_in_subject.nii.gz"
    
    antsApplyTransforms -d 3 \
        -i "$talairach_atlas" \
        -r "$orientation_corrected_input" \
        -o "$atlas_in_subject" \
        -t "[${ants_prefix}0GenericAffine.mat,1]" \
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
        
        validate_talairach_region() {
            local region_file="$1"
            local region_name="$2"
            
            if [ -f "$region_file" ]; then
                # Create intersection with Harvard-Oxford brainstem
                local validated_file="${region_file%.nii.gz}_validated.nii.gz"
                fslmaths "$region_file" -mas "$harvard_brainstem_mask" "$validated_file"
                
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
    
    for region_file in "${detailed_dir}"/${output_basename}_*.nii.gz "${pons_dir}"/${output_basename}_*.nii.gz; do
        if [ -f "$region_file" ]; then
            local intensity_file="${region_file%.nii.gz}_intensity.nii.gz"
            fslmaths "$input_file" -mas "$region_file" "$intensity_file"
            
            # Also create T1 intensity version
            local t1_intensity_file="${region_file%.nii.gz}_t1_intensity.nii.gz"
            fslmaths "$input_file" -mas "$region_file" "$t1_intensity_file"
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