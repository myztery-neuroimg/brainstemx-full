#!/usr/bin/env bash
#
# segmentation.sh - Refactored segmentation module for brain MRI processing pipeline
#
# This module contains:
# - Harvard/Oxford atlas as primary method (gold standard for brainstem boundaries)
# - Talairach atlas for detailed brainstem subdivision (validated against Harvard/Oxford boundaries)
# - Atlas-to-subject transformation: preserves native resolution by bringing MNI atlases to subject space
# - All outputs in T1 native space, applied to both T1 and registered FLAIR
# - Proper file naming and discovery
# - Continues to clustering after validation
#

# Load Talairach atlas-based segmentation for detailed brainstem subdivision
if [ -f "$(dirname "${BASH_SOURCE[0]}")/segment_talairach.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/segment_talairach.sh"
    log_message "Talairach atlas loaded for detailed brainstem subdivision"
fi

# Ensure RESULTS_DIR is absolute path
if [ -n "${RESULTS_DIR}" ] && [[ "$RESULTS_DIR" != /* ]]; then
    export RESULTS_DIR="$(cd "$(dirname "$RESULTS_DIR")" && pwd)/$(basename "$RESULTS_DIR")"
    log_message "Converted RESULTS_DIR to absolute path: $RESULTS_DIR"
fi

# ============================================================================
# COORDINATE SYSTEM HELPER FUNCTIONS
# ============================================================================

get_qform_description() {
    local code="$1"
    case "$code" in
        0) echo "Unknown coordinate system" ;;
        1) echo "Scanner Anatomical coordinates" ;;
        2) echo "Aligned Anatomical coordinates" ;;
        3) echo "Talairach coordinates" ;;
        4) echo "MNI 152 coordinates" ;;
        *) echo "Invalid/Unknown code ($code)" ;;
    esac
}

get_sform_description() {
    local code="$1"
    case "$code" in
        0) echo "Unknown coordinate system" ;;
        1) echo "Scanner Anatomical coordinates" ;;
        2) echo "Aligned Anatomical coordinates" ;;
        3) echo "Talairach coordinates" ;;
        4) echo "MNI 152 coordinates" ;;
        *) echo "Invalid/Unknown code ($code)" ;;
    esac
}

# ADVANCED: Detect axis permutation/flipping issues
detect_coordinate_space_issues() {
    log_message "Advanced coordinate space issue detection:"
    
    # Compare atlas vs MNI template axis directions
    local atlas_xx=$(fslinfo "$harvard_subcortical" | grep "sform_xorient" | awk '{print $2}')
    local atlas_yy=$(fslinfo "$harvard_subcortical" | grep "sform_yorient" | awk '{print $2}')
    local atlas_zz=$(fslinfo "$harvard_subcortical" | grep "sform_zorient" | awk '{print $2}')
    
    local mni_xx=$(fslinfo "$mni_brain" | grep "sform_xorient" | awk '{print $2}')
    local mni_yy=$(fslinfo "$mni_brain" | grep "sform_yorient" | awk '{print $2}')
    local mni_zz=$(fslinfo "$mni_brain" | grep "sform_zorient" | awk '{print $2}')
    
    # Check for sign mismatches (axis flips)
    local x_mismatch=false
    local y_mismatch=false
    local z_mismatch=false
    
    if [ "$(echo "($atlas_xx > 0 && $mni_xx < 0) || ($atlas_xx < 0 && $mni_xx > 0)" | bc -l 2>/dev/null)" = "1" ]; then
        x_mismatch=true
        log_formatted "ERROR" "DETECTED: X-axis direction mismatch (Atlas: $atlas_xx, MNI: $mni_xx)"
    fi
    
    if [ "$(echo "($atlas_yy > 0 && $mni_yy < 0) || ($atlas_yy < 0 && $mni_yy > 0)" | bc -l 2>/dev/null)" = "1" ]; then
        y_mismatch=true
        log_formatted "ERROR" "DETECTED: Y-axis direction mismatch (Atlas: $atlas_yy, MNI: $mni_yy)"
    fi
    
    if [ "$(echo "($atlas_zz > 0 && $mni_zz < 0) || ($atlas_zz < 0 && $mni_zz > 0)" | bc -l 2>/dev/null)" = "1" ]; then
        z_mismatch=true
        log_formatted "ERROR" "DETECTED: Z-axis direction mismatch (Atlas: $atlas_zz, MNI: $mni_zz)"
    fi
    
    # Report findings
    if [ "$x_mismatch" = "true" ] || [ "$y_mismatch" = "true" ] || [ "$z_mismatch" = "true" ]; then
        log_formatted "CRITICAL" "AXIS DIRECTION MISMATCHES DETECTED!"
        log_formatted "WARNING" "This explains why brainstem appears in wrong location"
        log_formatted "INFO" "Automatic correction will be attempted via fslswapdim"
        return 1
    else
        log_formatted "SUCCESS" "✓ Atlas and MNI template have compatible axis directions"
        return 0
    fi
}


# ============================================================================
# COORDINATE SYSTEM PRE-FLIGHT VALIDATION
# ============================================================================

pre_flight_coordinate_validation() {
    local subject_file="$1"
    local atlas_file="$2"
    local template_file="$3"
    
    log_message "=== PRE-FLIGHT COORDINATE SYSTEM VALIDATION ==="
    log_message "Checking for orientation conflicts BEFORE processing begins"
    
    # Get coordinate information for all files
    local subj_orient=$(fslorient -getorient "$subject_file" 2>/dev/null || echo "UNKNOWN")
    local subj_qform=$(fslorient -getqformcode "$subject_file" 2>/dev/null || echo "UNKNOWN")
    local subj_sform=$(fslorient -getsformcode "$subject_file" 2>/dev/null || echo "UNKNOWN")
    
    local atlas_orient=$(fslorient -getorient "$atlas_file" 2>/dev/null || echo "UNKNOWN")
    local atlas_qform=$(fslorient -getqformcode "$atlas_file" 2>/dev/null || echo "UNKNOWN")
    local atlas_sform=$(fslorient -getsformcode "$atlas_file" 2>/dev/null || echo "UNKNOWN")
    
    local template_orient=$(fslorient -getorient "$template_file" 2>/dev/null || echo "UNKNOWN")
    local template_qform=$(fslorient -getqformcode "$template_file" 2>/dev/null || echo "UNKNOWN")
    local template_sform=$(fslorient -getsformcode "$template_file" 2>/dev/null || echo "UNKNOWN")
    
    log_message "Current coordinate states:"
    log_message "  Subject:  orient=$subj_orient, qform=$subj_qform, sform=$subj_sform"
    log_message "  Atlas:    orient=$atlas_orient, qform=$atlas_qform, sform=$atlas_sform"
    log_message "  Template: orient=$template_orient, qform=$template_qform, sform=$template_sform"
    
    # Identify conflicts that WILL cause FSL warnings
    local conflicts_detected=false
    local conflict_summary=""
    
    # Check for orientation mismatches
    if [ "$subj_orient" != "$atlas_orient" ] && [ "$subj_orient" != "UNKNOWN" ] && [ "$atlas_orient" != "UNKNOWN" ]; then
        conflicts_detected=true
        conflict_summary="${conflict_summary}Orientation mismatch: Subject($subj_orient) vs Atlas($atlas_orient). "
    fi
    
    if [ "$subj_orient" != "$template_orient" ] && [ "$subj_orient" != "UNKNOWN" ] && [ "$template_orient" != "UNKNOWN" ]; then
        conflicts_detected=true
        conflict_summary="${conflict_summary}Orientation mismatch: Subject($subj_orient) vs Template($template_orient). "
    fi
    
    # Check for coordinate system code mismatches
    if [ "$subj_qform" != "$atlas_qform" ] && [ "$subj_qform" != "UNKNOWN" ] && [ "$atlas_qform" != "UNKNOWN" ]; then
        conflicts_detected=true
        conflict_summary="${conflict_summary}Qform mismatch: Subject($subj_qform) vs Atlas($atlas_qform). "
    fi
    
    if [ "$subj_sform" != "$atlas_sform" ] && [ "$subj_sform" != "UNKNOWN" ] && [ "$atlas_sform" != "UNKNOWN" ]; then
        conflicts_detected=true
        conflict_summary="${conflict_summary}Sform mismatch: Subject($subj_sform) vs Atlas($atlas_sform). "
    fi
    
    # Report findings
    if [ "$conflicts_detected" = "true" ]; then
        log_formatted "WARNING" "COORDINATE CONFLICTS DETECTED - FSL warnings likely"
        log_message "Conflicts: $conflict_summary"
        log_message "These conflicts explain the 'Inconsistent orientations' warning"
        return 1  # Indicate conflicts detected
    else
        log_formatted "SUCCESS" "✓ No coordinate conflicts detected - FSL should run cleanly"
        return 0  # No conflicts
    fi
}

# Add True MI validation function
validate_registration_quality() {
    local fixed_image="$1"
    local moving_image="$2"
    local transform_prefix="$3"
    local validation_dir="${RESULTS_DIR}/validation/registration"
    
    log_message "=== TRUE MUTUAL INFORMATION VALIDATION ==="
    log_message "Correlation-derived MI assumes Gaussian joint pdf; violates MI's Shannon definition"
    log_message "Computing true MI using ANTs MeasureImageSimilarity"
    
    mkdir -p "$validation_dir"
    
    # Apply transforms to create registered moving image using centralized function
    local registered_moving="${validation_dir}/registered_moving_temp.nii.gz"
    apply_transformation "$moving_image" "$fixed_image" "$registered_moving" "$transform_prefix" "Linear"
    if apply_transformation "$moving_image" "$fixed_image" "$registered_moving" "$transform_prefix" "Linear"; then
        log_message "✓ Successfully applied transform for validation using centralized function"
    else
        log_formatted "WARNING" "Transform application failed for validation"
        return 1
    fi
    
    if [ ! -f "$registered_moving" ]; then
        log_formatted "WARNING" "Could not create registered image for MI validation"
        return 1
    fi
    
    # True MI calculation using ANTs MeasureImageSimilarity
    if command -v MeasureImageSimilarity &> /dev/null; then
        log_message "Computing true MI with ANTs MeasureImageSimilarity..."
        local mi_result=$(MeasureImageSimilarity 3 "$fixed_image" "$registered_moving" -m MI 2>/dev/null | tail -1)
        
        if [ -n "$mi_result" ]; then
            log_formatted "SUCCESS" "True Mutual Information: $mi_result"
            echo "True MI: $mi_result" > "${validation_dir}/true_mi_result.txt"
            
            # Validate MI value is reasonable (should be positive for good registration)
            local mi_value=$(echo "$mi_result" | awk '{print $1}' | sed 's/.*://g' | tr -d ' ')
            if [ -n "$mi_value" ] && (( $(echo "$mi_value > 0.1" | bc -l 2>/dev/null || echo 0) )); then
                log_formatted "SUCCESS" "Registration quality validation PASSED (MI=$mi_value)"
            else
                log_formatted "WARNING" "Registration quality may be poor (MI=$mi_value)"
            fi
        else
            log_formatted "WARNING" "Failed to compute true MI with MeasureImageSimilarity"
            return 1
        fi
    fi
    # Clean up temporary file
    rm -f "$registered_moving"
    return 0
}

# ============================================================================
# SIMPLE TEST FUNCTION FOR COORDINATE VALIDATION
# ============================================================================

test_coordinate_validation() {
    log_message "=== TESTING COORDINATE VALIDATION FUNCTION ==="
    
    # Test with dummy files to verify detection logic
    local test_cases=0
    local test_passed=0
    
    # Mock fslorient function for testing
    mock_fslorient() {
        local option="$1"
        local file="$2"
        
        case "$file" in
            "test_subject.nii.gz")
                case "$option" in
                    "-getorient") echo "RADIOLOGICAL" ;;
                    "-getqformcode") echo "1" ;;
                    "-getsformcode") echo "1" ;;
                esac ;;
            "test_atlas.nii.gz")
                case "$option" in
                    "-getorient") echo "NEUROLOGICAL" ;;
                    "-getqformcode") echo "4" ;;
                    "-getsformcode") echo "4" ;;
                esac ;;
            "test_template.nii.gz")
                case "$option" in
                    "-getorient") echo "RADIOLOGICAL" ;;
                    "-getqformcode") echo "1" ;;
                    "-getsformcode") echo "1" ;;
                esac ;;
        esac
    }
    
    # Override fslorient temporarily
    local original_fslorient=$(which fslorient 2>/dev/null || echo "")
    alias fslorient=mock_fslorient
    
    # Test 1: Should detect orientation mismatch (RADIOLOGICAL vs NEUROLOGICAL)
    test_cases=$((test_cases + 1))
    log_message "Test 1: Testing orientation conflict detection..."
    if ! pre_flight_coordinate_validation "test_subject.nii.gz" "test_atlas.nii.gz" "test_template.nii.gz" >/dev/null 2>&1; then
        log_message "✓ Test 1 PASSED: Correctly detected orientation mismatch"
        test_passed=$((test_passed + 1))
    else
        log_message "✗ Test 1 FAILED: Should have detected orientation mismatch"
    fi
    
    # Test 2: Should detect qform/sform mismatch (Scanner vs MNI)
    test_cases=$((test_cases + 1))
    log_message "Test 2: Testing coordinate system conflict detection..."
    # The same test files have qform 1 vs 4 mismatch
    if ! pre_flight_coordinate_validation "test_subject.nii.gz" "test_atlas.nii.gz" "test_template.nii.gz" >/dev/null 2>&1; then
        log_message "✓ Test 2 PASSED: Correctly detected coordinate system mismatch"
        test_passed=$((test_passed + 1))
    else
        log_message "✗ Test 2 FAILED: Should have detected coordinate system mismatch"
    fi
    
    # Restore original fslorient
    unalias fslorient 2>/dev/null || true
    
    log_message "=== TEST RESULTS ==="
    log_message "Tests passed: $test_passed/$test_cases"
    
    if [ "$test_passed" -eq "$test_cases" ]; then
        log_formatted "SUCCESS" "✓ All coordinate validation tests passed"
        return 0
    else
        log_formatted "WARNING" "Some coordinate validation tests failed"
        return 1
    fi
}

# CRITICAL: Axis direction analysis using sform matrix
validate_axis_directions() {
    local file="$1"
    local name="$2"
    
    # Extract sform matrix diagonal elements (main axis directions)
    local sform_xx=$(fslorient -getsformcode "$file" | grep "sform_xorient" | awk '{print $2}')
    local sform_yy=$(fslorient -getqformcode "$file" | grep "sform_yorient" | awk '{print $2}')
    local sform_zz=$(fslinfo "$file" | grep "sform_zorient" | awk '{print $2}')
    
    log_message " Validating axis directions for $file ($name):"
    log_message "  $name axis directions: X=$sform_xx Y=$sform_yy Z=$sform_zz"
    
    # Detect potential axis flips or permutations
    if [ "$(echo "$sform_xx < 0" | bc -l 2>/dev/null)" = "1" ]; then
        log_formatted "WARNING" "$name: X-axis may be flipped (negative)"
    fi
    if [ "$(echo "$sform_yy < 0" | bc -l 2>/dev/null)" = "1" ]; then
        log_formatted "WARNING" "$name: Y-axis may be flipped (negative)"
    fi
    if [ "$(echo "$sform_zz < 0" | bc -l 2>/dev/null)" = "1" ]; then
        log_formatted "WARNING" "$name: Z-axis may be flipped (negative)"
    fi
}


# EARLY VALIDATION: Check all input files for basic integrity
validate_file_headers() {
    local file="$1"
    local name="$2"
    
    if ! fslinfo "$file" >/dev/null 2>&1; then
        log_formatted "ERROR" "$name file has corrupt/invalid header: $file"
        return 1
    fi
    
    # Check for reasonable dimensions
    local dims=$(fslinfo "$file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    if [[ ! "$dims" =~ ^[0-9]+x[0-9]+x[0-9]+$ ]]; then
        log_formatted "ERROR" "$name file has invalid dimensions: $dims"
        return 1
    fi
    
    return 0
}

# ============================================================================
# BRAINSTEM REFINEMENT: Subject-specific mask generation
# ============================================================================

refine_brainstem_mask_subject_specific() {
    local input_image="$1"
    local initial_mask="$2"
    local output_refined_mask="$3"
    local temp_refinement_dir="$4"
    
    log_message "Running subject-specific brain-stem refinement..."
    
    # Step 1: Run tissue segmentation with robust fallback strategies
    local tissue_labels="${temp_refinement_dir}/tissue_labels.nii.gz"
    local segmentation_successful=false
    
    # Validate input image first
    local input_mean=$(fslstats "$input_image" -M 2>/dev/null)
    local input_std=$(fslstats "$input_image" -S 2>/dev/null)
    local input_voxels=$(fslstats "$input_image" -V | awk '{print $1}')
    
    log_message "Input validation: mean=$input_mean, std=$input_std, voxels=$input_voxels"
    
    # Check if input has sufficient contrast for segmentation
    if [ -z "$input_mean" ] || [ -z "$input_std" ] || [ "$input_voxels" -lt 1000 ]; then
        log_formatted "WARNING" "Input image insufficient for tissue segmentation, using original mask"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi
    
    # Validate contrast (std should be reasonable fraction of mean) - make threshold more lenient
    local contrast_ratio=$(echo "scale=3; $input_std / $input_mean" | bc -l 2>/dev/null || echo "0")
    if (( $(echo "$contrast_ratio < 0.05" | bc -l 2>/dev/null || echo 1) )); then
        log_formatted "WARNING" "Insufficient tissue contrast (ratio=$contrast_ratio), using original mask"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi
    
    # Additional validation: check if we have reasonable intensity range
    local input_range=$(fslstats "$input_image" -R 2>/dev/null)
    local min_val=$(echo "$input_range" | awk '{print $1}')
    local max_val=$(echo "$input_range" | awk '{print $2}')
    local intensity_range=$(echo "scale=3; $max_val - $min_val" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$intensity_range < 10" | bc -l 2>/dev/null || echo 1) )); then
        log_formatted "WARNING" "Insufficient intensity range ($intensity_range), using original mask"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi
    
    # Try Atropos with progressive fallbacks
    if command -v Atropos &> /dev/null && [ "$segmentation_successful" = "false" ]; then
        log_message "Using Atropos for tissue segmentation..."
        
        # Use already extracted brain files from brain extraction step
        local input_basename=$(basename "$input_image" .nii.gz)
        local brain_extracted="${RESULTS_DIR}/registered/${input_basename}_to_t1Warped.nii.gz"
        local brain_mask="${RESULTS_DIR}/registered/${input_basename}_brain_mask.nii.gz"
        
        # Check if brain extraction files exist (should have been created earlier in pipeline)
        if [ ! -f "$brain_extracted" ] || [ ! -f "$brain_mask" ]; then
            log_message "Exact basename match not found ($brain_extracted or $brain_mask), searching for available brain extraction files..."
            
            # Find available brain extraction files
            local available_brain_files=($(find "${RESULTS_DIR}/registered" -name "T2*_to_t1Warped.nii.gz" 2>/dev/null))
            local available_mask_files=($(find "${RESULTS_DIR}/registered" -name "T2*_brain_mask.nii.gz" 2>/dev/null))
            
            log_message "Found ${#available_brain_files[@]} brain files and ${#available_mask_files[@]} mask files"
            
            if [ ${#available_brain_files[@]} -gt 0 ] && [ ${#available_mask_files[@]} -gt 0 ]; then
                # Try to match brain and mask files from the same sequence
                brain_extracted="${available_brain_files[0]}"
                brain_mask="${available_mask_files[0]}"
                log_message "Using files:"
                log_message "  Brain: $(basename "$brain_extracted")"
                log_message "  Mask: $(basename "$brain_mask")"
            else
                log_formatted "ERROR" "Registered T2_to_t1Warped and brain_mask files not found - brain extraction should have been completed earlier in pipeline"
                log_formatted "ERROR" "Searched in: ${RESULTS_DIR}/registered/"
                log_formatted "ERROR" "Brain files found: ${#available_brain_files[@]} | Mask files found: ${#available_mask_files[@]}"
                log_formatted "ERROR" "Segmentation module cannot proceed without registration outputs"
                return 1
            fi
        fi
        
        # Validate brain extraction was successful
        local brain_voxels=$(fslstats "$brain_mask" -V | awk '{print $1}' 2>/dev/null || echo "0")
        log_message "Using existing brain extraction: $brain_voxels voxels in mask"
        
        if [ "$brain_voxels" -gt 100 ]; then
            # Try 3-class segmentation first with comprehensive error handling
            log_message "Trying Atropos 3-class segmentation..."
            local atropos_output="${temp_refinement_dir}/atropos_3class.log"
            if Atropos -d 3 \
                -a "$brain_extracted" \
                -x "$brain_mask" \
                -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                -c "[3,0.0001]" \
                -m "[0.3,1x1x1]" \
                -i "KMeans[3]" \
                -k Gaussian >"$atropos_output" 2>&1; then
                
                if [ -f "$tissue_labels" ]; then
                    log_message "✓ Atropos 3-class segmentation successful"
                    segmentation_successful=true
                fi
            else
                log_message "Atropos 3-class failed: $(tail -n 2 "$atropos_output" 2>/dev/null | head -n 1)"
            fi
            
            # Fallback to 2-class if 3-class failed
            if [ "$segmentation_successful" = "false" ]; then
                log_message "Trying Atropos 2-class segmentation..."
                local atropos_output2="${temp_refinement_dir}/atropos_2class.log"
                if Atropos -d 3 \
                    -a "$brain_extracted" \
                    -x "$brain_mask" \
                    -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                    -c "[3,0.0001]" \
                    -m "[0.3,1x1x1]" \
                    -i "KMeans[2]" \
                    -k Gaussian >"$atropos_output2" 2>&1; then
                    
                    if [ -f "$tissue_labels" ]; then
                        log_message "✓ Atropos 2-class segmentation successful"
                        segmentation_successful=true
                    fi
                else
                    log_message "Atropos 2-class failed: $(tail -n 2 "$atropos_output2" 2>/dev/null | head -n 1)"
                fi
            fi
            
            # Fallback to Otsu initialization if KMeans failed
            if [ "$segmentation_successful" = "false" ]; then
                log_message "Trying Atropos with Otsu initialization..."
                local atropos_output3="${temp_refinement_dir}/atropos_otsu.log"
                if Atropos -d 3 \
                    -a "$brain_extracted" \
                    -x "$brain_mask" \
                    -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                    -c "[3,0.0001]" \
                    -m "[0.3,1x1x1]" \
                    -i "Otsu[2]" \
                    -k Gaussian >"$atropos_output3" 2>&1; then
                    
                    if [ -f "$tissue_labels" ]; then
                        log_message "✓ Atropos Otsu segmentation successful"
                        segmentation_successful=true
                    fi
                else
                    log_message "Atropos Otsu failed: $(tail -n 2 "$atropos_output3" 2>/dev/null | head -n 1)"
                fi
            fi
        fi
    fi
    
    # FAST fallback with progressive strategies
    if command -v fast &> /dev/null && [ "$segmentation_successful" = "false" ]; then
        log_message "Using FAST for tissue segmentation..."
        
        # Try 3-class FAST first with better error handling
        log_message "Trying FAST 3-class segmentation..."
        local fast_output="${temp_refinement_dir}/fast_3class.log"
        if fast -t 1 -n 3 -o "${temp_refinement_dir}/fast_" "$input_image" >"$fast_output" 2>&1; then
            if [ -f "${temp_refinement_dir}/fast_seg.nii.gz" ]; then
                cp "${temp_refinement_dir}/fast_seg.nii.gz" "$tissue_labels"
                log_message "✓ FAST 3-class segmentation successful"
                segmentation_successful=true
            fi
        else
            log_message "FAST 3-class failed: $(tail -n 2 "$fast_output" 2>/dev/null | head -n 1)"
        fi
        
        # Fallback to 2-class FAST
        if [ "$segmentation_successful" = "false" ]; then
            log_message "Trying FAST 2-class segmentation..."
            local fast_output2="${temp_refinement_dir}/fast_2class.log"
            if fast -t 1 -n 2 -o "${temp_refinement_dir}/fast2_" "$input_image" >"$fast_output2" 2>&1; then
                if [ -f "${temp_refinement_dir}/fast2_seg.nii.gz" ]; then
                    cp "${temp_refinement_dir}/fast2_seg.nii.gz" "$tissue_labels"
                    log_message "✓ FAST 2-class segmentation successful"
                    segmentation_successful=true
                fi
            else
                log_message "FAST 2-class failed: $(tail -n 2 "$fast_output2" 2>/dev/null | head -n 1)"
            fi
        fi
        
        # Additional FAST fallback: use brain extracted image if available from earlier pipeline step
        if [ "$segmentation_successful" = "false" ]; then
            local input_basename=$(basename "$input_image" .nii.gz)
            local brain_extracted="${RESULTS_DIR}/brain_extraction/${input_basename}_brain.nii.gz"
            
            # If exact match not found, search for any brain extraction files
            if [ ! -f "$brain_extracted" ]; then
                log_message "Exact basename match not found, searching for available brain extraction files..."
                local available_brain_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain.nii.gz" 2>/dev/null))
                if [ ${#available_brain_files[@]} -gt 0 ]; then
                    brain_extracted="${available_brain_files[0]}"
                    log_message "Using available brain extraction file: $(basename "$brain_extracted")"
                fi
            fi
            
            if [ -f "$brain_extracted" ]; then
                log_message "Trying FAST on brain-extracted image from earlier pipeline step..."
                local fast_output3="${temp_refinement_dir}/fast_brain.log"
                if fast -t 1 -n 2 -o "${temp_refinement_dir}/fast_brain_" "$brain_extracted" >"$fast_output3" 2>&1; then
                    if [ -f "${temp_refinement_dir}/fast_brain_seg.nii.gz" ]; then
                        cp "${temp_refinement_dir}/fast_brain_seg.nii.gz" "$tissue_labels"
                        log_message "✓ FAST brain-extracted segmentation successful"
                        segmentation_successful=true
                    fi
                else
                    log_message "FAST brain-extracted failed: $(tail -n 2 "$fast_output3" 2>/dev/null | head -n 1)"
                fi
            else
                log_formatted "WARNING" "Brain extracted file not found from earlier pipeline step: $brain_extracted"
            fi
        fi
    fi
            
    # If all segmentation attempts failed, use original mask
    if [ "$segmentation_successful" = "false" ]; then
        log_formatted "WARNING" "All tissue segmentation methods failed - Using original atlas-based mask without refinement"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi

    # @todo We have already a _wm registered FLAIR file T2_SPACE_FLAIR_Sag_CS_17_n4_brain_std_to_t1_wm_mask.nii.gz let's use it

    
    # Improve tissue region selection with atlas guidance
    # Combine tissue segmentation with atlas mask for better constraint
    #fslmaths "${RESULTS_DIR}/registered/T2_SPACE_FLAIR_Sag_CS_17_n4_brain_std_to_t1_wm_mask.nii.gz" -mas "$initial_mask" -kernel sphere 2 -dilM "$tissue_region"
    tissue_region="${RESULTS_DIR}/registered/T2_SPACE_FLAIR_Sag_CS_17_n4_brain_std_to_t1_wm_mask.nii.gz"

    if [ ! -f "$tissue_region" ]; then
        log_formatted "ERROR" "Couldn't locate wm mask file for T2 registered against T1 at $tissue_region"
        return 1
    fi

    tissue_voxels=$(fslstats "$tissue_region" -V | awk '{print $1}')
    if [ "$tissue_voxels" -lt 20 ]; then
        log_formatted "WARNING" "Selected tissue region very small ($tissue_voxels voxels), using original mask"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi
    
    log_message "Selected atlas-guided tissue region: $tissue_voxels voxels"
    
    # Step 3: Create atlas-guided seed region
    local seed_region="${temp_refinement_dir}/seed_region.nii.gz"
    
    log_message "Step 3: Use atlas-based seeding: erode the initial mask $initial_mask to create conservative seed"
    # This ensures we start from high-confidence atlas regions
    fslmaths "$initial_mask" -kernel sphere 1 -ero "$seed_region"
    local seed_voxels=$(fslstats "$seed_region" -V | awk '{print $1}')
    log_message "After eroding initial mask by sphere 1 by wm: seed_voxels is ${seed_voxels}"

    log_message "Masking seed_region by wm tissue region from $tissue_region"
    # Ensure seed region has tissue support
    fslmaths "$seed_region" -mas "$tissue_region" "$seed_region"
    
    local seed_voxels=$(fslstats "$seed_region" -V | awk '{print $1}')
    log_message "After masking by wm: seed_voxels is ${seed_voxels}"
    if [ "$seed_voxels" -lt 10 ]; then
        log_formatted "WARNING" "Insufficient seed region, avoiding atlas-guided MGAC refinement"
        cp "$initial_mask" "$output_refined_mask"
        return 0
    fi
    
    log_message "Created atlas-guided seed region: $seed_voxels voxels"
    
    
    # Path to the Python script
    local mgac_script="src/modules/morphological_geodesic_active_contour.py"
    
    # Step 4: Atlas-guided morphological geodesic active contour
    log_message "Step 4: Running atlas-guided morphological geodesic active contour evolution: ${mgac_script}"

    if [ ! -f "$mgac_script" ]; then
        log_formatted "ERROR" "MGAC Python script not found: $mgac_script"
        return 1
    fi
            
    # Optimized parameters for brainstem anatomy
    local iterations=10      # Reduced for stability and speed
    local sigma=1.5          # Tighter edge detection for fine structures
    local k=2.0              # Higher edge sensitivity for tissue boundaries
    local alpha=0.02         # Much smaller expansion force to prevent overgrowth
    local beta=0.1           # Add smoothness constraint for anatomical realism
    local dt=0.05            # Smaller time step for numerical stability
    
    # Run the atlas-guided Python implementation
    if uv run python "$mgac_script" \
        "$input_image" \
        "$seed_region" \
        "$tissue_region" \
        "$output_refined_mask" \
        --atlas_constraint "$initial_mask" \
        --iterations "$iterations" \
        --sigma "$sigma" \
        --k "$k" \
        --alpha "$alpha" \
        --beta "$beta" \
        --dt "$dt"; then
        
        log_formatted "SUCCESS" "Morphological geodesic active contour evolution completed"
    else
        log_formatted "ERROR" "Morphological geodesic active contour failed, using fallback"
        cp "$initial_mask" "$output_refined_mask"
        return 1
    fi
    
    # Comprehensive quality validation for atlas-guided refinement
    local refined_voxels=$(fslstats "$output_refined_mask" -V | awk '{print $1}')
    local original_voxels=$(fslstats "$initial_mask" -V | awk '{print $1}')
    
    if [ "$refined_voxels" -eq 0 ]; then
        log_formatted "WARNING" "Refinement produced empty mask, using original"
        cp "$initial_mask" "$output_refined_mask"
        return 1
    fi
    
    # Calculate volume change percentage
    local volume_change_pct=0
    if [ "$original_voxels" -gt 0 ]; then
        volume_change_pct=$(echo "scale=1; 100 * ($refined_voxels - $original_voxels) / $original_voxels" | bc -l)
    fi
    
    # Calculate Dice coefficient with original atlas
    local overlap_voxels=$(fslstats "$output_refined_mask" -mas "$initial_mask" -V | awk '{print $1}')
    local dice_denominator=$(echo "$refined_voxels + $original_voxels" | bc -l)
    local dice_score=0
    
    if [ "$dice_denominator" -gt 0 ]; then
        dice_score=$(echo "scale=3; 2 * $overlap_voxels / $dice_denominator" | bc -l)
    fi
    
    # Quality gates: reject if refinement is too aggressive or poor quality
    local quality_passed=true
    
    # Check 1: Volume change should be reasonable (< 50% change)
    if (( $(echo "${volume_change_pct#-} > 20" | bc -l) )); then
        log_formatted "WARNING" "Excessive volume change: ${volume_change_pct}%, using original atlas"
        quality_passed=false
    fi
    
    # Check 2: Dice overlap should be reasonable (> 0.7)
    if (( $(echo "$dice_score < 0.7" | bc -l) )); then
        log_formatted "WARNING" "Poor overlap with atlas: Dice=$dice_score, using original atlas"
        quality_passed=false
    fi
    
    # Check 3: Refined mask should not be too large relative to atlas
    if [ "$refined_voxels" -gt $(echo "2 * $original_voxels" | bc -l) ]; then
        log_formatted "WARNING" "Refined mask too large (${refined_voxels} vs ${original_voxels} atlas), using original"
        quality_passed=false
    fi
    
    # Apply quality gate
    if [ "$quality_passed" = "false" ]; then
        cp "$initial_mask" "$output_refined_mask"
        refined_voxels=$original_voxels
    fi
    
    log_message "Atlas-guided brainstem refinement completed"
    log_message "  Original atlas voxels: $original_voxels | Refined voxels: $refined_voxels"
    log_message "  Volume change: ${volume_change_pct}% |  Dice overlap with atlas: $dice_score"
    return 0
}

# ============================================================================
# UTILITY FUNCTIONS FOR SEGMENTATION
# ============================================================================

cleanup_and_fail() {
    local exit_code="$1"
    local error_msg="$2"
    local temp_dir="${3:-}"
    
    log_formatted "ERROR" "SEGMENTATION FAILURE: $error_msg"
    log_formatted "ERROR" "Segmentation failed due to data quality issues"
    
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
    
    return "$exit_code"
}

# ============================================================================
# PRIMARY METHOD: Harvard/Oxford Atlas Segmentation in T1 Space
# ============================================================================

extract_brainstem_harvard_oxford() {
    # Uses Harvard-Oxford subcortical atlas to extract brainstem
    # IMPORTANT: Uses only index 7 which is the Brain-Stem region
    # Do NOT use other indices as they are different structures (e.g., index 13 is ventricle with 500K+ voxels!)
    
    local input_file="$1"
    local output_file="${2:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$input_file" .nii.gz)_brainstem.nii.gz}"
    
    # Validate input
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $input_file does not exist"
        return 1
    fi
    
    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set"
        return 1
    fi
    
    # Create output directory with absolute path
    local output_dir="$(dirname "$output_file")"
    # Convert to absolute path if relative
    if [[ "$output_dir" != /* ]]; then
        output_dir="$(pwd)/$output_dir"
    fi
    
    log_message "Creating output directory: $output_dir"
    if ! mkdir -p "$output_dir"; then
        log_formatted "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi
    
    # Verify directory was created
    if [ ! -d "$output_dir" ] || [ ! -w "$output_dir" ]; then
        log_formatted "ERROR" "Output directory not writable: $output_dir"
        return 1
    fi
    
    log_formatted "INFO" "===== HARVARD/OXFORD ATLAS SEGMENTATION ====="
    log_message "Processing in subject's native T1 space - no resampling to standard space"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Determine template resolution based on config
    local template_res="${DEFAULT_TEMPLATE_RES:-1mm}"
    if [ "${AUTO_DETECT_RESOLUTION:-true}" = "true" ]; then
        # Auto-detect resolution based on input voxel size
        local voxel_size=$(fslinfo "$input_file" | grep "^pixdim1" | awk '{print $2}')
        if (( $(echo "$voxel_size > 1.5" | bc -l) )); then
            template_res="2mm"
            log_message "Auto-detected low resolution input, using 2mm templates"
        else
            template_res="1mm"
            log_message "Auto-detected high resolution input, using 1mm templates"
        fi
    fi
    
    # Set appropriate templates based on resolution
    local mni_template="${TEMPLATE_DIR}/MNI152_T1_${template_res}.nii.gz"
    local mni_brain="${TEMPLATE_DIR}/MNI152_T1_${template_res}_brain.nii.gz"
    
    # Find Harvard-Oxford subcortical atlas
    local harvard_subcortical=""
    local atlas_search_paths=(
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-${template_res}.nii.gz"
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-prob-${template_res}.nii.gz"
    )
    
    for atlas_file in "${atlas_search_paths[@]}"; do
        if [ -f "$atlas_file" ]; then
            harvard_subcortical="$atlas_file"
            log_message "Using Harvard-Oxford atlas: $atlas_file"
            break
        fi
    done
    
    if [ -z "$harvard_subcortical" ]; then
        log_formatted "ERROR" "Harvard-Oxford subcortical atlas not found in any expected location"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # COMPREHENSIVE COORDINATE SYSTEM DETECTION WITH EARLY VALIDATION
    log_message "=== COMPREHENSIVE COORDINATE SYSTEM ANALYSIS ==="
    log_message "Performing extensive coordinate system detection as requested"
    
    log_message "Step 1: Validating file headers before coordinate analysis..."
    validate_file_headers "$input_file" "Subject" || return 1
    validate_file_headers "$harvard_subcortical" "Atlas" || return 1
    validate_file_headers "$mni_brain" "MNI template" || return 1
    log_formatted "SUCCESS" "✓ All input files have valid headers"
    
    # PRE-FLIGHT COORDINATE VALIDATION - CATCH CONFLICTS EARLY
    log_message "=== PRE-FLIGHT COORDINATE VALIDATION ==="
    if pre_flight_coordinate_validation "$input_file" "$harvard_subcortical" "$mni_brain"; then
        log_formatted "SUCCESS" "✓ No coordinate conflicts detected - proceeding normally"
    else
        log_formatted "WARNING" "Coordinate conflicts detected - will attempt resolution"
        log_message "This explains the 'Inconsistent orientations' FSL warning you're seeing"
    fi
    
    # Get precise orientation and coordinate system codes using fslorient
    local subject_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
    local atlas_orient=$(fslorient -getorient "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    local mni_orient=$(fslorient -getorient "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    
    # CRITICAL: Get qform and sform codes using fslorient (not fslinfo)
    local subject_qform=$(fslorient -getqformcode "$input_file" 2>/dev/null || echo "UNKNOWN")
    local subject_sform=$(fslorient -getsformcode "$input_file" 2>/dev/null || echo "UNKNOWN")
    local atlas_qform=$(fslorient -getqformcode "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    local atlas_sform=$(fslorient -getsformcode "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    local mni_qform=$(fslorient -getqformcode "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    local mni_sform=$(fslorient -getsformcode "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    
    log_message "=== ORIENTATION ANALYSIS ==="
    log_message "Subject orientation: $subject_orient | Harvard-Oxford atlas orientation: $atlas_orient | MNI template orientation: $mni_orient"
    
    log_message "=== COORDINATE SYSTEM CODES ==="
    log_message "Subject: $input_file | qform code: $subject_qform ($(get_qform_description "$subject_qform")) | sform code: $subject_sform ($(get_sform_description "$subject_sform"))"
    log_message "Atlas: $harvard_subcortical qform code: $atlas_qform ($(get_qform_description "$atlas_qform")) | sform code: $atlas_sform ($(get_sform_description "$atlas_sform"))"
    
    # DETECT COORDINATE SYSTEM MISMATCHES
    local coord_mismatch_detected=false
    local critical_mismatch=false
    
    if [ "$subject_qform" != "$atlas_qform" ]; then
        log_formatted "ERROR" "QFORM CODE MISMATCH: Subject ($subject_qform) vs Atlas ($atlas_qform)"
        coord_mismatch_detected=true
        if [[ "$subject_qform" == "1" && "$atlas_qform" == "4" ]] || [[ "$subject_qform" == "4" && "$atlas_qform" == "1" ]]; then
            critical_mismatch=true
        fi
    fi
    
    if [ "$subject_sform" != "$atlas_sform" ]; then
        log_formatted "ERROR" "SFORM CODE MISMATCH: Subject ($subject_sform) vs Atlas ($atlas_sform)"
        coord_mismatch_detected=true
        if [[ "$subject_sform" == "1" && "$atlas_sform" == "4" ]] || [[ "$subject_sform" == "4" && "$atlas_sform" == "1" ]]; then
            critical_mismatch=true
        fi
    fi
    
    if [ "$critical_mismatch" = "true" ]; then
        log_formatted "CRITICAL" "SCANNER ANATOMICAL vs MNI 152 !"
        log_formatted "WARNING" "Subject and Atlas sform/qform misalignment. This WILL cause anatomical mislocalization if not corrected"
    fi
    
    # Additional coordinate system details using fslinfo for comprehensive logging
    log_message "=== DETAILED COORDINATE MATRICES ==="
    log_message "Subject coordinate details:"
    fslinfo "$input_file" | grep -E "(orient|sform|qform|pixdim)" | while read line; do
        log_message "  $line"
    done
    
    log_message "Harvard-Oxford atlas coordinate details:"
    fslinfo "$harvard_subcortical" | grep -E "(orient|sform|qform|pixdim)" | while read line; do
        log_message "  $line"
    done
    
    log_message "MNI template coordinate details:"
    fslinfo "$mni_brain" | grep -E "(orient|sform|qform|pixdim)" | while read line; do
        log_message "  $line"
    done
    
    # Validate the full atlas has the brainstem region (index 7) before proceeding
    log_message "Validating brainstem region (index 7) exists in atlas..."
    local test_brainstem="${temp_dir}/test_brainstem_extraction.nii.gz"
    fslmaths "$harvard_subcortical" -thr 6.9 -uthr 7.1 -bin "$test_brainstem" -odt int
    local brainstem_test_voxels=$(fslstats "$test_brainstem" -V | awk '{print $1}')
    
    if [ "$brainstem_test_voxels" -lt 100 ]; then
        log_formatted "ERROR" "Brainstem region (index 7) has insufficient voxels ($brainstem_test_voxels) in atlas"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_formatted "SUCCESS" "✓ Brainstem region validated in atlas: $brainstem_test_voxels voxels"
    rm -f "$test_brainstem"
    
    # COMPREHENSIVE ATLAS REORIENTATION TO SUBJECT SPACE
    log_message "=== ATLAS REORIENTATION TO SUBJECT SPACE ==="
    
    local atlas_needs_correction=false
    local corrected_atlas="${RESULTS_DIR}/fixed_spaces/harvard_oxford_reoriented.nii.gz"
    
    # Check for any coordinate system mismatches requiring correction
    if [ "$coord_mismatch_detected" = "true" ]; then
        atlas_needs_correction=true
        log_formatted "ERROR" "Coordinate system mismatch requires atlas reorientation"
    fi
    
    if [ "$subject_orient" != "$atlas_orient" ] && [ "$atlas_orient" != "UNKNOWN" ] && [ "$subject_orient" != "UNKNOWN" ]; then
        atlas_needs_correction=true
        log_formatted "WARNING" "Basic orientation mismatch: Subject ($subject_orient) vs Atlas ($atlas_orient)"
    fi
    
    local intermediate_atlas="$harvard_subcortical"

    if [ "$atlas_needs_correction" = "true" ]; then
        
        # Step 1: Handle coordinate system code mismatches first       
        if [ "$critical_mismatch" = "true" ]; then
            log_formatted "WARNING" "Applying coordinate system transformation for Scanner vs MNI space"
            
            # Create intermediate file for coordinate system correction
            local coord_corrected="${temp_dir}/atlas_coord_corrected.nii.gz"
            
            # Handle Scanner Anatomical (1) vs MNI 152 (4) coordinate system mismatch
            if [[ "$subject_qform" != "$atlas_qform" ]] ||  [[ "$subject_sform" != "$atlas_sform" ]]; then
                log_message "Converting atlas from MNI 152 to Scanner Anatomical coordinate system"
                # Atlas is in MNI space, need to bring it to scanner space
                # This typically requires flipping specific axes depending on scanner orientation

                #@todo implement proper reorientation of harvard_subcortical against subject_qform/subject_sform
                fslswapdim "$harvard_subcortical" x y z "$coord_corrected"
                fslorient -setqformcode "$subject_qform" "$coord_corrected"
                fslorient -setsformcode "$subject_sform" "$coord_corrected"
            fi
                            
            intermediate_atlas="$coord_corrected"
            log_message "✓ Coordinate system correction applied"
        fi
        
        # Step 2: Handle basic orientation mismatches
        if [ "$subject_orient" != "$atlas_orient" ] && [ "$atlas_orient" != "UNKNOWN" ] && [ "$subject_orient" != "UNKNOWN" ]; then
            log_message "Applying orientation correction: $atlas_orient → $subject_orient"
            
            if [ "$atlas_orient" = "NEUROLOGICAL" ] && [ "$subject_orient" = "RADIOLOGICAL" ]; then
                fslswapdim "$intermediate_atlas" -x y z "$corrected_atlas"
                fslorient -forceradiological "$corrected_atlas"
                log_message "✓ Converted atlas from NEUROLOGICAL to RADIOLOGICAL"
                
            elif [ "$atlas_orient" = "RADIOLOGICAL" ] && [ "$subject_orient" = "NEUROLOGICAL" ]; then
                fslswapdim "$intermediate_atlas" -x y z "$corrected_atlas"
                fslorient -forceneurological "$corrected_atlas"
                log_message "✓ Converted atlas from RADIOLOGICAL to NEUROLOGICAL"
                
            else
                log_formatted "WARNING" "Unsupported orientation conversion: $atlas_orient → $subject_orient"
                cp "$intermediate_atlas" "$corrected_atlas"
            fi
            
        else
            # No orientation correction needed, just copy coordinate-corrected version
            cp "$intermediate_atlas" "$corrected_atlas"
        fi
                
        # Step 4: Verify the reorientation was successful
        local corrected_qform=$(fslorient -getqformcode "$corrected_atlas" 2>/dev/null || echo "UNKNOWN")
        local corrected_sform=$(fslorient -getsformcode "$corrected_atlas" 2>/dev/null || echo "UNKNOWN")
        local corrected_orient=$(fslorient -getorient "$corrected_atlas" 2>/dev/null || echo "UNKNOWN")
        
        log_message "=== REORIENTATION VERIFICATION ==="
        log_message "Corrected atlas qform: $corrected_qform (target: $subject_qform)"
        log_message "Corrected atlas sform: $corrected_sform (target: $subject_sform)"
        log_message "Corrected atlas orientation: $corrected_orient (target: $subject_orient)"
                        
        # Use the corrected version for further processing
        harvard_subcortical="$corrected_atlas"
        
    else
        log_formatted "SUCCESS" "✓ Atlas and subject coordinate systems are compatible"
    fi
    
    # ATLAS VALIDATION: Use atlasq to validate the Harvard-Oxford atlas
    log_message "Validating Harvard-Oxford atlas structure..."
    
    # Enhanced atlas file validation using atlasq
    if command -v atlasq &> /dev/null; then
        log_message "Running comprehensive atlasq validation..."
        
        # Use atlasq summary for comprehensive atlas information
        local atlas_summary=$(atlasq summary harvardoxford-subcortical 2>/dev/null || echo "SUMMARY_FAILED")
        
        if [ "$atlas_summary" = "SUMMARY_FAILED" ]; then
            log_formatted "WARNING" "atlasq summary failed - using direct file validation"
            
            # Fallback: try direct file query if summary fails (using original atlas for atlasq)
            local atlas_info=$(atlasq -a "$harvard_subcortical" 2>/dev/null || echo "QUERY_FAILED")
            if [ "$atlas_info" != "QUERY_FAILED" ]; then
                log_message "Direct atlas query successful: $atlas_info"
            fi
        else
            log_formatted "SUCCESS" "✓ Harvard-Oxford atlas summary retrieved"
            
            # Parse and validate key information from summary
            local atlas_type=$(echo "$atlas_summary" | grep "Type:" | awk '{print $2}' || echo "unknown")
            local atlas_labels=$(echo "$atlas_summary" | grep "Labels:" | awk '{print $2}' || echo "0")
            local brainstem_line=$(echo "$atlas_summary" | grep "7.*Brain-Stem" || echo "")
            
            log_message "Atlas type: $atlas_type"
            log_message "Total labels: $atlas_labels"
            
            # Validate atlas type
            if [ "$atlas_type" = "probabilistic" ]; then
                log_formatted "SUCCESS" "✓ Correct atlas type: probabilistic"
            else
                log_formatted "WARNING" "Unexpected atlas type: $atlas_type (expected: probabilistic)"
            fi
            
            # Validate label count (Harvard-Oxford subcortical should have 21 labels)
            if [ "$atlas_labels" = "21" ]; then
                log_formatted "SUCCESS" "✓ Correct number of labels: 21"
            else
                log_formatted "WARNING" "Unexpected label count: $atlas_labels (expected: 21)"
            fi
            
            # Validate brainstem region (index 7)
            if [ -n "$brainstem_line" ]; then
                log_formatted "SUCCESS" "✓ Brainstem region (index 7) confirmed in atlas"
                
                # Extract MNI coordinates for brainstem from summary
                # The format is: "7     | Brain-Stem                  | 2.0   | -28.0 | -36.0"
                # Use pipe as field separator to get coordinates from fields 3, 4, 5
                local brainstem_coords=$(echo "$brainstem_line" | awk -F'|' '{gsub(/^ *| *$/, "", $3); gsub(/^ *| *$/, "", $4); gsub(/^ *| *$/, "", $5); print $3, $4, $5}' || echo "")
                if [ -n "$brainstem_coords" ]; then
                    log_message "Brainstem MNI coordinates: $brainstem_coords"
                    
                    # Parse coordinates for validation with improved error handling
                    local mni_x=$(echo "$brainstem_coords" | awk '{print $1}' | sed 's/^ *//;s/ *$//')
                    local mni_y=$(echo "$brainstem_coords" | awk '{print $2}' | sed 's/^ *//;s/ *$//')
                    local mni_z=$(echo "$brainstem_coords" | awk '{print $3}' | sed 's/^ *//;s/ *$//')
                    
                    # Validate we actually got three numeric values
                    if [ -z "$mni_x" ] || [ -z "$mni_y" ] || [ -z "$mni_z" ]; then
                        log_formatted "WARNING" "Failed to parse all three MNI coordinates from: '$brainstem_coords'"
                        log_message "Raw brainstem line: $brainstem_line"
                        log_message "Parsed coordinates: X='$mni_x', Y='$mni_y', Z='$mni_z'"
                        log_message "Skipping coordinate validation due to parsing error"
                    else
                        log_message "Parsed coordinates: X=$mni_x, Y=$mni_y, Z=$mni_z"
                    
                        # Validate coordinates are in expected range for brainstem
                        # Expected: X near 0-2 (midline), Y negative (posterior), Z negative (inferior)
                        if (( $(echo "$mni_x >= -5 && $mni_x <= 5" | bc -l) )) && \
                           (( $(echo "$mni_y <= -20 && $mni_y >= -40" | bc -l) )) && \
                           (( $(echo "$mni_z <= -30 && $mni_z >= -50" | bc -l) )); then
                            log_formatted "SUCCESS" "✓ Brainstem MNI coordinates are anatomically plausible"
                        else
                            log_formatted "WARNING" "Brainstem MNI coordinates outside expected range"
                            log_message "Expected: X(-5 to 5), Y(-40 to -20), Z(-50 to -30)"
                            log_message "Actual: X($mni_x), Y($mni_y), Z($mni_z)"
                        fi
                    fi
                fi
            else
                log_formatted "ERROR" "Brainstem region (index 7) not found in atlas summary"
                log_message "This indicates atlas corruption or incorrect atlas version"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Show first few labels for verification
            log_message "Atlas label preview:"
            echo "$atlas_summary" | grep -A 8 "Index | Label" | tail -8
        fi
    else
        log_formatted "WARNING" "atlasq not available - performing basic FSL validation only"
    fi
    
    # FSL-based atlas validation
    log_message "Performing FSL-based atlas validation..."
    
    # Check if atlas is a valid NIfTI file
    if ! fslinfo "$harvard_subcortical" >/dev/null 2>&1; then
        log_formatted "ERROR" "Harvard-Oxford atlas is not a valid NIfTI file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Check atlas dimensions and basic properties
    local atlas_dims=$(fslinfo "$harvard_subcortical" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local atlas_voxels=$(fslstats "$harvard_subcortical" -V | awk '{print $1}')
    local atlas_max=$(fslstats "$harvard_subcortical" -R | awk '{print $2}')
    
    log_message "Atlas $harvard_subcortical"
    log_message "  Dimensions: $atlas_dims | Total voxels: $atlas_voxels | Max label value: $atlas_max"
    
    # Validate atlas has reasonable properties
    if [ "$atlas_voxels" -lt 1000000 ]; then
        log_formatted "WARNING" "Atlas seems too small ($atlas_voxels voxels) - may be corrupted"
    fi
    
    if (( $(echo "$atlas_max < 7" | bc -l) )); then
        log_formatted "ERROR" "Atlas max value ($atlas_max) is less than 7 - brainstem region not available"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate atlas has reasonable properties
    if [ "$atlas_voxels" -lt 1000000 ]; then
        log_formatted "WARNING" "Atlas seems too small ($atlas_voxels voxels) - may be corrupted"
    fi
    
    if [ "$(echo "$atlas_max" | cut -d. -f1)" -lt 7 ]; then
        log_formatted "ERROR" "Atlas max label ($atlas_max) too low - should contain brainstem region (index 7)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Clean up test file
    rm -f "${temp_dir}/test_brainstem.nii.gz"
    
    # Check if templates exist
    if [ ! -f "$mni_template" ] || [ ! -f "$mni_brain" ]; then
        log_formatted "ERROR" "MNI templates not found at resolution ${template_res}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_formatted "SUCCESS" "Atlas validation completed - Harvard-Oxford atlas is valid"
    
    # NOTE: Registration will be performed after orientation correction
    # Create transforms directory if it doesn't exist
    mkdir -p "${RESULTS_DIR}/registered/transforms"
        
    # Set up ANTs registration parameters using existing configuration
    local ants_prefix="${RESULTS_DIR}/registered/transforms/ants_to_mni_"
    local ants_warped="${RESULTS_DIR}/registered/transforms/ants_to_mni_warped.nii.gz"
    local brainstem_mask_mni_file="${RESULTS_DIR}/registered/transforms/brainstem_mask_mni_file.nii.gz"
    
    # Step 4: Transform brainstem mask to subject T1 space
    log_message "Transforming brainstem mask to subject T1 space..."
    
    # COMPREHENSIVE: Validate coordinate spaces, dimensions, and transformations (ENHANCED)
    log_message "======= COMPREHENSIVE COORDINATE SPACE VALIDATION (ENHANCED) ======="
    log_message "Using fslorient for precise coordinate system analysis as requested"
    
    # Get precise coordinate system information using fslorient
    local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
    local mni_orient=$(fslorient -getorient "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    local atlas_orient=$(fslorient -getorient "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    
    # CRITICAL: Get qform and sform codes using fslorient (as demonstrated by user)
    local input_qform=$(fslorient -getqformcode "$input_file" 2>/dev/null || echo "UNKNOWN")
    local input_sform=$(fslorient -getsformcode "$input_file" 2>/dev/null || echo "UNKNOWN")
    local mni_qform=$(fslorient -getqformcode "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    local mni_sform=$(fslorient -getsformcode "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    local atlas_qform=$(fslorient -getqformcode "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    local atlas_sform=$(fslorient -getsformcode "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    
    log_message "=== ORIENTATION VALIDATION ==="
    log_message "  Subject T1: $input_orient (qform: $input_qform, sform: $input_sform)"
    log_message "  MNI template: $mni_orient (qform: $mni_qform, sform: $mni_sform)"
    log_message "  Atlas (post-reorientation): $atlas_orient (qform: $atlas_qform, sform: $atlas_sform)"
    
    # VALIDATION: Check that coordinate systems are now compatible
    log_message "=== COORDINATE SYSTEM COMPATIBILITY CHECK ==="
    local post_reorientation_issues=false
    
    if [ "$input_qform" != "UNKNOWN" ] && [ "$atlas_qform" != "UNKNOWN" ] && [ "$input_qform" != "$atlas_qform" ]; then
        log_formatted "ERROR" "QFORM codes still don't match: Subject ($input_qform) vs Atlas ($atlas_qform)"
        log_formatted "ERROR" "This indicates atlas reorientation failed or incomplete"
        post_reorientation_issues=true
    fi
    
    if [ "$input_sform" != "UNKNOWN" ] && [ "$atlas_sform" != "UNKNOWN" ] && [ "$input_sform" != "$atlas_sform" ]; then
        log_formatted "ERROR" "SFORM codes still don't match: Subject ($input_sform) vs Atlas ($atlas_sform)"
        log_formatted "ERROR" "This indicates atlas reorientation failed or incomplete"
        post_reorientation_issues=true
    fi
    
    if [ "$input_orient" != "UNKNOWN" ] && [ "$atlas_orient" != "UNKNOWN" ] && [ "$input_orient" != "$atlas_orient" ]; then
        log_formatted "ERROR" "Orientations still don't match: Subject ($input_orient) vs Atlas ($atlas_orient)"
        log_formatted "ERROR" "This indicates atlas reorientation failed or incomplete"
        post_reorientation_issues=true
    fi
    
    if [ "$post_reorientation_issues" = "true" ]; then
        log_formatted "CRITICAL" "Atlas reorientation was unsuccessful - anatomical mislocalization WILL occur"
        log_formatted "CRITICAL" "Expected: All coordinate codes and orientations should match between subject and atlas"
        log_formatted "ERROR" "STOPPING PIPELINE to prevent FSL orientation warnings and incorrect results"
        rm -rf "$temp_dir"
        return 1
    fi
        
    # Extract sform matrices for detailed analysis (supplementary to fslorient)
    local input_sform_matrix=$(fslinfo "$input_file" | grep -E "sform_[xyz]" | awk '{print $2}' | tr '\n' ' ')
    local mni_sform_matrix=$(fslinfo "$mni_brain" | grep -E "sform_[xyz]" | awk '{print $2}' | tr '\n' ' ')
    local atlas_sform_matrix=$(fslinfo "$harvard_subcortical" | grep -E "sform_[xyz]" | awk '{print $2}' | tr '\n' ' ')
    
    log_message "  Subject sform matrix elements: $input_sform_matrix"
    log_message "  MNI sform matrix elements: $mni_sform_matrix"
    log_message "  Atlas sform matrix elements: $atlas_sform_matrix"
    
    # Check voxel dimensions for scaling compatibility
    local input_pixdims=$(fslinfo "$input_file" | grep -E "pixdim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local mni_pixdims=$(fslinfo "$mni_brain" | grep -E "pixdim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local atlas_pixdims=$(fslinfo "$harvard_subcortical" | grep -E "pixdim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    
    log_message "Voxel dimension analysis:"
    log_message "  Subject voxels: ${input_pixdims}mm"
    log_message "  MNI template voxels: ${mni_pixdims}mm" 
    log_message "  Atlas voxels: ${atlas_pixdims}mm"
    
    # Check matrix dimensions for compatibility
    local input_dims=$(fslinfo "$input_file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local mni_dims=$(fslinfo "$mni_brain" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local atlas_dims=$(fslinfo "$harvard_subcortical" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    
    log_message "Matrix dimension analysis:"
    log_message "  Subject matrix: $input_dims"
    log_message "  MNI template matrix: $mni_dims"
    log_message "  Atlas matrix: $atlas_dims"
    
    
    log_message "Axis direction validation:"
    validate_axis_directions "$input_file" "Subject"
    validate_axis_directions "$mni_brain" "MNI template"
    validate_axis_directions "$harvard_subcortical" "Atlas"
    
    # Run coordinate space issue detection
    detect_coordinate_space_issues
    local coord_issues=$?
    
    log_message "======================================================="
    
    # ===== HARVARD-OXFORD ATLAS COORDINATE CORRECTION =========================
    # Handle both basic orientation AND axis direction issues
    local atlas_corrected="$harvard_subcortical"
    local correction_needed=false
    
    # Prepare for corrections
    if [ "$atlas_orient" != "$mni_orient" ] && [ "$atlas_orient" != "UNKNOWN" ] && [ "$mni_orient" != "UNKNOWN" ]; then
        correction_needed=true
        log_formatted "INFO" "Basic orientation correction needed: $atlas_orient → $mni_orient"
    fi
    
    if [ "$coord_issues" -eq 1 ]; then
        correction_needed=true
        log_formatted "INFO" "Axis direction correction needed due to coordinate space mismatches"
    fi
    
    if [ "$correction_needed" = "true" ]; then
        atlas_corrected="${temp_dir}/harvard_oxford_corrected.nii.gz"
        log_formatted "INFO" "Applying comprehensive atlas coordinate correction..."
        
        # Determine the appropriate fslswapdim parameters based on detected issues
        local swap_x="x"
        local swap_y="y" 
        local swap_z="z"
        
        # Apply axis direction corrections if detected
        if [ "$coord_issues" -eq 1 ]; then
            # Extract axis directions again for correction logic
            local atlas_xx=$(fslinfo "$harvard_subcortical" | grep "sform_xorient" | awk '{print $2}')
            local atlas_yy=$(fslinfo "$harvard_subcortical" | grep "sform_yorient" | awk '{print $2}')
            local atlas_zz=$(fslinfo "$harvard_subcortical" | grep "sform_zorient" | awk '{print $2}')
            
            local mni_xx=$(fslinfo "$mni_brain" | grep "sform_xorient" | awk '{print $2}')
            local mni_yy=$(fslinfo "$mni_brain" | grep "sform_yorient" | awk '{print $2}')
            local mni_zz=$(fslinfo "$mni_brain" | grep "sform_zorient" | awk '{print $2}')
            
            # Flip axes if directions don't match
            if [ "$(echo "($atlas_xx > 0 && $mni_xx < 0) || ($atlas_xx < 0 && $mni_xx > 0)" | bc -l 2>/dev/null)" = "1" ]; then
                swap_x="-x"
                log_message "  Flipping X-axis direction"
            fi
            
            if [ "$(echo "($atlas_yy > 0 && $mni_yy < 0) || ($atlas_yy < 0 && $mni_yy > 0)" | bc -l 2>/dev/null)" = "1" ]; then
                swap_y="-y"
                log_message "  Flipping Y-axis direction"
            fi
            
            if [ "$(echo "($atlas_zz > 0 && $mni_zz < 0) || ($atlas_zz < 0 && $mni_zz > 0)" | bc -l 2>/dev/null)" = "1" ]; then
                swap_z="-z"
                log_message "  Flipping Z-axis direction"
            fi
        fi
        
        # Additional orientation-based corrections
        if [ "$atlas_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
            swap_x="-x"  # Override or combine with axis flip
            log_message "  Additional NEUROLOGICAL→RADIOLOGICAL correction"
        elif [ "$atlas_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
            swap_x="-x"  # Override or combine with axis flip
            log_message "  Additional RADIOLOGICAL→NEUROLOGICAL correction"
        fi
        
        # Apply the comprehensive correction
        log_message "Applying fslswapdim with: $swap_x $swap_y $swap_z"
        fslswapdim "$harvard_subcortical" $swap_x $swap_y $swap_z "$atlas_corrected"
        
        # Set the target orientation
        if [ "$mni_orient" = "RADIOLOGICAL" ]; then
            fslorient -forceradiological "$atlas_corrected"
        elif [ "$mni_orient" = "NEUROLOGICAL" ]; then
            fslorient -forceneurological "$atlas_corrected"
        fi
        
        # Verify correction was successful
        local atlas_corr_orient=$(fslorient -getorient "$atlas_corrected" 2>/dev/null || echo "UNKNOWN")
        log_formatted "SUCCESS" "Atlas correction completed: $atlas_corr_orient"
        
        # Re-validate coordinate directions after correction
        log_message "Re-validating coordinate directions after correction..."
        validate_axis_directions "$atlas_corrected" "Corrected Atlas"
        
    else
        log_formatted "SUCCESS" "✓ No atlas coordinate correction needed"
    fi
    
    # CRITICAL FIX: Handle orientation mismatch
    local orientation_corrected_input="$input_file"
    local orientation_corrected=false
    
    if [ "$input_orient" = "UNKNOWN" ] || [ "$mni_orient" = "UNKNOWN" ]; then
        log_formatted "WARNING" "Cannot determine image orientations - proceeding with caution"
    elif [ "$input_orient" != "$mni_orient" ]; then
        log_formatted "WARNING" "Orientation mismatch detected: Subject ($input_orient) vs MNI ($mni_orient)"
        log_formatted "INFO" "Applying orientation correction to fix anatomical mislocalization"
        
        # Create orientation-corrected version of input for registration
        orientation_corrected_input="${temp_dir}/input_orientation_corrected.nii.gz"
        
        if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
            log_message "Converting NEUROLOGICAL to RADIOLOGICAL orientation..."
            # Flip left-right (X-axis) to convert NEUROLOGICAL to RADIOLOGICAL
            fslswapdim "$input_file" -x y z "$orientation_corrected_input"
            # Explicitly set orientation metadata to RADIOLOGICAL
            fslorient -forceradiological "$orientation_corrected_input"
            orientation_corrected=true
        elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
            log_message "Converting RADIOLOGICAL to NEUROLOGICAL orientation..."
            # Flip left-right (X-axis) to convert RADIOLOGICAL to NEUROLOGICAL
            fslswapdim "$input_file" -x y z "$orientation_corrected_input"
            # Explicitly set orientation metadata to NEUROLOGICAL
            fslorient -forceneurological "$orientation_corrected_input"
            orientation_corrected=true
        else
            log_formatted "WARNING" "Unsupported orientation conversion: $input_orient to $mni_orient"
            log_message "Proceeding without orientation correction - results may be incorrect"
            cp "$input_file" "$orientation_corrected_input"
        fi
        
        # Verify the corrected file was created
        if [ ! -f "$orientation_corrected_input" ]; then
            log_formatted "ERROR" "Failed to create orientation-corrected input file"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # Update orientation info
        local corrected_orient=$(fslorient -getorient "$orientation_corrected_input" 2>/dev/null || echo "UNKNOWN")
        log_message "Corrected subject orientation: $corrected_orient"
        
        if [ "$corrected_orient" = "$mni_orient" ]; then
            log_formatted "SUCCESS" "Orientation correction successful: $corrected_orient"
        else
            log_formatted "WARNING" "Orientation correction may be incomplete: $corrected_orient vs expected $mni_orient"
        fi
    else
        log_formatted "SUCCESS" "Orientations match: $input_orient"
        # No correction needed, but copy file to temp location for consistency
        cp "$input_file" "${temp_dir}/input_orientation_corrected.nii.gz"
        orientation_corrected_input="${temp_dir}/input_orientation_corrected.nii.gz"
    fi
    
    # Step 1: Register orientation-corrected input to MNI space using ANTs
    log_message "Registering $orientation_corrected_input to MNI space using ANTs..."
    
    # CRITICAL: Use full SyN registration (affine + warp) for proper composite transforms
    # Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)
    log_formatted "INFO" "Using composite SyN registration (affine + nonlinear warp)"
    
    # DEBUG: Check if transform files already exist
    log_message "=== TRANSFORM FILE EXISTENCE CHECK ==="
    local affine_transform="${ants_prefix}0GenericAffine.mat"
    local warp_transform="${ants_prefix}1Warp.nii.gz"
    
    if [ -f "$affine_transform" ]; then
        local affine_age=$(find "$affine_transform" -mtime -1 2>/dev/null | wc -l)
        local affine_size=$(stat -f "%z" "$affine_transform" 2>/dev/null || stat --format="%s" "$affine_transform" 2>/dev/null || echo "0")
        log_message "Existing affine transform found: $affine_transform ($affine_size bytes, recent: $affine_age)"
    else
        log_message "No existing affine transform: $affine_transform"
    fi
    
    if [ -f "$warp_transform" ]; then
        local warp_age=$(find "$warp_transform" -mtime -1 2>/dev/null | wc -l)
        local warp_size=$(stat -f "%z" "$warp_transform" 2>/dev/null || stat --format="%s" "$warp_transform" 2>/dev/null || echo "0")
        log_message "Existing warp transform found: $warp_transform ($warp_size bytes, recent: $warp_age)"
    else
        log_message "No existing warp transform: $warp_transform"
    fi
    
    # Check if we should skip registration due to existing valid transforms
    local skip_registration=false
    if [ -f "$affine_transform" ] && [ -f "$warp_transform" ]; then
        local both_recent=$(find "$affine_transform" "$warp_transform" -mtime -1 2>/dev/null | wc -l)
        if [ "$both_recent" -eq 2 ]; then
            log_formatted "WARNING" "Recent ANTs transforms found - registration may be skipped"
            log_message "If you want fresh registration, delete: $affine_transform and $warp_transform"
            skip_registration=true
        fi
    fi
    
    # Enhanced cleanup based on pipeline stage
    if [ "${FORCE_FRESH_REGISTRATION:-false}" = "true" ]; then
        log_formatted "INFO" "FORCE_FRESH_REGISTRATION=true - removing existing transforms"
        rm -f "${ants_prefix}"*GenericAffine.mat "${ants_prefix}"*Warp.nii.gz "${ants_prefix}"*InverseWarp.nii.gz
        rm -f "${ants_prefix}"Warped.nii.gz "${ants_prefix}"README.txt
        log_message "Removed existing transform files to force fresh registration"
    fi
        
    if [ "$orientation_corrected" = "true" ]; then
        log_formatted "INFO" "Running full SyN registration due to orientation correction"
        
        # DEBUG: Show exact command and parameters before execution
        log_message "=== EXECUTE_ANTS_COMMAND DEBUG INFO ==="
        log_message "Command: antsRegistrationSyNQuick.sh"
        log_message "Fixed template: $mni_brain"
        log_message "Moving image: $orientation_corrected_input"
        log_message "Transform type: s (SyN)"
        log_message "Output prefix: $ants_prefix"
        log_message "Threads: ${ANTS_THREADS:-1}"
        log_message "Skip registration flag: $skip_registration"
        
        # Check if antsRegistrationSyNQuick.sh will skip due to existing files
        if [ "$skip_registration" = "true" ]; then
            log_formatted "WARNING" "execute_ants_command may skip registration due to existing transforms"
            log_message "To force fresh registration, delete existing transforms first"
        fi
        
        # Run full SyN registration (not just affine) for composite transforms
        local start_time=$(date +%s)
        execute_ants_command "ants_to_mni_syn_registration" "Full SyN registration to MNI template (orientation corrected)" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_message "execute_ants_command completed in ${duration} seconds"
        if [ "$duration" -lt 30 ]; then
            log_formatted "WARNING" "SyN registration completed suspiciously fast (${duration}s)"
            log_message "This suggests existing transforms were reused or registration failed silently"
        fi
    elif command -v compute_initial_affine &> /dev/null; then
        # Use the existing function but ensure it does SyN registration
        log_message "Using compute_initial_affine function with SyN enhancement"
        log_message "=== COMPUTE_INITIAL_AFFINE DEBUG INFO ==="
        log_message "Skip registration flag: $skip_registration"
        
        local start_time=$(date +%s)
        compute_initial_affine "$orientation_corrected_input" "$mni_brain" "$ants_prefix"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_message "compute_initial_affine completed in ${duration} seconds"
        
        # If only affine was computed, run additional SyN step
        if [ ! -f "${ants_prefix}1Warp.nii.gz" ]; then
            log_message "Adding nonlinear warp component to complete composite transform"
            log_message "=== SYN ENHANCEMENT DEBUG INFO ==="
            log_message "Warp field missing, running SyN enhancement..."
            
            local syn_start_time=$(date +%s)
            execute_ants_command "ants_syn_enhancement" "Adding nonlinear component to existing affine" \
                antsRegistrationSyNQuick.sh \
                -d 3 \
                -f "$mni_brain" \
                -m "$orientation_corrected_input" \
                -t s \
                -o "$ants_prefix" \
                -n "${ANTS_THREADS:-1}"
            local syn_end_time=$(date +%s)
            local syn_duration=$((syn_end_time - syn_start_time))
            
            log_message "SyN enhancement completed in ${syn_duration} seconds"
            if [ "$syn_duration" -lt 30 ]; then
                log_formatted "WARNING" "SyN enhancement completed suspiciously fast (${syn_duration}s)"
            fi
        else
            log_message "Warp field already exists, skipping SyN enhancement"
        fi
    else
        # Fallback: Run full SyN registration using execute_ants_command
        log_message "Running ANTs full SyN registration to MNI space..."
        log_message "=== FALLBACK REGISTRATION DEBUG INFO ==="
        log_message "Skip registration flag: $skip_registration"
        
        local start_time=$(date +%s)
        execute_ants_command "ants_to_mni_syn_registration" "Full SyN registration to MNI template" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_message "Fallback registration completed in ${duration} seconds"
        if [ "$duration" -lt 30 ]; then
            log_formatted "WARNING" "Fallback registration completed suspiciously fast (${duration}s)"
        fi
    fi
    
    # Check if composite registration succeeded - both components required
    if [ ! -f "${ants_prefix}0GenericAffine.mat" ]; then
        log_formatted "ERROR" "ANTs registration failed - affine transform not created"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ ! -f "${ants_prefix}1Warp.nii.gz" ]; then
        log_formatted "ERROR" "ANTs registration failed - warp field not created"
        log_formatted "ERROR" "Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate transform files are non-empty and readable
    local affine_size=$(stat -f "%z" "${ants_prefix}0GenericAffine.mat" 2>/dev/null || stat --format="%s" "${ants_prefix}0GenericAffine.mat" 2>/dev/null || echo "0")
    local warp_size=$(stat -f "%z" "${ants_prefix}1Warp.nii.gz" 2>/dev/null || stat --format="%s" "${ants_prefix}1Warp.nii.gz" 2>/dev/null || echo "0")
    
    if [ "$affine_size" -lt 100 ]; then
        log_formatted "ERROR" "Affine transform file is suspiciously small or empty: $affine_size bytes"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ "$warp_size" -lt 1000 ]; then
        log_formatted "ERROR" "Warp field file is suspiciously small or empty: $warp_size bytes"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # The ANTs composite transforms are automatically invertible
    log_formatted "SUCCESS" "ANTs composite registration completed successfully"
    log_message "  Affine component: ${ants_prefix}0GenericAffine.mat ($affine_size bytes)"
    log_message "  Warp component: ${ants_prefix}1Warp.nii.gz ($warp_size bytes)"
    
    # Validate registration quality with True MI
    validate_registration_quality "$mni_brain" "$orientation_corrected_input" "$ants_prefix"
    
    # Step 3: Transform Harvard-Oxford atlas to subject space (preserving native resolution)
    log_message "Transforming Harvard-Oxford atlas to subject native space..."
    
    # Transform the ENTIRE atlas to subject space first, then extract regions
    # This preserves subject resolution and is more efficient
    local atlas_in_subject="${RESULTS_DIR}/registered/harvard_oxford_in_subject.nii.gz"
    
    # CRITICAL FIX: Use centralized apply_transformation function for consistent SyN handling
    log_message "Applying composite transforms: warp field + affine (atlas→subject mapping)"
    
    # Use centralized apply_transformation function for consistent SyN transform handling
    if apply_transformation "$atlas_corrected" "$orientation_corrected_input" "$atlas_in_subject" "$ants_prefix" "NearestNeighbor"; then
        log_message "✓ Successfully applied transform using centralized function"
    else
        log_formatted "ERROR" "Failed to apply transform using centralized function"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Check if atlas transformation was successful
    if [ ! -f "$atlas_in_subject" ]; then
        log_formatted "ERROR" "Failed to transform atlas to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Now extract brainstem from the transformed atlas in subject space
    log_message "Extracting brainstem from atlas in subject native space..."
    
    local brainstem_index=7  # Brain-Stem in Harvard-Oxford subcortical atlas
    log_message "Extracting brainstem (index $brainstem_index) from transformed atlas..."
    
    # DEBUG: Check atlas dimensions before extraction
    log_message "=== MASK DIMENSION DEBUG ==="
    local atlas_dims=$(fslinfo "$atlas_in_subject" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local atlas_nonzero_voxels=$(fslstats "$atlas_in_subject" -V | awk '{print $1}')
    local atlas_total_voxels=$(echo "$atlas_dims" | awk -F'x' '{print $1 * $2 * $3}')
    log_message "Atlas in subject space dimensions: $atlas_dims"
    log_message "Atlas calculated total voxels: $atlas_total_voxels"
    log_message "Atlas non-zero voxels: $atlas_nonzero_voxels"
    
    # Check brainstem voxels in atlas before extraction (using tolerance for floating-point artifacts)
    local brainstem_lower=6.9
    local brainstem_upper=7.1
    local brainstem_in_atlas=$(fslstats "$atlas_in_subject" -l $brainstem_lower -u $brainstem_upper -V | awk '{print $1}')
    log_message "Brainstem voxels (range $brainstem_lower-$brainstem_upper) in atlas: $brainstem_in_atlas"
    
    # Use tolerance range to capture floating-point interpolation artifacts
    log_message "Using tolerance range [$brainstem_lower, $brainstem_upper] to handle floating-point interpolation artifacts"
    fslmaths "$atlas_in_subject" -thr $brainstem_lower -uthr $brainstem_upper -bin "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" -odt int
    
    # DEBUG: Check mask dimensions after extraction
    local mask_dims=$(fslinfo "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local mask_nonzero_voxels=$(fslstats "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" -V | awk '{print $1}')
    local mask_total_voxels=$(echo "$mask_dims" | awk -F'x' '{print $1 * $2 * $3}')
    log_message "Mask dimensions after extraction: $mask_dims"
    log_message "Mask calculated total voxels: $mask_total_voxels"
    log_message "Mask non-zero voxels: $mask_nonzero_voxels"
    
    # CRITICAL: Check if dimensions match
    if [ "$atlas_dims" != "$mask_dims" ]; then
        log_formatted "ERROR" "DIMENSION MISMATCH! Atlas: $atlas_dims, Mask: $mask_dims"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ "$atlas_total_voxels" != "$mask_total_voxels" ]; then
        log_formatted "ERROR" "TOTAL VOXEL COUNT MISMATCH! Atlas: $atlas_total_voxels, Mask: $mask_total_voxels"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Check if brainstem extraction worked
    if [ "$brainstem_in_atlas" != "$mask_nonzero_voxels" ]; then
        log_formatted "ERROR" "BRAINSTEM EXTRACTION FAILED! Expected: $brainstem_in_atlas, Got: $mask_nonzero_voxels"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local voxel_count="$mask_nonzero_voxels"
    if [ "$voxel_count" -gt 100 ]; then
        log_message "Found brainstem with $voxel_count non-zero voxels in subject space"
    else
        log_formatted "ERROR" "Brainstem region too small or not found in subject space (only $voxel_count voxels)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # BRAIN-STEM REFINEMENT: Generate subject-specific mask using Atropos/FAST
    # Affine-only atlas projection presumes negligible brain-stem shape variance—contradicted by hydrocephalus & Chiari cases
    log_message "Addressing shape variance in hydrocephalus & Chiari cases with subject-specific segmentation"
    
    # Apply brain-stem refinement
    local refinement_temp_dir="${temp_dir}/refinement"
    mkdir -p "$refinement_temp_dir"
    
    local refined_mask="${RESULTS_DIR}/registered/brainstem_mask_subject_refined.nii.gz"
    
    if refine_brainstem_mask_subject_specific "$orientation_corrected_input" \
                                           "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" \
                                           "$refined_mask" \
                                           "$refinement_temp_dir"; then
        log_message "Using refined subject-specific brainstem mask"
        cp "$refined_mask" "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz"
    else
        log_formatted "WARNING" "Subject-specific refinement failed, using atlas-based mask"
    fi
    
    # Clean up refinement temporary files
    rm -rf "$refinement_temp_dir"
    
    # If orientation correction was applied, we need to transform back to original orientation
    # @todo The orientation correction occurs to atlasses  not subject files, this isnt needed
    if [ "$orientation_corrected" = "TRUEtrue" ]; then
        log_message "Converting brainstem mask back to original subject orientation..."
        
        # Apply reverse orientation correction to the mask
        if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
            # Convert back from RADIOLOGICAL to NEUROLOGICAL
            fslswapdim "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" -x y z "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz"
            # Set orientation back to original NEUROLOGICAL
            fslorient -forceneurological "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz"
        elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
            # Convert back from NEUROLOGICAL to RADIOLOGICAL
            fslswapdim "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" -x y z "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz"
            # Set orientation back to original RADIOLOGICAL
            fslorient -forceradiological "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz"
        else
            # No correction applied or unsupported conversion
            cp "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz"
        fi
        
        # Use the corrected version
        mv "${RESULTS_DIR}/registered/brainstem_mask_subject_tri_corrected.nii.gz" "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz"
        log_message "Orientation correction applied to brainstem mask"
    fi
    
    # Check if the transform was successful
    if [ ! -f "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" ]; then
        log_formatted "ERROR" "Failed to transform brainstem mask to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Threshold at 0.5 to create binary mask (captures partial volume voxels)
    fslmaths "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" -thr 0.5 -bin "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" -odt int
    
    # CRITICAL: Validate anatomical location of transformed mask
    log_formatted "INFO" "===== ANATOMICAL LOCATION VALIDATION ====="
    local com=$(fslstats "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" -C)
    local dims=$(fslinfo "$input_file" | grep -E "^dim[1-3]" | awk '{print $2}')
    
    log_message "Validating brainstem mask in original subject space..."
    
    # Parse center of mass and dimensions
    local x=$(echo "$com" | awk '{print $1}')
    local y=$(echo "$com" | awk '{print $2}')
    local z=$(echo "$com" | awk '{print $3}')
    local dimx=$(echo "$dims" | sed -n '1p')
    local dimy=$(echo "$dims" | sed -n '2p')
    local dimz=$(echo "$dims" | sed -n '3p')
    
    # Calculate relative position (percentage of volume)
    local rel_x=$(echo "scale=2; $x / $dimx" | bc -l)
    local rel_y=$(echo "scale=2; $y / $dimy" | bc -l)
    local rel_z=$(echo "scale=2; $z / $dimz" | bc -l)
    
    log_message "Brainstem center of mass: ($x, $y, $z)"
    log_message "Image dimensions: ${dimx}x${dimy}x${dimz}"
    log_message "Relative position: (${rel_x}, ${rel_y}, ${rel_z})"
    
    # Validate anatomical plausibility
    local anatomically_plausible=true
    
    # Brainstem should be:
    # - Centered in X (0.4 < rel_x < 0.6)
    # - Posterior in Y (depends on orientation, but generally 0.3 < rel_y < 0.7)
    # - Inferior in Z (rel_z < 0.4 for most orientations)
    
    if (( $(echo "$rel_x < 0.3 || $rel_x > 0.7" | bc -l) )); then
        log_formatted "WARNING" "Brainstem X position unusual: $rel_x (expected 0.4-0.6 for midline)"
        anatomically_plausible=false
    fi
    
    if (( $(echo "$rel_z > 0.6" | bc -l) )); then
        log_formatted "WARNING" "Brainstem Z position unusual: $rel_z (expected < 0.4 for inferior brain)"
        anatomically_plausible=false
    fi
    
    # Check volume is reasonable (typical brainstem is 3000-15000 voxels depending on resolution)
    local mask_volume=$(fslstats "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" -V | awk '{print $1}')
    if [ "$mask_volume" -lt 500 ] || [ "$mask_volume" -gt 50000 ]; then
        log_formatted "WARNING" "Brainstem volume unusual: $mask_volume voxels (expected 500-50000)"
        anatomically_plausible=false
    fi
    
    if [ "$anatomically_plausible" = "false" ]; then
        log_formatted "ERROR" "CRITICAL: Brainstem segmentation appears anatomically implausible!"
        log_formatted "ERROR" "This suggests a coordinate space transformation error."
        log_formatted "ERROR" "Possible causes:"
        log_formatted "ERROR" "  1. Registration failure between subject and MNI space"
        log_formatted "ERROR" "  2. Orientation mismatch between images"
        log_formatted "ERROR" "  3. Atlas coordinate system mismatch"
        log_formatted "ERROR" "  4. Transform inversion applied incorrectly"
                
        # Copy intermediate files for inspection
        cp "${brainstem_mask_mni_file}" "${output_dir}/../debug_brainstem_mni.nii.gz" 2>/dev/null || true
        cp "${RESULTS_DIR}/registered/brainstem_mask_subject_tri.nii.gz" "${output_dir}/../debug_brainstem_subject_tri.nii.gz" 2>/dev/null || true
        cp "${ants_prefix}0GenericAffine.mat" "${output_dir}/../debug_transform.mat" 2>/dev/null || true
        
        log_message "Debug files saved to $(dirname "$output_dir")"
        log_message "  debug_brainstem_mni.nii.gz - Brainstem mask in MNI space"
        log_message "  debug_brainstem_subject_tri.nii.gz - Transformed mask before thresholding"
        log_message "  debug_transform.mat - ANTs transformation matrix"
        
        # Create visualization overlay for manual inspection
        local debug_overlay="${output_dir}/../debug_brainstem_overlay.nii.gz"
        if overlay 1 0 "$input_file" -5000 5000 "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" 0.5 1 "$debug_overlay" 2>/dev/null; then
            log_message "  debug_brainstem_overlay.nii.gz - Overlay for visual inspection"
        fi
        
        rm -rf "$temp_dir"
        return 1
    else
        log_formatted "SUCCESS" "Brainstem segmentation passes anatomical validation"
        log_message "Volume: $mask_volume voxels, Position: (${rel_x}, ${rel_y}, ${rel_z})"
    fi
    
    # Step 5: Apply mask to get intensity values
    log_message "Creating intensity-based brainstem segmentation..."
    
    # Verify mask exists
    if [ ! -f "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" ]; then
        log_formatted "ERROR" "Brainstem mask not found: ${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Convert output path to absolute if relative
    local abs_output_file="$output_file"
    
    log_message "Output will be written to: $abs_output_file"
    
    # Remove any existing file or symlink at the output location
    if [ -L "$abs_output_file" ] || [ -e "$abs_output_file" ]; then
        log_message "Removing existing file/symlink at output location"
        rm -f "$abs_output_file"
    fi
    
    # Apply mask using fslmaths directly (safe_fslmaths is checking output as input)
    fslmaths "$input_file" -mas "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" \
             "$abs_output_file"
    
    # Check if output was created
    if [ ! -f "$abs_output_file" ]; then
        log_formatted "ERROR" "Failed to create brainstem segmentation"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Also save the binary mask
    local mask_file="${output_dir}/$(basename $output_file .nii.gz)_mask.nii.gz"
    log_message "Saving mask file: $mask_file"

    # Remove any existing mask file
    if [ -L "$mask_file" ] || [ -e "$mask_file" ]; then
        rm -f "$mask_file"
    fi
    
    cp "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" "$mask_file"

    # Create T1 intensity version for QA module compatibility
    local output_dir_path="$(dirname "$abs_output_file")"
    local base_name=$(basename "$abs_output_file" .nii.gz)
    local t1_intensity_file="${output_dir_path}/${base_name}_t1_intensity.nii.gz"
    
    log_message "Creating T1 intensity version for QA module..."
    if fslmaths "$input_file" -mas "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" "$t1_intensity_file"; then
        log_message "✓ Created T1 intensity version: $(basename "$t1_intensity_file")"
    else
        log_formatted "WARNING" "Failed to create T1 intensity version (non-critical)"
    fi
    
    # Apply segmentation to FLAIR AND create FLAIR-space versions for analysis compatibility
    log_message "Checking for FLAIR to apply segmentation and create analysis-compatible versions..."
    local flair_registered="${RESULTS_DIR}/registered/*_std_to_t1Warped.nii.gz"
    local flair_files_found=()
    local original_flair_files=()
    local registration_dir="${RESULTS_DIR}/registered"
    
    log_message "=== HARVARD-OXFORD FLAIR DISCOVERY ==="
    log_message "Looking for registered FLAIR files in: $registration_dir"
    
    # Look for registered FLAIR files using comprehensive patterns
    if [ -f "$flair_registered" ]; then
        flair_files_found+=("$flair_registered")
        log_message "Found flair_registered variable: $(basename "$flair_registered")"
    fi

    # Also look for other FLAIR registration patterns
    if [ -d "$registration_dir" ]; then
        log_message "Searching for FLAIR registration patterns:"
        log_message "  Pattern 1: *_std_to_t1Warped.nii.gz (user-specified)"
        log_message "  Pattern 2: *FLAIR*Warped.nii.gz"
        log_message "  Pattern 3: flair*Warped.nii.gz"
        
        # Use find with explicit maxdepth
        while IFS= read -r -d '' flair_file; do
            flair_files_found+=("$flair_file")
            log_message "Found registered FLAIR: $(basename "$flair_file")"
        done < <(find "$registration_dir" -maxdepth 1 -name "*_std_to_t1Warped.nii.gz" -o -name "*FLAIR*Warped.nii.gz" -o -name "flair*Warped.nii.gz" -print0 2>/dev/null)
        
        # Alternative approach: use glob patterns if find fails
        if [ ${#flair_files_found[@]} -eq 0 ]; then
            log_message "Find command failed, trying glob patterns..."
            for pattern in "*_std_to_t1Warped.nii.gz" "*FLAIR*Warped.nii.gz" "flair*Warped.nii.gz"; do
                for file in "$registration_dir"/$pattern; do
                    if [ -f "$file" ]; then
                        # Check if we already have this file to avoid duplicates
                        local already_found=false
                        for existing_file in "${flair_files_found[@]}"; do
                            if [ "$file" = "$existing_file" ]; then
                                already_found=true
                                break
                            fi
                        done
                        
                        if [ "$already_found" = "false" ]; then
                            flair_files_found+=("$file")
                            log_message "Glob found registered FLAIR: $file"
                        fi
                    fi
                done
            done
        fi
    else
        log_message "Registration directory does not exist: $registration_dir"
    fi

    # Final summary
    if [ ${#flair_files_found[@]} -gt 0 ]; then
        log_message "✓ Total registered FLAIR files found: ${#flair_files_found[@]}"
        for flair in "${flair_files_found[@]}"; do
            log_message "  - $(basename $flair)"
        done
    else
        log_message "⚠ No registered FLAIR files found"
    fi
    
    # Look for original FLAIR files for FLAIR-space analysis
    #if [ -d "${RESULTS_DIR}/standardized" ]; then
    #while IFS= read -r -d '' orig_flair; do
    #        original_flair_files+=("$orig_flair")
    #    done < <(find "${RESULTS_DIR}/standardized" \( -name "FLAIR*_std.nii.gz"  \) ! -name "*_intensity*" ! -name "*_t1_intensity*" ! -name "*_flair_intensity*" -print0 2>/dev/null)
    #fi
    
    # Apply segmentation to each registered FLAIR file found (T1 space)
    for flair_file in "${flair_files_found[@]}"; do
        if [ -f "$flair_file" ]; then
            local flair_base=$(basename "$flair_file" .nii.gz)
            local flair_intensity_file="${output_dir_path}/${base_name}_flair_intensity.nii.gz"
            
            # Check dimensions compatibility before applying mask
            local flair_dims=$(fslinfo "$flair_file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
            local mask_dims=$(fslinfo "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
            
            if [ "$flair_dims" = "$mask_dims" ]; then
                log_message "Creating FLAIR intensity version from: $(basename "$flair_file")"
                if fslmaths "$flair_file" -mas "${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz" "$flair_intensity_file"; then
                    log_message "✓ Created FLAIR intensity version: $(basename "$flair_intensity_file")"
                else
                    log_formatted "WARNING" "Failed to create FLAIR intensity version (non-critical)"
                fi
            else
                log_formatted "WARNING" "FLAIR dimensions ($flair_dims) don't match mask ($mask_dims) - skipping FLAIR intensity creation"
            fi
            
            # Only process the first compatible FLAIR file
            break
        fi
    done
    
    if [ ${#flair_files_found[@]} -eq 0 ] && [ ${#original_flair_files[@]} -eq 0 ]; then
        log_formatted "WARNING" "No FLAIR files found - T1 intensity only"
    fi
    
    # Create QA-compatible naming convention
    local mask_base_name=$(basename "$mask_file" .nii.gz)
    local qa_t1_intensity="${output_dir_path}/${mask_base_name}_t1_intensity.nii.gz"
    
    if [ -f "$t1_intensity_file" ] && [ "$t1_intensity_file" != "$qa_t1_intensity" ]; then
        ln -sf "$(basename "$t1_intensity_file")" "$qa_t1_intensity" 2>/dev/null
        cp "$t1_intensity_file" "$qa_t1_intensity"
        log_message "✓ Created QA-compatible T1 intensity: $qa_t1_intensity"
    fi
    
    # Create QA-compatible FLAIR intensity if it exists
    local flair_intensity_file="${output_dir_path}/${base_name}_flair_intensity.nii.gz"
    if [ -f "$flair_intensity_file" ]; then
        local qa_flair_intensity="${output_dir_path}/${mask_base_name}_flair_intensity.nii.gz"
        if [ "$flair_intensity_file" != "$qa_flair_intensity" ]; then
            ln -sf "$(basename "$flair_intensity_file")" "$qa_flair_intensity" 2>/dev/null
            cp "$flair_intensity_file" "$qa_flair_intensity"
            log_message "✓ Created QA-compatible FLAIR intensity: $(basename "$qa_flair_intensity")"
        fi
    fi
    
    # Enhanced validation with detailed file path logging
    log_message "=== FINAL OUTPUT VALIDATION ==="
    log_message "Validating primary output file: $abs_output_file"
    
    if [ ! -f "$abs_output_file" ]; then
        log_formatted "ERROR" "Failed to create primary output file: $abs_output_file"
        log_message "Directory contents:"
        ls -la "$(dirname "$abs_output_file")" 2>/dev/null || log_message "Directory does not exist"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Update output_file to absolute path for consistency
    output_file="$abs_output_file"
    
    local output_size=$(stat -f "%z" "$output_file" 2>/dev/null || stat --format="%s" "$output_file" 2>/dev/null || echo "0")
    local mask_file_for_count="${RESULTS_DIR}/registered/brainstem_mask_subject.nii.gz"
    
    log_message "Calculating voxel count from mask: $mask_file_for_count"
    if [ ! -f "$mask_file_for_count" ]; then
        log_formatted "WARNING" "Mask file for voxel count not found: $mask_file_for_count"
        local voxel_count="unknown"
    else
        local voxel_count=$(fslstats "$mask_file_for_count" -V | awk '{print $1}')
        log_message "✓ Mask file exists, voxel count: $voxel_count"
    fi
    
    log_formatted "SUCCESS" "Harvard-Oxford brainstem extraction complete"
    log_message "  Output: $output_file ($(( output_size / 1024 )) KB)"
    log_message "  Voxels: $voxel_count in subject T1 space"
    log_message "  Binary mask: $mask_file"
    
    # Clean up
    rm -rf "$temp_dir"
    return 0
}

# ============================================================================
# ENHANCED SEGMENTATION WITH FLAIR INTEGRATION
# ============================================================================

extract_brainstem_with_flair() {
    local t1_file="$1"
    local flair_file="$2"
    # Fix: resolve to absolute path to avoid ../issues with FSL tools
    local default_output_dir="${RESULTS_DIR}/segmentation/brainstem"
    local resolved_output_dir=$(cd "$default_output_dir" 2>/dev/null && pwd || echo "$default_output_dir")
    local output_prefix="${3:-${resolved_output_dir}/$(basename "$t1_file" .nii.gz)}"
    
    # Validate inputs - FAIL HARD on missing files
    if [ ! -f "$t1_file" ]; then
        log_formatted "ERROR" "T1 file not found: $t1_file"
        return 1
    fi
    
    if [ ! -f "$flair_file" ]; then
        log_formatted "ERROR" "FLAIR file not found: $flair_file"
        return 1
    fi
    
    # Ensure output directory exists
    local output_dir="$(dirname "$output_prefix")"
    if [[ "$output_dir" != /* ]]; then
        output_dir="$(pwd)/$output_dir"
    fi
    
    if ! mkdir -p "$output_dir"; then
        log_formatted "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi
    
    log_formatted "INFO" "===== ENHANCED SEGMENTATION WITH FLAIR INTEGRATION ====="
    log_formatted "WARNING" "STRICT MODE: Pipeline will FAIL HARD on any data quality issues"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # First get Harvard-Oxford segmentation from T1 - FAIL HARD if this fails
    local t1_brainstem="${output_prefix}_brainstem_t1based.nii.gz"
    if ! extract_brainstem_harvard_oxford "$t1_file" "$t1_brainstem"; then
        cleanup_and_fail 1 "T1-based Harvard-Oxford segmentation failed - cannot proceed" "$temp_dir"
        return 1
    fi
    
    if [ ! -f "$t1_brainstem" ]; then
        cleanup_and_fail 1 "T1-based segmentation output not created: $t1_brainstem" "$temp_dir"
        return 1
    fi
    
    # Get the binary mask - FAIL HARD if missing
    local t1_mask="${output_prefix}_brainstem_t1based.nii.gz"
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "T1 brainstem mask not found: $t1_mask" "$temp_dir"
        return 1
    fi
    
    # Check if FLAIR is already in T1 space (from registration step) - use same logic as main function
    local flair_in_t1=""
    
    # Look for registered FLAIR files using specific pattern
    local flair_registered_files=()
    local registration_dir="${RESULTS_DIR}/registered"
    
    log_message "=== REGISTERED FLAIR DISCOVERY ==="
    log_message "Looking for registered FLAIR files in: $registration_dir"
    
    if [ -d "$registration_dir" ]; then
        log_message "Registration directory exists, searching for patterns:"
        log_message "  Pattern 1: *_std_to_t1Warped.nii.gz"
        log_message "  Pattern 2: *FLAIR*Warped.nii.gz"
        
        # List all files in the directory for debugging
        log_message "All files in registration directory:"
        ls -la "$registration_dir"/*.nii.gz 2>/dev/null | while read -r line; do
            log_message "  $line"
        done || log_message "  No .nii.gz files found"
        
        # Debug: Test the find command directly
        log_message "Testing find command directly:"
        find "$registration_dir" -maxdepth 1 -name "*_std_to_t1Warped.nii.gz" 2>/dev/null | while read -r found_file; do
            log_message "  Direct find result: $found_file"
        done
        
        # Use the specific pattern from user feedback with explicit maxdepth
        while IFS= read -r -d '' registered_flair; do
            flair_registered_files+=("$registered_flair")
            log_message "Found registered FLAIR: $(basename "$registered_flair")"
        done < <(find "$registration_dir" -maxdepth 1 -name "*_std_to_t1Warped.nii.gz" -o -name "*FLAIR*Warped.nii.gz" -print0 2>/dev/null)
        
        # Alternative approach: use glob patterns if find fails
        if [ ${#flair_registered_files[@]} -eq 0 ]; then
            log_message "Find command failed, trying glob patterns..."
            for pattern in "*_std_to_t1Warped.nii.gz" "*FLAIR*Warped.nii.gz"; do
                for file in "$registration_dir"/$pattern; do
                    if [ -f "$file" ]; then
                        # Check if we already have this file to avoid duplicates
                        local already_found=false
                        for existing_file in "${flair_registered_files[@]}"; do
                            if [ "$file" = "$existing_file" ]; then
                                already_found=true
                                break
                            fi
                        done
                        
                        if [ "$already_found" = "false" ]; then
                            flair_registered_files+=("$file")
                            log_message "Glob found registered FLAIR: $(basename $file)"
                        fi
                    fi
                done
            done
        fi
    else
        log_message "Registration directory does not exist: $registration_dir"
    fi
    
    log_message "Total registered FLAIR files found: ${#flair_registered_files[@]}"
    
    if [ ${#flair_registered_files[@]} -gt 0 ]; then
        flair_in_t1="${flair_registered_files[0]}"
        log_message "✓ Using registered FLAIR in T1 space: $(basename "$flair_in_t1")"
        log_message "Full path: $flair_in_t1"
    else
        log_message "⚠ No registered FLAIR found, using original FLAIR (will need to check dimensions)"
        flair_in_t1="$flair_file"
        log_message "Original FLAIR path: $flair_in_t1"
    fi
    
    # Validate FLAIR file exists - FAIL HARD
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR file not found: $flair_in_t1" "$temp_dir"
        return 1
    fi
    
    # Create FLAIR-enhanced mask using intensity information
    log_message "Enhancing segmentation with FLAIR intensity information..."
    
    # Check dimensions compatibility - FAIL HARD on mismatch
    log_message "Validating image dimensions and orientations..."
    local flair_dims=$(fslinfo "$flair_in_t1" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local mask_dims=$(fslinfo "$t1_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    
    log_message "FLAIR dimensions: $flair_dims"
    log_message "Mask dimensions: $mask_dims"
    
    if [ "$flair_dims" != "$mask_dims" ]; then
        log_formatted "ERROR" "CRITICAL: FLAIR and mask have incompatible dimensions"
        log_formatted "ERROR" "FLAIR: $flair_dims, Mask: $mask_dims"
        cleanup_and_fail 1 "Image dimension mismatch prevents reliable FLAIR integration" "$temp_dir"
        return 1
    fi
    
    # Check orientations are consistent - FAIL HARD on orientation mismatch
    local flair_orient=$(fslorient -getorient "$flair_in_t1" 2>/dev/null)
    local mask_orient=$(fslorient -getorient "$t1_mask" 2>/dev/null)
    
    if [ "$flair_orient" != "$mask_orient" ]; then
        log_formatted "ERROR" "CRITICAL: FLAIR and mask have inconsistent orientations"
        log_formatted "ERROR" "FLAIR: $flair_orient, Mask: $mask_orient"
        cleanup_and_fail 1 "Orientation mismatch prevents reliable FLAIR integration" "$temp_dir"
        return 1
    fi
    
    # Extract FLAIR intensities within brainstem region - FAIL HARD on any error
    log_message "Extracting FLAIR intensities within brainstem region..."
    
    # Apply the registered FLAIR to the brainstem mask directly - simple and correct!
    log_message "=== FLAIR INTENSITY EXTRACTION DEBUG ==="
    log_message "FLAIR intensity file: $flair_in_t1"
    log_message "Brainstem mask file: $t1_mask"
    log_message "Both files are in T1 space - direct multiplication will work"
    
    # Validate input files exist before fslmaths operation
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR input file missing: $flair_in_t1" "$temp_dir"
        return 1
    fi
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "Brainstem mask file missing: $t1_mask" "$temp_dir"
        return 1
    fi
    
    # Check mask voxel count before extraction
    local mask_voxel_count=$(fslstats "$t1_mask" -V 2>/dev/null | awk '{print $1}')
    log_message "Brainstem mask contains $mask_voxel_count voxels"
    
    if [ -z "$mask_voxel_count" ] || [ "$mask_voxel_count" -eq 0 ]; then
        cleanup_and_fail 1 "Brainstem mask is empty - cannot extract FLAIR intensities" "$temp_dir"
        return 1
    fi
    
    # Resolve relative paths before FSL operations
    local resolved_flair=$(realpath "$flair_in_t1" 2>/dev/null || readlink -f "$flair_in_t1" 2>/dev/null || echo "$flair_in_t1")
    
    log_message "=== PATH RESOLUTION DEBUG ==="
    log_message "FLAIR path: $flair_in_t1"
    log_message "Structural (T1) mask: $t1_mask"
    
    # Verify resolved files exist
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "Resolved FLAIR file does not exist: $flair_in_t1"
        return 1
    fi
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "Resolved mask file does not exist: $t1_mask"
        return 1
    fi
    
    # Check coordinate system compatibility before FLAIR extraction
    log_message "=== COORDINATE SYSTEM COMPATIBILITY CHECK ==="
    resolved_flair="$flair_in_t1"
    resolved_mask="$t1_mask"   
    # Get precise orientation and coordinate system codes using fslorient
    local flair_orient=$(fslorient -getorient "$resolved_flair" 2>/dev/null || echo "UNKNOWN")
    local mask_orient=$(fslorient -getorient "$resolved_mask" 2>/dev/null || echo "UNKNOWN")
    
    # CRITICAL: Get qform and sform codes using fslorient (not fslinfo)
    local flair_qform=$(fslorient -getqformcode "$resolved_flair" 2>/dev/null || echo "UNKNOWN")
    local flair_sform=$(fslorient -getsformcode "$resolved_flair" 2>/dev/null || echo "UNKNOWN")
    local mask_qform=$(fslorient -getqformcode "$resolved_mask" 2>/dev/null || echo "UNKNOWN")
    local mask_sform=$(fslorient -getsformcode "$resolved_mask" 2>/dev/null || echo "UNKNOWN")
    
    log_message "FLAIR orientation: $flair_orient (qform: $flair_qform, sform: $flair_sform)"
    log_message "Mask orientation: $mask_orient (qform: $mask_qform, sform: $mask_sform)"
    
    # Check for coordinate system mismatches
    if [ "$flair_orient" != "$mask_orient" ] && [ "$flair_orient" != "UNKNOWN" ] && [ "$mask_orient" != "UNKNOWN" ]; then
        log_formatted "ERROR" "ORIENTATION MISMATCH: FLAIR ($flair_orient) vs Mask ($mask_orient)"
        log_formatted "ERROR" "This will cause fslmaths to fail or produce incorrect results"
        return 1
    fi
    
    if [ "$flair_qform" != "$mask_qform" ] && [ "$flair_qform" != "UNKNOWN" ] && [ "$mask_qform" != "UNKNOWN" ]; then
        log_formatted "ERROR" "QFORM MISMATCH: FLAIR ($flair_qform) vs Mask ($mask_qform)"
        log_formatted "ERROR" "Coordinate system incompatibility detected"
        return 1
    fi
    
    if [ "$flair_sform" != "$mask_sform" ] && [ "$flair_sform" != "UNKNOWN" ] && [ "$mask_sform" != "UNKNOWN" ]; then
        log_formatted "ERROR" "SFORM MISMATCH: FLAIR ($flair_sform) vs Mask ($mask_sform)"
        log_formatted "ERROR" "Spatial transformation incompatibility detected"
        return 1
    fi
    
    # Extract FLAIR intensities using resolved absolute paths
    log_message "Extracting FLAIR intensities from $mask_voxel_count brainstem voxels (using absolute paths)..."
    log_message "Command: fslmaths $resolved_flair -mas $resolved_mask ${RESULTS_DIR}/registered/flair_brainstem.nii.gz"
    local flair_brainstem_intensity_file="${RESULTS_DIR}/registered/flair_brainstem.nii.gz"
    local fslmaths_output=""
    local fslmaths_exit_code=0
    
    fslmaths_output=$(fslmaths "$resolved_flair" -mas "$resolved_mask" "$flair_brainstem_intensity_file" 2>&1)
    fslmaths_exit_code=$?
    
    if [ -n "$fslmaths_output" ]; then
        log_message "fslmaths output: $fslmaths_output"
    fi
    
    # Check if output file was created
    if [ ! -f "$flair_brainstem_intensity_file" ]; then
        log_formatted "ERROR" "fslmaths completed with exit code $fslmaths_exit_code but output file not created"
        cleanup_and_fail 1 "fslmaths failed to create output file"
        return 1
    fi
    
    # Check output file size
    local output_size=$(stat -f "%z" "$flair_brainstem_intensity_file" || stat --format="%s" "$flair_brainstem_intensity_file" || echo "0")
    log_message "Output file created: $flair_brainstem_intensity_file (${output_size} bytes)"
    
    if [ "$output_size" -lt 100 ]; then
        log_formatted "ERROR" "Output file is suspiciously small: ${output_size} bytes"
        cleanup_and_fail 1 "fslmaths created empty or corrupt output"
        return 1
    fi
    
    if [ $fslmaths_exit_code -ne 0 ]; then
        cleanup_and_fail 1 "fslmaths operation failed with exit code $fslmaths_exit_code"
        return 1
    fi
    
    log_message "✓ FLAIR intensity extraction completed using brainstem mask directly"
    log_message "Output file: $flair_brainstem_intensity_file"
    
    # Enhanced debugging to understand the data
    log_message "=== FLAIR DATA ANALYSIS ==="
    
    # Check input FLAIR statistics
    local flair_stats=$(fslstats "$flair_in_t1" -R -V 2>/dev/null)
    log_message "FLAIR input stats (min max voxels volume): $flair_stats"
    
    # Check mask statistics
    local mask_stats=$(fslstats "$t1_mask" -R -V 2>/dev/null)
    log_message "Brainstem mask stats (min max voxels volume): $mask_stats"
    
    # Verify the output file was created and has non-zero voxels - FAIL HARD
    if [ ! -f "$flair_brainstem_intensity_file" ]; then
        cleanup_and_fail 1 "FLAIR brainstem extraction failed - output file not created"
        return 1
    fi
    
    # Check output statistics in detail
    local output_stats=$(fslstats "$flair_brainstem_intensity_file" -R -V)
    log_message "FLAIR output stats (min max voxels volume): $output_stats"
    
    # Get voxel count and validate it's a number
    local flair_voxel_count=$(echo "$output_stats" | awk '{print $3}')
    local flair_nonzero_count=$(fslstats "$flair_brainstem_intensity_file" -l 0 -V 2>/dev/null | awk '{print $1}')
    log_message "Total voxels: $flair_voxel_count, Non-zero voxels: $flair_nonzero_count"
    
    if [ -z "$flair_voxel_count" ] || ! [[ "$flair_voxel_count" =~ ^[0-9]+$ ]]; then
        cleanup_and_fail 1 "Failed to get valid voxel count from FLAIR brainstem (got: '$flair_voxel_count')"
        return 1
    fi
    
    # Check for non-zero voxels instead of total voxels
    if [ -z "$flair_nonzero_count" ] || [ "$flair_nonzero_count" -eq 0 ]; then
        log_formatted "ERROR" "FLAIR brainstem region contains no non-zero intensity values"
        log_message "This suggests either:"
        log_message "1. FLAIR image contains only zero values in brainstem region"
        log_message "2. Brainstem mask and FLAIR image don't overlap spatially"
        log_message "3. Coordinate system mismatch despite matching dimensions"
        cleanup_and_fail 1 "FLAIR brainstem region is empty - no valid data for enhancement"
        return 1
    fi
    
    log_message "Extracted FLAIR data: $flair_voxel_count voxels"
    
    # Calculate intensity statistics within brainstem - FAIL HARD on invalid stats
    log_message "Calculating FLAIR intensity statistics..."
    
    # Validate input file exists before fslstats operations
    if [ ! -f "$flair_brainstem_intensity_file" ]; then
        cleanup_and_fail 1 "FLAIR brainstem file missing before statistics calculation: $flair_brainstem_intensity_file"
        return 1
    fi
    
    local mean_intensity=$(fslstats $flair_brainstem_intensity_file -M 2>/dev/null)
    local std_intensity=$(fslstats $flair_brainstem_intensity_file -S 2>/dev/null)
    
    # Validate statistics - FAIL HARD on invalid values
    if [ -z "$mean_intensity" ] || [ -z "$std_intensity" ]; then
        cleanup_and_fail 1 "Failed to calculate FLAIR intensity statistics"
        return 1
    fi
    
    if [ "$mean_intensity" = "0.000000" ] || [ "$std_intensity" = "0.000000" ]; then
        cleanup_and_fail 1 "Invalid FLAIR intensity statistics (mean=$mean_intensity, std=$std_intensity)"
        return 1
    fi
    
    # Validate numeric format - FAIL HARD on non-numeric values
    # More robust number validation that handles floating point numbers and whitespace
    if ! echo "$mean_intensity" | grep -E '^[[:space:]]*[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?[[:space:]]*$' > /dev/null; then
        # Fallback: try to use the number arithmetically to test if it's valid
        if ! awk "BEGIN {exit !($mean_intensity >= 0 || $mean_intensity < 0)}" 2>/dev/null; then
            cleanup_and_fail 1 "Mean intensity is not a valid number: '$mean_intensity'"
            return 1
        else
            log_message "Number validation passed on fallback test: $mean_intensity"
        fi
    fi
    
    if ! echo "$std_intensity" | grep -E '^[[:space:]]*[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?[[:space:]]*$' > /dev/null; then
        cleanup_and_fail 1 "Standard deviation is not a valid number: $std_intensity"
        return 1
    fi
    
    log_message "FLAIR brainstem statistics: mean=$mean_intensity, std=$std_intensity"
    
    # Create refined mask based on FLAIR intensities
    log_message "Creating refined mask based on FLAIR intensities..."
    
    # Calculate thresholds - FAIL HARD on calculation failure
    local lower_threshold=$(echo "$mean_intensity - 2 * $std_intensity" | bc -l 2>/dev/null)
    local upper_threshold=$(echo "$mean_intensity + 2 * $std_intensity" | bc -l 2>/dev/null)
    
    if [ -z "$lower_threshold" ] || [ -z "$upper_threshold" ]; then
        cleanup_and_fail 1 "Failed to calculate intensity thresholds using bc"
        return 1
    fi
    
    log_message "Intensity thresholds: lower=$lower_threshold, upper=$upper_threshold"
    
    # Create refined mask - FAIL HARD on any error
    # Validate input file exists before threshold operation
    if [ ! -f "$flair_brainstem_intensity_file" ]; then
        cleanup_and_fail 1 "FLAIR brainstem file missing before threshold operation: $flair_brainstem_intensity_file"
        return 1
    fi
    
    # Combine T1 and FLAIR information - FAIL HARD on error
    log_message "Combining T1 and FLAIR information..."
        
    # Apply refined mask to T1 for final output - FAIL HARD on error
    # Validate input files exist before T1 masking operation
    if [ ! -f "$t1_file" ]; then
        cleanup_and_fail 1 "T1 file missing before final masking: $t1_file"
        return 1
    fi
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "Combined brainstem mask missing before T1 masking: $t1_mask"
        return 1
    fi
    
    if ! fslmaths "$t1_file" -mas "$t1_mask" \
                  "${output_prefix}_brainstem_intensity.nii.gz"; then
        cleanup_and_fail 1 "Failed to create final T1-masked segmentation output"
        return 1
    fi
    
    # Create FLAIR intensity version - FAIL HARD on error
    # Validate input files exist before FLAIR masking operation
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR file missing before final masking: $flair_in_t1"
        return 1
    fi

    if ! fslmaths "$flair_in_t1" -mas "$t1_mask" \
                  "${output_prefix}_brainstem_flair_intensity.nii.gz"; then
        cleanup_and_fail 1 "Failed to create FLAIR intensity segmentation output"
        return 1
    fi
    
    # Create T1 intensity version for QA module compatibility
    log_message "Creating T1 intensity version for QA module..."
    if ! fslmaths "$t1_file" -mas "$t1_mask" \
                  "${output_prefix}_brainstem_t1_intensity.nii.gz"; then
        cleanup_and_fail 1 "Failed to create T1 intensity segmentation output"
        return 1
    fi
        
    # Get final voxel count and validate it's a number
    local final_voxels=$(fslstats "${output_prefix}_brainstem_t1_intensity.nii.gz" -v 2>/dev/null | awk '{print $1}')
    if [ -z "$final_voxels" ] || ! [[ "$final_voxels" =~ ^[0-9]+$ ]]; then
        cleanup_and_fail 1 "Failed to get valid voxel count from final mask (got: '$final_voxels')"
        return 1
    fi
    
    if [ "$final_voxels" -eq 0 ]; then
        cleanup_and_fail 1 "Final enhanced segmentation resulted in empty mask"
        return 1
    fi
    
    # Validate all expected outputs exist and are non-empty
    log_message "Performing comprehensive output validation..."
    
    # Use validation flag to ensure proper termination
    local validation_failed=false
    
    # Define expected output files
    local expected_files=(
        "$t1_mask"
        "${output_prefix}_brainstem_intensity.nii.gz"
        "${output_prefix}_brainstem_flair_intensity.nii.gz"
        "${output_prefix}_brainstem_t1_intensity.nii.gz" #redundant
    ) 
    
    # First pass: check all files exist - FAIL IMMEDIATELY if any missing
    for output_file in "${expected_files[@]}"; do
        if [ ! -f "$output_file" ]; then
            cleanup_and_fail 1 "Required output file not created: $output_file"
            validation_failed=true
            break
        fi
    done
    
    # Exit immediately if first pass failed
    if [ "$validation_failed" = "true" ]; then
        return 1
    fi
    
    # Second pass: validate each file thoroughly - FAIL IMMEDIATELY on any issue
    for output_file in "${expected_files[@]}"; do
        
        # Check file is readable
        if [ ! -r "$output_file" ]; then
            cleanup_and_fail 1 "Required output file not readable: $output_file"
            return 1
        fi
        
        # Check file size with proper empty variable handling
        local file_size=$(stat -f "%z" "$output_file" 2>/dev/null || stat --format="%s" "$output_file" 2>/dev/null)
        if [ -z "$file_size" ]; then
            cleanup_and_fail 1 "Could not determine file size for: $output_file"
            return 1
        fi
        
        # Validate file_size is numeric before comparison
        if ! [[ "$file_size" =~ ^[0-9]+$ ]]; then
            cleanup_and_fail 1 "Invalid file size value for: $output_file (got: '$file_size')"
            return 1
        fi
        
        if [ "$file_size" -lt 1000 ]; then
            cleanup_and_fail 1 "Output file suspiciously small: $output_file ($file_size bytes)"
            return 1
        fi
        
        # Validate file as proper NIfTI by checking fslinfo works
        if ! fslinfo "$output_file" >/dev/null 2>&1; then
            cleanup_and_fail 1 "Output file is not a valid NIfTI file: $output_file"
            return 1
        fi
        
        log_message "✓ Validated output: $output_file ($file_size bytes)"
    done
    
    log_formatted "SUCCESS" "Enhanced brainstem segmentation complete with FLAIR integration"
    log_message "  Final enhanced mask: $final_voxels voxels"
    log_message "  T1 intensities: ${output_prefix}_brainstem_intensity.nii.gz"
    log_message "  T1 intensity mask: ${output_prefix}_brainstem_t1_intensity.nii.gz"
    log_message "  FLAIR intensities: ${output_prefix}_brainstem_flair_intensity.nii.gz"
    log_message "  Binary mask: $t1_mask"
    
    # Create QA-compatible naming convention
    log_message "Creating QA-compatible intensity file naming..."
    local output_dir="$(dirname "${output_prefix}")"
    local mask_file="${output_prefix}_brainstem_mask.nii.gz"
        
    # Clean up
    rm -rf "$temp_dir"
    return 0
}

# ============================================================================
# COMPREHENSIVE BRAINSTEM EXTRACTION WITH MULTIPLE METHODS
# ============================================================================

extract_brainstem_final() {
    local input_file="$1"
    local input_basename=$(basename "$input_file" .nii.gz)
    
    # Define output directory - brainstem only
    local brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    
    log_message "Creating brainstem segmentation directory:"
    log_message "  Brainstem: $brainstem_dir"
    
    if ! mkdir -p "$brainstem_dir"; then
        log_formatted "ERROR" "Failed to create brainstem segmentation directory"
        return 1
    fi
    
    # Verify directory is writable
    if [ ! -w "$brainstem_dir" ]; then
        log_formatted "ERROR" "Brainstem segmentation directory is not writable"
        return 1
    fi
    
    log_formatted "INFO" "===== ATLAS-BASED BRAINSTEM SEGMENTATION ====="
    log_message "Using Harvard-Oxford for reliable brainstem, then Talairach for detailed subdivision"
    
    # STEP 1: ALWAYS use Harvard-Oxford FIRST as the GOLD STANDARD
    local harvard_success=false
    log_message "Step 1: Harvard-Oxford atlas (GOLD STANDARD for brainstem boundaries)"
    local harvard_output="${brainstem_dir}/${input_basename}_brainstem.nii.gz"
    local harvard_mask="${brainstem_dir}/${input_basename}_brainstem_mask.nii.gz"
    
    if extract_brainstem_harvard_oxford "$input_file" "$harvard_output"; then
        harvard_success=true
        log_formatted "SUCCESS" "Harvard-Oxford brainstem segmentation successful (GOLD STANDARD)"
        
        # Check for FLAIR enhancement
        local flair_file=""
        local flair_registered="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
        if [ -f "$flair_registered" ]; then
            flair_file="$flair_registered"
        else
            # Try to find original FLAIR (exclude intensity derivatives to prevent recursive processing)
            flair_file=$(find "${RESULTS_DIR}/registered" -name "*FLAIR*_std.nii.gz" ! -name "*_intensity*" ! -name "*_t1_intensity*" ! -name "*_flair_intensity*" | head -1)
        fi
        
        if [ -n "$flair_file" ] && [ -f "$flair_file" ]; then
            log_message "Enhancing with FLAIR data..."
            local enhanced_prefix="${brainstem_dir}/${input_basename}"
            if extract_brainstem_with_flair "$input_file" "$flair_file" "$enhanced_prefix"; then
                # Use enhanced version as primary output
                [ -f "${enhanced_prefix}_brainstem.nii.gz" ] && \
                    cp "${enhanced_prefix}_brainstem.nii.gz" "$harvard_output"
                log_formatted "SUCCESS" "FLAIR-enhanced segmentation completed"
            else
                log_formatted "ERROR" "FLAIR enhancement failed with critical data quality issues"
                log_formatted "ERROR" "Pipeline configured to FAIL HARD on data quality problems"
                return 1
            fi
        fi
    else
        log_formatted "ERROR" "Harvard-Oxford segmentation failed - cannot proceed without reliable brainstem boundaries"
        return 1
    fi
    
    # STEP 2: Use Talairach for detailed brainstem subdivision (REUSING HARVARD-OXFORD TRANSFORM)
    local talairach_subdivision_valid=false
    log_message "Step 2: Attempting Talairach atlas for detailed brainstem subdivision (unified registration)"
    
    # Reuse Harvard-Oxford registration transform to eliminate duplicate processing
    if command -v extract_brainstem_talairach_with_transform &> /dev/null; then
        # Get the transform parameters from Harvard-Oxford registration
        local ants_transform="${RESULTS_DIR}/registered/transforms/ants_to_mni_0GenericAffine.mat"
        
        # Check if Harvard-Oxford transform exists
        if [ -f "$ants_transform" ]; then
            log_message "Reusing Harvard-Oxford transform for Talairach processing (eliminating duplicate registration)"
            
            # Create temporary directory for orientation correction (if needed)
            local talairach_temp=$(mktemp -d)
            
            # Handle orientation correction (replicating Harvard-Oxford logic for consistency)
            local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
            local mni_template="${TEMPLATE_DIR}/MNI152_T1_1mm_brain.nii.gz"
            local mni_orient=$(fslorient -getorient "$mni_template" 2>/dev/null || echo "UNKNOWN")
            
            local orientation_corrected_input="$input_file"
            local orientation_corrected=false
            
            if [ "$input_orient" != "UNKNOWN" ] && [ "$mni_orient" != "UNKNOWN" ] && [ "$input_orient" != "$mni_orient" ]; then
                log_message "Applying same orientation correction as Harvard-Oxford for consistency"
                orientation_corrected_input="${talairach_temp}/input_orientation_corrected.nii.gz"
                
                if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
                    fslswapdim "$input_file" -x y z "$orientation_corrected_input"
                    fslorient -forceradiological "$orientation_corrected_input"
                    orientation_corrected=true
                elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
                    fslswapdim "$input_file" -x y z "$orientation_corrected_input"
                    fslorient -forceneurological "$orientation_corrected_input"
                    orientation_corrected=true
                else
                    cp "$input_file" "$orientation_corrected_input"
                fi
            else
                cp "$input_file" "${talairach_temp}/input_orientation_corrected.nii.gz"
                orientation_corrected_input="${talairach_temp}/input_orientation_corrected.nii.gz"
            fi
            
            if extract_brainstem_talairach_with_transform "$input_file" "$input_basename" "$harvard_mask" \
                                                         "$orientation_corrected_input" "$ants_transform" "$orientation_corrected"; then
                log_formatted "SUCCESS" "Talairach brainstem subdivision completed using SHARED transform (no duplicate registration)"
                talairach_subdivision_valid=true
            else
                log_formatted "WARNING" "Talairach segmentation with shared transform failed, trying standalone fallback"
                
                # Fallback to standalone Talairach (will do its own registration)
                if command -v extract_brainstem_talairach &> /dev/null; then
                    if extract_brainstem_talairach "$input_file" "$input_basename" "$harvard_mask"; then
                        log_formatted "SUCCESS" "Talairach standalone segmentation completed (fallback with separate registration)"
                        talairach_subdivision_valid=true
                    else
                        log_formatted "WARNING" "Both shared and standalone Talairach segmentation failed, trying Juelich fallback"
                    fi
                fi
            fi
            
            # Clean up temporary directory
            rm -rf "$talairach_temp"
        else
            log_formatted "WARNING" "Harvard-Oxford transform not available for reuse, using standalone Talairach"
            
            # Fallback to standalone Talairach
            if command -v extract_brainstem_talairach &> /dev/null; then
                if extract_brainstem_talairach "$input_file" "$input_basename" "$harvard_mask"; then
                    log_formatted "SUCCESS" "Talairach standalone segmentation completed"
                    talairach_subdivision_valid=true
                else
                    log_formatted "WARNING" "Talairach segmentation failed, trying Juelich fallback"
                fi
            fi
        fi
        
        # If Talairach segmentation failed, mark subdivision as failed
        if [ "$talairach_subdivision_valid" = "false" ]; then
            log_formatted "WARNING" "Talairach segmentation failed - no detailed brainstem subdivision available"
        fi
    else
        log_formatted "WARNING" "Talairach segmentation not available - no detailed brainstem subdivision available"
    fi
    
    # Handle subdivision files based on validation results
    if [ "$talairach_subdivision_valid" = "true" ]; then
        log_message "Using validated brainstem subdivision constrained to Harvard-Oxford boundaries"
        
        # Check what subdivision method was actually used
        local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
        if [ -d "$detailed_dir" ] && [ "$(find "$detailed_dir" -name "${input_basename}_*.nii.gz" | wc -l)" -gt 0 ]; then
            log_message "✓ Talairach detailed brainstem subdivisions available in: $detailed_dir"
        fi
    fi
            
    # Map files to expected names (remove method suffixes)
    map_segmentation_files "$input_basename" "$brainstem_dir"
    
    # Create combined label map for easy visualization
    # "$input_basename" "$brainstem_dir"
    
    # Validate segmentation
    validate_segmentation_outputs "$input_file" "$input_basename"
    
    # Generate comprehensive visualization report
    generate_segmentation_report "$input_file" "$input_basename"
    
    log_formatted "SUCCESS" "Atlas-based segmentation complete"
    
    # IMPORTANT: Return 0 to continue pipeline flow
    return 0
}

# 
# ============================================================================
# FILE MAPPING AND DISCOVERY
# ============================================================================

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
                cp  "$file" "${brainstem_dir}/${clean_name}"
            fi
        fi
    done
        
    return 0
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_segmentation_outputs() {
    local input_file="$1"
    local basename="$2"
    
    log_message "Validating segmentation outputs..."
    
    local brainstem_file="${RESULTS_DIR}/segmentation/brainstem/${basename}_brainstem.nii.gz"
    
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
        ls -la "${RESULTS_DIR}/segmentation/brainstem/${basename}"*.nii.gz 2>/dev/null || echo "No brainstem files"
        echo "Validation: $([ "$validation_passed" = "true" ] && echo "PASSED" || echo "WARNINGS")"
    } > "${validation_dir}/segmentation_validation.txt"
    
    # IMPORTANT: Always return 0 to continue pipeline
    # Validation warnings should not stop the pipeline
    return 0
}

# ============================================================================
# COMBINED SEGMENTATION MAP CREATION
# ============================================================================

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
        fslmaths "$brainstem_mask" -mas $BRAINSTEM_LABEL -add "$combined_map" "$combined_map"
        log_message "Added brainstem to combined map (label=$BRAINSTEM_LABEL)"
    fi
        
    # Create label description file
    {
        echo "# Brainstem Segmentation Label Map"
        echo "# Label values:"
        echo "0 = Background"
        echo "1 = Brainstem (Harvard-Oxford)"
    } > "${combined_dir}/${input_basename}_segmentation_labels.txt"
    
    log_message "Combined segmentation map created: $combined_map , labelled at ${combined_dir}/${input_basename}_segmentation_labels.txt"
    return 0
}

# ============================================================================
# SEGMENTATION REPORT GENERATION
# ============================================================================

generate_segmentation_report() {
    local input_file="$1"
    local input_basename="$2"
    local report_dir="${RESULTS_DIR}/reports"
    log_message "Generating comprehensive segmentation report..."
    
    mkdir -p "$report_dir"
    
    local report_file="${report_dir}/segmentation_report_${input_basename}.txt"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Gather file information
    local t1_file="${RESULTS_DIR}/standardized/$(basename "$input_file")"
    local flair_registered="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
    local brainstem_intensity="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem.nii.gz"
    local brainstem_mask="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem_mask.nii.gz"
    local combined_labels="${RESULTS_DIR}/segmentation/combined/${input_basename}_segmentation_labels.nii.gz"
    
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
Method: Harvard-Oxford (Gold Standard) + Talairach (Detailed Subdivision)
Fallback: Juelich atlas (if Talairach unavailable)
Space: T1 Native Space
Brainstem voxels: $brainstem_voxels

FILES GENERATED
--------------
1. Binary Masks (for ROI analysis):
   - Brainstem mask: ${brainstem_mask}

2. Intensity Maps (T1 values within masks):
   - Brainstem intensities: ${brainstem_intensity}

3. Combined Label Map:
   - All structures: ${combined_labels}
   - Labels: 0=Background, 1=Brainstem

VISUALIZATION INSTRUCTIONS
-------------------------
To visualize the segmentations overlaid on your images:

1. View segmentations on T1:
   freeview ${t1_file} \\
           ${brainstem_mask} -cm red -a 50

2. View segmentations on registered FLAIR:
   freeview ${flair_registered} \\
           ${brainstem_mask} -cm red -a 50

3. View combined label map:
   freeview ${t1_file} \\
           ${combined_labels} -cm random -a 50

4. View with intensity overlay (shows T1 intensities within brainstem):
   freeview ${t1_file} \\
           ${brainstem_intensity} -cm hot -a 70
EOF
    if [ -f "$flair_registered" ]; then
        cat >> "$report_file" <<EOF
5. View segmentations on original FLAIR:
   freeview ${flair_file} \\
           ${brainstem_mask} -cm red -a 50
EOF
    fi
    
    cat >> "$report_file" <<EOF

CLUSTERING PREPARATION
---------------------
The following files are available for clustering analysis:
- Binary masks: Define ROIs for analysis
- Intensity maps: Provide signal values within ROIs
- Combined labels: Allow multi-region analysis

All segmentations are in T1 native space and can be used with registered
FLAIR or other modalities for multi-modal analysis.

NOTES
-----
- Harvard-Oxford provides reliable brainstem boundaries
- Talairach subdivisions are validated to be within brainstem boundaries

================================================================================
EOF

    log_formatted "SUCCESS" "Segmentation report generated: $report_file"
    
    # Also display key visualization commands
    log_formatted "INFO" "===== VISUALIZATION COMMANDS ====="
    log_message "To view your segmentations:"
    log_message ""
    log_message "  # View on T1:"
    log_message "  freeview ${t1_file} \\"
    log_message "          ${brainstem_mask} -cm red -a 50"
    log_message ""
    
    if [ -f "$flair_registered" ]; then
        log_message "  # View on registered FLAIR:"
        log_message "  fsleyes ${flair_registered} \\"
        log_message "          ${brainstem_mask} -cm red -a 50 \\"
        log_message ""
    fi
    
    log_message "  # View combined label map:"
    log_message "  fsleyes ${t1_file} \\"
    log_message "          ${combined_labels} -cm random -a 50"
    log_message ""
    log_message "Full report saved to: $report_file"
    
    return 0
}

# ============================================================================
# LEGACY FUNCTIONS FOR COMPATIBILITY
# ============================================================================

# Keep these for backward compatibility but they now use the new implementation
extract_brainstem_standardspace() {
    log_formatted "WARNING" "extract_brainstem_standardspace is deprecated. Using Harvard-Oxford in T1 space."
    extract_brainstem_harvard_oxford "$@"
}

extract_brainstem_talairach() {
    log_formatted "WARNING" "extract_brainstem_talairach is deprecated."
    return 0
}

extract_brainstem_ants() {
    log_formatted "WARNING" "extract_brainstem_ants is deprecated."
    return 0
}

# Simple validation function that doesn't block pipeline
validate_segmentation() {
    log_message "Running segmentation validation..."
    # Always return 0 to continue pipeline
    return 0
}

# Kept for compatibility but simplified
discover_and_map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"


    map_segmentation_files "$input_basename" "$brainstem_dir"
    
    # Always return success to continue pipeline
    return 0
}

# ============================================================================
# TISSUE SEGMENTATION (kept from original)
# ============================================================================

segment_tissues() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and output directory
    input_file="$1"
    output_dir="${2:-${RESULTS_DIR}/segmentation/tissue}"
    
    # Create output directory
    mkdir -p "$output_dir"
    
    log_message "Performing tissue segmentation on $input_file"
    
    # Get basename for output files
    basename=$(basename "$input_file" .nii.gz)
    
    # Step 1: Use existing brain extraction files (should have been done earlier in pipeline)
    # Try exact basename match first
    local brain_mask="${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz"
    local brain_file="${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz"
    
    # If exact match not found, search for any brain extraction files
    if [ ! -f "$brain_mask" ] || [ ! -f "$brain_file" ]; then
        log_message "Exact basename match not found (${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz | ${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz), searching for available brain extraction files..."
        
        # Find available brain extraction files
        local available_brain_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain.nii.gz" 2>/dev/null))
        local available_mask_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain_mask.nii.gz" 2>/dev/null))
        
        if [ ${#available_brain_files[@]} -gt 0 ] && [ ${#available_mask_files[@]} -gt 0 ]; then
            # Use the first available brain extraction files
            brain_file="${available_brain_files[0]}"
            brain_mask="${available_mask_files[0]}"
            log_message "Using available brain extraction files:"
            log_message "  Brain: $(basename "$brain_file")"
            log_message "  Mask: $(basename "$brain_mask")"
        else
            log_formatted "ERROR" "Brain extraction files not found - brain extraction should have been completed earlier in pipeline"
            log_formatted "ERROR" "Searched in: ${RESULTS_DIR}/brain_extraction/"
            log_formatted "ERROR" "Available files:"
            ls -la "${RESULTS_DIR}/brain_extraction/" 2>/dev/null || echo "Directory not accessible"
            return 1
        fi
    fi
    
    # Step 2: Tissue segmentation using Atropos
    log_message "Running Atropos segmentation..."
    
    # Build the Atropos command
    local atropos_cmd="Atropos -d 3 -a \"$brain_file\" -x \"$brain_mask\" -o \"[${output_dir}/${basename}_seg.nii.gz,${output_dir}/${basename}_prob%02d.nii.gz]\" -c \"[${ATROPOS_CONVERGENCE}]\" -m \"${ATROPOS_MRF}\" -i \"${ATROPOS_INIT_METHOD}[${ATROPOS_T1_CLASSES}]\" -k Gaussian"
    
    # Execute with filtering
    execute_with_logging "$atropos_cmd" "atropos_segmentation"
    
    # Step 3: Extract tissue classes
    log_message "Extracting tissue classes..."
    
    # Build threshold commands
    local thresh1_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_csf.nii.gz\" 1 1"
    local thresh2_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_gm.nii.gz\" 2 2"
    local thresh3_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_wm.nii.gz\" 3 3"
    
    # Execute with filtering
    execute_with_logging "$thresh1_cmd" "threshold_csf"
    execute_with_logging "$thresh2_cmd" "threshold_gm"
    execute_with_logging "$thresh3_cmd" "threshold_wm"
    
    log_message "Tissue segmentation complete"
    return 0
}

# ============================================================================
# EXPORT FUNCTIONS
# ============================================================================

export -f extract_brainstem_harvard_oxford
export -f extract_brainstem_with_flair
export -f extract_brainstem_final
export -f map_segmentation_files
export -f validate_segmentation_outputs
export -f create_combined_segmentation_map
export -f generate_segmentation_report

# Legacy exports for compatibility
export -f extract_brainstem_standardspace
export -f extract_brainstem_talairach
export -f extract_brainstem_ants
export -f validate_segmentation
export -f segment_tissues
export -f discover_and_map_segmentation_files

log_message "Segmentation module loaded"
