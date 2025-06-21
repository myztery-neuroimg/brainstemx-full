#!/bin/bash

# Comprehensive validation that atlas regions are anatomically correct after registration
validate_atlas_anatomical_accuracy() {
    local subject_image="$1"           # T1 image in subject space  
    local registered_atlas="$2"        # Atlas transformed to subject space
    local region_index="$3"            # Region to validate (e.g., 7 for brainstem)
    local region_name="$4"             # Human-readable name (e.g., "brainstem")
    local validation_output_dir="$5"   # Where to save validation results
    
    log_formatted "INFO" "===== ANATOMICAL VALIDATION: $region_name ====="
    
    mkdir -p "$validation_output_dir"
    local temp_dir=$(mktemp -d)
    
    # Extract the specific region
    local region_mask="${temp_dir}/${region_name}_mask.nii.gz"
    local tolerance_lower=$(echo "$region_index - 0.1" | bc -l)
    local tolerance_upper=$(echo "$region_index + 0.1" | bc -l)
    
    fslmaths "$registered_atlas" -thr $tolerance_lower -uthr $tolerance_upper -bin "$region_mask"
    
    local region_voxels=$(fslstats "$region_mask" -V | awk '{print $1}')
    if [ "$region_voxels" -eq 0 ]; then
        log_formatted "ERROR" "No voxels found for $region_name (index $region_index)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "Found $region_voxels voxels for $region_name"
    
    # VALIDATION 1: Center of Mass Analysis
    validate_center_of_mass() {
        log_message "=== CENTER OF MASS VALIDATION ==="
        
        # Calculate center of mass
        local com_output=$(fslstats "$region_mask" -C)
        local com_x=$(echo "$com_output" | awk '{print $1}')
        local com_y=$(echo "$com_output" | awk '{print $2}')  
        local com_z=$(echo "$com_output" | awk '{print $3}')
        
        log_message "Region center of mass: ($com_x, $com_y, $com_z)"
        
        # Get image dimensions and calculate expected center
        local img_info=$(fslinfo "$subject_image")
        local dim_x=$(echo "$img_info" | grep "^dim1" | awk '{print $2}')
        local dim_y=$(echo "$img_info" | grep "^dim2" | awk '{print $2}')
        local dim_z=$(echo "$img_info" | grep "^dim3" | awk '{print $2}')
        
        local center_x=$(echo "$dim_x / 2" | bc -l)
        local center_y=$(echo "$dim_y / 2" | bc -l) 
        local center_z=$(echo "$dim_z / 2" | bc -l)
        
        log_message "Image center: ($center_x, $center_y, $center_z)"
        
        # Calculate deviations
        local dev_x=$(echo "scale=2; ($com_x - $center_x)" | bc -l)
        local dev_y=$(echo "scale=2; ($com_y - $center_y)" | bc -l)
        local dev_z=$(echo "scale=2; ($com_z - $center_z)" | bc -l)
        
        # Expected brainstem location (should be central in X, posterior in Y, inferior in Z)
        local expected_status="PASS"
        case "$region_name" in
            "brainstem")
                # Brainstem should be: central X (±10 voxels), posterior Y (negative), inferior Z (negative)
                if (( $(echo "sqrt($dev_x*$dev_x) > 10" | bc -l) )); then
                    expected_status="FAIL"
                    log_formatted "WARNING" "Brainstem not central in X: deviation = $dev_x voxels"
                fi
                if (( $(echo "$dev_y > 0" | bc -l) )); then
                    expected_status="FAIL" 
                    log_formatted "WARNING" "Brainstem not posterior: Y deviation = $dev_y (should be negative)"
                fi
                ;;
            "left_thalamus"|"right_thalamus")
                # Thalamus should be central in Y and Z, lateralized in X
                if (( $(echo "sqrt($dev_y*$dev_y + $dev_z*$dev_z) > 15" | bc -l) )); then
                    expected_status="FAIL"
                    log_formatted "WARNING" "Thalamus not in expected central location"
                fi
                ;;
        esac
        
        echo "center_of_mass_validation: $expected_status" >> "${validation_output_dir}/validation_summary.txt"
        echo "center_of_mass_coordinates: $com_x,$com_y,$com_z" >> "${validation_output_dir}/validation_summary.txt"
        echo "center_deviations: $dev_x,$dev_y,$dev_z" >> "${validation_output_dir}/validation_summary.txt"
        
        return $([ "$expected_status" = "PASS" ] && echo 0 || echo 1)
    }
    
    # VALIDATION 2: Volume Analysis  
    validate_region_volume() {
        log_message "=== VOLUME VALIDATION ==="
        
        local voxel_volume=$(fslstats "$region_mask" -V | awk '{print $2}')
        log_message "Region volume: ${voxel_volume} mm³"
        
        # Expected volumes (literature-based normal ranges)
        local expected_min expected_max volume_status="PASS"
        case "$region_name" in
            "brainstem")
                expected_min=8000   # ~8-25 cm³ for whole brainstem
                expected_max=25000
                ;;
            "left_thalamus"|"right_thalamus") 
                expected_min=4000   # ~4-8 cm³ per thalamus
                expected_max=8000
                ;;
            "pons")
                expected_min=2000   # ~2-6 cm³ for pons
                expected_max=6000
                ;;
            *)
                expected_min=100    # Generic small structure
                expected_max=50000  # Generic large structure
                ;;
        esac
        
        if (( $(echo "$voxel_volume < $expected_min" | bc -l) )); then
            volume_status="FAIL"
            log_formatted "WARNING" "Volume too small: ${voxel_volume} mm³ < ${expected_min} mm³"
        elif (( $(echo "$voxel_volume > $expected_max" | bc -l) )); then
            volume_status="FAIL"
            log_formatted "WARNING" "Volume too large: ${voxel_volume} mm³ > ${expected_max} mm³"
        else
            log_message "✓ Volume within expected range: ${expected_min}-${expected_max} mm³"
        fi
        
        echo "volume_validation: $volume_status" >> "${validation_output_dir}/validation_summary.txt"
        echo "region_volume: $voxel_volume" >> "${validation_output_dir}/validation_summary.txt"
        echo "expected_volume_range: ${expected_min}-${expected_max}" >> "${validation_output_dir}/validation_summary.txt"
        
        return $([ "$volume_status" = "PASS" ] && echo 0 || echo 1)
    }
    
    # VALIDATION 3: Shape Analysis
    validate_region_shape() {
        log_message "=== SHAPE VALIDATION ==="
        
        # Calculate bounding box
        local bbox_output=$(fslstats "$region_mask" -w)
        local bbox_x_min=$(echo "$bbox_output" | awk '{print $1}')
        local bbox_x_size=$(echo "$bbox_output" | awk '{print $2}')
        local bbox_y_min=$(echo "$bbox_output" | awk '{print $3}')
        local bbox_y_size=$(echo "$bbox_output" | awk '{print $4}')
        local bbox_z_min=$(echo "$bbox_output" | awk '{print $5}')
        local bbox_z_size=$(echo "$bbox_output" | awk '{print $6}')
        
        log_message "Bounding box: X[$bbox_x_min:$((bbox_x_min + bbox_x_size))] Y[$bbox_y_min:$((bbox_y_min + bbox_y_size))] Z[$bbox_z_min:$((bbox_z_min + bbox_z_size))]"
        
        # Calculate aspect ratios
        local aspect_xy=$(echo "scale=3; $bbox_x_size / $bbox_y_size" | bc -l)
        local aspect_xz=$(echo "scale=3; $bbox_x_size / $bbox_z_size" | bc -l)
        local aspect_yz=$(echo "scale=3; $bbox_y_size / $bbox_z_size" | bc -l)
        
        log_message "Aspect ratios: X/Y=$aspect_xy, X/Z=$aspect_xz, Y/Z=$aspect_yz"
        
        # Shape validation based on expected anatomy
        local shape_status="PASS"
        case "$region_name" in
            "brainstem")
                # Brainstem should be elongated in superior-inferior direction (Z)
                if (( $(echo "$aspect_yz < 1.5" | bc -l) )); then
                    shape_status="FAIL"
                    log_formatted "WARNING" "Brainstem not sufficiently elongated in Z direction: Y/Z ratio = $aspect_yz"
                fi
                ;;
            "left_thalamus"|"right_thalamus")
                # Thalamus should be roughly spherical-to-oval
                if (( $(echo "$aspect_xy > 2.0 || $aspect_xz > 2.0 || $aspect_yz > 2.0" | bc -l) )); then
                    shape_status="FAIL"
                    log_formatted "WARNING" "Thalamus shape too elongated"
                fi
                ;;
        esac
        
        echo "shape_validation: $shape_status" >> "${validation_output_dir}/validation_summary.txt"
        echo "bounding_box: ${bbox_x_size}x${bbox_y_size}x${bbox_z_size}" >> "${validation_output_dir}/validation_summary.txt"
        echo "aspect_ratios: ${aspect_xy},${aspect_xz},${aspect_yz}" >> "${validation_output_dir}/validation_summary.txt"
        
        return $([ "$shape_status" = "PASS" ] && echo 0 || echo 1)
    }
    
    # VALIDATION 4: Neighborhood Analysis
    validate_anatomical_neighborhood() {
        log_message "=== NEIGHBORHOOD VALIDATION ==="
        
        # Create dilated mask to check surrounding regions
        local dilated_mask="${temp_dir}/${region_name}_dilated.nii.gz"
        fslmaths "$region_mask" -kernel sphere 5 -dilM "$dilated_mask"
        
        # Check what other atlas regions are nearby
        local neighborhood_mask="${temp_dir}/neighborhood.nii.gz"
        fslmaths "$dilated_mask" -sub "$region_mask" "$neighborhood_mask"
        
        # Get intensities in neighborhood from original atlas
        local neighbor_intensities="${temp_dir}/neighbor_intensities.txt"
        fslmeants -i "$registered_atlas" -m "$neighborhood_mask" --showall > "$neighbor_intensities"
        
        # Analyze neighborhood composition
        local unique_neighbors=$(awk '{print int($1+0.5)}' "$neighbor_intensities" | sort -n | uniq -c | sort -nr)
        log_message "Neighboring atlas regions:"
        echo "$unique_neighbors" | head -5 | while read count intensity; do
            if [ "$intensity" != "0" ] && [ "$intensity" != "$region_index" ]; then
                log_message "  Region $intensity: $count voxels"
            fi
        done
        
        # Expected neighbors validation (region-specific)
        local neighborhood_status="PASS"
        case "$region_name" in
            "brainstem")
                # Brainstem should be near thalamus, cerebellum, etc.
                # This is a simplified check - could be made more sophisticated
                local has_expected_neighbors=$(echo "$unique_neighbors" | grep -E "(10|11|16|17)" | wc -l)
                if [ "$has_expected_neighbors" -eq 0 ]; then
                    neighborhood_status="WARNING"
                    log_formatted "WARNING" "Brainstem neighborhood doesn't contain expected adjacent structures"
                fi
                ;;
        esac
        
        echo "neighborhood_validation: $neighborhood_status" >> "${validation_output_dir}/validation_summary.txt"
        
        return $([ "$neighborhood_status" = "PASS" ] && echo 0 || echo 1)
    }
    
    # VALIDATION 5: Cross-Modal Registration Quality
    validate_registration_quality() {
        log_message "=== REGISTRATION QUALITY VALIDATION ==="
        
        # Calculate correlation between subject image and atlas in region
        local region_correlation=$(fslcc -m "$region_mask" "$subject_image" "$registered_atlas" | awk '{print $3}')
        log_message "Region-specific correlation: $region_correlation"
        
        local quality_status="PASS"
        if (( $(echo "$region_correlation < 0.3" | bc -l) )); then
            quality_status="FAIL"
            log_formatted "WARNING" "Poor registration quality: correlation = $region_correlation"
        elif (( $(echo "$region_correlation < 0.5" | bc -l) )); then
            quality_status="WARNING"
            log_formatted "WARNING" "Moderate registration quality: correlation = $region_correlation"
        else
            log_message "✓ Good registration quality: correlation = $region_correlation"
        fi
        
        echo "registration_quality_validation: $quality_status" >> "${validation_output_dir}/validation_summary.txt"
        echo "region_correlation: $region_correlation" >> "${validation_output_dir}/validation_summary.txt"
        
        return $([ "$quality_status" = "PASS" ] && echo 0 || echo 1)
    }
    
    # Run all validations
    echo "=== ANATOMICAL VALIDATION REPORT FOR $region_name ===" > "${validation_output_dir}/validation_summary.txt"
    echo "validation_date: $(date)" >> "${validation_output_dir}/validation_summary.txt"
    echo "subject_image: $subject_image" >> "${validation_output_dir}/validation_summary.txt"
    echo "registered_atlas: $registered_atlas" >> "${validation_output_dir}/validation_summary.txt"
    echo "region_index: $region_index" >> "${validation_output_dir}/validation_summary.txt"
    echo "region_voxels: $region_voxels" >> "${validation_output_dir}/validation_summary.txt"
    echo "" >> "${validation_output_dir}/validation_summary.txt"
    
    local validation_results=()
    
    validate_center_of_mass && validation_results+=("COM:PASS") || validation_results+=("COM:FAIL")
    validate_region_volume && validation_results+=("VOL:PASS") || validation_results+=("VOL:FAIL") 
    validate_region_shape && validation_results+=("SHAPE:PASS") || validation_results+=("SHAPE:FAIL")
    validate_anatomical_neighborhood && validation_results+=("NEIGHBOR:PASS") || validation_results+=("NEIGHBOR:FAIL")
    validate_registration_quality && validation_results+=("REG:PASS") || validation_results+=("REG:FAIL")
    
    # Overall assessment
    local failed_validations=$(printf '%s\n' "${validation_results[@]}" | grep -c "FAIL")
    local warning_validations=$(printf '%s\n' "${validation_results[@]}" | grep -c "WARNING")
    
    echo "" >> "${validation_output_dir}/validation_summary.txt"
    echo "validation_results: ${validation_results[*]}" >> "${validation_output_dir}/validation_summary.txt"
    echo "failed_validations: $failed_validations" >> "${validation_output_dir}/validation_summary.txt"
    echo "warning_validations: $warning_validations" >> "${validation_output_dir}/validation_summary.txt"
    
    if [ "$failed_validations" -eq 0 ]; then
        if [ "$warning_validations" -eq 0 ]; then
            echo "overall_assessment: EXCELLENT" >> "${validation_output_dir}/validation_summary.txt"
            log_formatted "SUCCESS" "✓ All anatomical validations PASSED - registration is anatomically accurate"
        else
            echo "overall_assessment: GOOD" >> "${validation_output_dir}/validation_summary.txt"
            log_formatted "SUCCESS" "✓ Core validations passed with $warning_validations warnings"
        fi
    elif [ "$failed_validations" -le 2 ]; then
        echo "overall_assessment: QUESTIONABLE" >> "${validation_output_dir}/validation_summary.txt"
        log_formatted "WARNING" "Some validations failed ($failed_validations) - registration quality questionable"
    else
        echo "overall_assessment: FAILED" >> "${validation_output_dir}/validation_summary.txt"
        log_formatted "ERROR" "Multiple validations failed ($failed_validations) - registration likely anatomically incorrect"
    fi
    
    # Create visual validation overlay
    create_validation_overlay "$subject_image" "$region_mask" "${validation_output_dir}/${region_name}_validation_overlay.nii.gz"
    
    # Clean up
    rm -rf "$temp_dir"
    
    log_message "Validation report saved to: ${validation_output_dir}/validation_summary.txt"
    return $([ "$failed_validations" -le 1 ] && echo 0 || echo 1)
}

# Helper function to create validation overlay
create_validation_overlay() {
    local subject_image="$1"
    local region_mask="$2" 
    local output_overlay="$3"
    
    # Create colored overlay showing region boundaries
    fslmaths "$region_mask" -edge -bin -mul 1000 "${output_overlay%%.nii.gz}_edges.nii.gz"
    fslmaths "$subject_image" -add "${output_overlay%%.nii.gz}_edges.nii.gz" "$output_overlay"
    
    rm -f "${output_overlay%%.nii.gz}_edges.nii.gz"
}

# Usage example for BrainStem X integration:
validate_brainstem_segmentation() {
    local t1_subject="$1"
    local registered_harvard_atlas="$2"
    local validation_dir="$3"
    
    # Validate brainstem (Harvard-Oxford index 7)
    validate_atlas_anatomical_accuracy \
        "$t1_subject" \
        "$registered_harvard_atlas" \
        "7" \
        "brainstem" \
        "$validation_dir"
}

validate_atlas_in_subject_space() {
    local subject_t1="$1"
    local atlas_in_subject="$2"
    local validation_output_dir="$3"
    
    log_formatted "INFO" "===== ATLAS VALIDATION WORKFLOW ====="
    
    mkdir -p "$validation_output_dir"
    
    # 1. Extract transformation matrices for debugging
    log_message "Extracting transformation matrices..."
    extract_transformation_matrix "$subject_t1" "sform" "fsl" > "${validation_output_dir}/subject_sform_matrix.txt"
    extract_transformation_matrix "$atlas_in_subject" "sform" "fsl" > "${validation_output_dir}/atlas_sform_matrix.txt"
    
    # 2. Validate each important atlas region
    local validation_results=()
    
    # Brainstem (index 7)
    if validate_atlas_anatomical_accuracy "$subject_t1" "$atlas_in_subject" "7" "brainstem" "${validation_output_dir}/brainstem"; then
        validation_results+=("brainstem:PASS")
    else
        validation_results+=("brainstem:FAIL")
    fi
    
    # Thalamus (indices 10, 11)
    if validate_atlas_anatomical_accuracy "$subject_t1" "$atlas_in_subject" "10" "left_thalamus" "${validation_output_dir}/left_thalamus"; then
        validation_results+=("left_thalamus:PASS")
    else
        validation_results+=("left_thalamus:FAIL")
    fi
    
    # 3. Generate comprehensive report
    {
        echo "=== ATLAS REGISTRATION VALIDATION SUMMARY ==="
        echo "Date: $(date)"
        echo "Subject: $subject_t1"
        echo "Atlas: $atlas_in_subject"
        echo ""
        echo "Validation Results:"
        for result in "${validation_results[@]}"; do
            echo "  $result"
        done
        echo ""
        
        local total_validations=${#validation_results[@]}
        local passed_validations=$(printf '%s\n' "${validation_results[@]}" | grep -c ":PASS")
        
        echo "Summary: $passed_validations/$total_validations regions passed validation"
        
        if [ "$passed_validations" -eq "$total_validations" ]; then
            echo "OVERALL ASSESSMENT: EXCELLENT - Atlas registration is anatomically accurate"
        elif [ "$passed_validations" -ge $((total_validations * 2 / 3)) ]; then
            echo "OVERALL ASSESSMENT: GOOD - Most regions correctly registered"
        else
            echo "OVERALL ASSESSMENT: POOR - Significant registration errors detected"
        fi
        
    } > "${validation_output_dir}/overall_validation_report.txt"
    
    log_message "Atlas-in-subject-space for $atlas_in_subject" - report: ${validation_output_dir}/atlas_subject_space_validation_report_{atlas_in_subject}.txt"

    
    return $([ "$passed_validations" -ge $((total_validations * 2 / 3)) ] && echo 0 || echo 1)
}

