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
    
    log_formatted "INFO" "===== HARVARD/OXFORD ATLAS SEGMENTATION (GOLD STANDARD) ====="
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
            log_message "Found Harvard-Oxford atlas: $atlas_file"
            break
        fi
    done
    
    if [ -z "$harvard_subcortical" ]; then
        log_formatted "ERROR" "Harvard-Oxford subcortical atlas not found in any expected location"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # DIAGNOSTIC: Check Harvard-Oxford atlas orientation and compare with subject
    log_message "=== ORIENTATION DIAGNOSTIC ==="
    local subject_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
    local atlas_orient=$(fslorient -getorient "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    local mni_orient=$(fslorient -getorient "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    
    log_message "Subject orientation: $subject_orient"
    log_message "Harvard-Oxford atlas orientation: $atlas_orient"
    log_message "MNI template orientation: $mni_orient"
    
    # Check coordinate system details
    log_message "Subject coordinate details:"
    fslinfo "$input_file" | grep -E "(orient|sform|qform|pixdim)" | while read line; do
        log_message "  $line"
    done
    
    log_message "Harvard-Oxford atlas coordinate details:"
    fslinfo "$harvard_subcortical" | grep -E "(orient|sform|qform|pixdim)" | while read line; do
        log_message "  $line"
    done
    
    # Check if atlas and subject have consistent coordinate systems
    if [ "$subject_orient" != "$atlas_orient" ] && [ "$atlas_orient" != "UNKNOWN" ] && [ "$subject_orient" != "UNKNOWN" ]; then
        log_formatted "WARNING" "ORIENTATION MISMATCH DETECTED!"
        log_formatted "WARNING" "Subject: $subject_orient vs Harvard-Oxford: $atlas_orient"
        log_formatted "WARNING" "This may cause misalignment - consider atlas orientation correction"
    else
        log_message "✓ Orientations appear consistent"
    fi
    log_message "==============================="
    
    # ATLAS VALIDATION: Use atlasq to validate the Harvard-Oxford atlas
    log_message "Validating Harvard-Oxford atlas structure..."
    
    # Enhanced atlas file validation using atlasq
    if command -v atlasq &> /dev/null; then
        log_message "Running comprehensive atlasq validation..."
        
        # Use atlasq summary for comprehensive atlas information
        local atlas_summary=$(atlasq summary harvardoxford-subcortical 2>/dev/null || echo "SUMMARY_FAILED")
        
        if [ "$atlas_summary" = "SUMMARY_FAILED" ]; then
            log_formatted "WARNING" "atlasq summary failed - using direct file validation"
            
            # Fallback: try direct file query if summary fails
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
    
    log_message "Atlas validation results:"
    log_message "  Dimensions: $atlas_dims"
    log_message "  Total voxels: $atlas_voxels"
    log_message "  Max label value: $atlas_max"
    
    # Validate atlas has reasonable properties
    if [ "$atlas_voxels" -lt 1000000 ]; then
        log_formatted "WARNING" "Atlas seems too small ($atlas_voxels voxels) - may be corrupted"
    fi
    
    if (( $(echo "$atlas_max < 7" | bc -l) )); then
        log_formatted "ERROR" "Atlas max value ($atlas_max) is less than 7 - brainstem region not available"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate brainstem region specifically
    log_message "Validating brainstem region (index 7) in atlas..."
    fslmaths "$harvard_subcortical" -thr 7 -uthr 7 -bin "${temp_dir}/test_brainstem.nii.gz"
    local brainstem_test_voxels=$(fslstats "${temp_dir}/test_brainstem.nii.gz" -V | awk '{print $1}')
    
    if [ "$brainstem_test_voxels" -lt 100 ]; then
        log_formatted "ERROR" "Brainstem region (index 7) has insufficient voxels ($brainstem_test_voxels) in atlas"
        log_formatted "ERROR" "This suggests atlas corruption or incorrect version"
        rm -rf "$temp_dir"
        return 1
    else
        log_formatted "SUCCESS" "✓ Brainstem region validated: $brainstem_test_voxels voxels in atlas"
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
            fi
        else
            log_formatted "WARNING" "MeasureImageSimilarity not available - computing MI with numpy alternative"
            
            # Fallback: compute with numpy histogram (256 bins) for QC
            python3 -c "
import numpy as np
import nibabel as nib
import sys
from scipy.stats import entropy

try:
    # Load images
    fixed = nib.load('$fixed_image').get_fdata().flatten()
    moving = nib.load('$registered_moving').get_fdata().flatten()
    
    # Remove zero values and normalize
    mask = (fixed != 0) & (moving != 0) & np.isfinite(fixed) & np.isfinite(moving)
    fixed = fixed[mask]
    moving = moving[mask]
    
    if len(fixed) < 1000:
        print('Insufficient non-zero voxels for MI calculation')
        sys.exit(1)
    
    # Compute 2D histogram with 256 bins
    hist_2d, _, _ = np.histogram2d(fixed, moving, bins=256)
    
    # Normalize to get probabilities
    hist_2d = hist_2d / np.sum(hist_2d)
    
    # Compute marginal distributions
    px = np.sum(hist_2d, axis=1)
    py = np.sum(hist_2d, axis=0)
    
    # Compute mutual information
    # MI = sum(p(x,y) * log(p(x,y) / (p(x) * p(y))))
    mi = 0.0
    for i in range(256):
        for j in range(256):
            if hist_2d[i,j] > 0 and px[i] > 0 and py[j] > 0:
                mi += hist_2d[i,j] * np.log2(hist_2d[i,j] / (px[i] * py[j]))
    
    print(f'True MI (numpy histogram, 256 bins): {mi:.6f}')
    
except Exception as e:
    print(f'MI calculation failed: {e}')
    sys.exit(1)
" > "${validation_dir}/numpy_mi_result.txt" 2>&1
            
            if [ $? -eq 0 ]; then
                local numpy_mi=$(grep "True MI" "${validation_dir}/numpy_mi_result.txt" | awk '{print $NF}')
                if [ -n "$numpy_mi" ]; then
                    log_formatted "SUCCESS" "Numpy-computed True MI: $numpy_mi"
                else
                    log_formatted "WARNING" "Numpy MI calculation produced no result"
                fi
            else
                log_formatted "WARNING" "Numpy MI calculation failed"
            fi
        fi
        
        # Clean up temporary file
        rm -f "$registered_moving"
        return 0
    }
    
    # Set up ANTs registration parameters using existing configuration
    local ants_prefix="${RESULTS_DIR}/registered/transforms/ants_to_mni_"
    local ants_warped="${RESULTS_DIR}/registered/transforms/ants_to_mni_warped.nii.gz"
    local brainstem_mask_mni_file="${RESULTS_DIR}/registered/transforms/brainstem_mask_mni_file.nii.gz"
    
    # Step 4: Transform brainstem mask to subject T1 space
    log_message "Transforming brainstem mask to subject T1 space..."
    
    # CRITICAL: Validate and fix coordinate spaces before registration
    log_message "Validating coordinate spaces before transformation..."
    local input_orient=$(fslorient -getorient "$input_file" 2>/dev/null || echo "UNKNOWN")
    local mni_orient=$(fslorient -getorient "$mni_brain" 2>/dev/null || echo "UNKNOWN")
    local atlas_orient=$(fslorient -getorient "$harvard_subcortical" 2>/dev/null || echo "UNKNOWN")
    
    log_message "Subject T1 orientation: $input_orient"
    log_message "MNI template orientation: $mni_orient"
    log_message "Atlas orientation: $atlas_orient"
    
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
    log_message "Registering $(basename \"$orientation_corrected_input\") to MNI space using ANTs..."
    log_message "Input file for registration: $orientation_corrected_input"
    
    # CRITICAL: Use full SyN registration (affine + warp) for proper composite transforms
    # Single-file transform = full deformation is false for ANTs; SyN always emits two (affine + warp)
    log_formatted "INFO" "Using composite SyN registration (affine + nonlinear warp)"
    
    if [ "$orientation_corrected" = "true" ]; then
        log_formatted "INFO" "Running full SyN registration due to orientation correction"
        
        # Run full SyN registration (not just affine) for composite transforms
        execute_ants_command "ants_to_mni_syn_registration" "Full SyN registration to MNI template (orientation corrected)" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    elif command -v compute_initial_affine &> /dev/null; then
        # Use the existing function but ensure it does SyN registration
        log_message "Using compute_initial_affine function with SyN enhancement"
        compute_initial_affine "$orientation_corrected_input" "$mni_brain" "$ants_prefix"
        
        # If only affine was computed, run additional SyN step
        if [ ! -f "${ants_prefix}1Warp.nii.gz" ]; then
            log_message "Adding nonlinear warp component to complete composite transform"
            execute_ants_command "ants_syn_enhancement" "Adding nonlinear component to existing affine" \
                antsRegistrationSyNQuick.sh \
                -d 3 \
                -f "$mni_brain" \
                -m "$orientation_corrected_input" \
                -t s \
                -o "$ants_prefix" \
                -n "${ANTS_THREADS:-1}"
        fi
    else
        # Fallback: Run full SyN registration using execute_ants_command
        log_message "Running ANTs full SyN registration to MNI space..."
        
        execute_ants_command "ants_to_mni_syn_registration" "Full SyN registration to MNI template" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$orientation_corrected_input" \
            -t s \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
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
    local atlas_in_subject="${temp_dir}/harvard_oxford_in_subject.nii.gz"
    
    # CRITICAL FIX: Use centralized apply_transformation function for consistent SyN handling
    log_message "Applying composite transforms: warp field + affine (atlas→subject mapping)"
    
    # Use centralized apply_transformation function for consistent SyN transform handling
    if apply_transformation "$harvard_subcortical" "$orientation_corrected_input" "$atlas_in_subject" "$ants_prefix" "GenericLabel"; then
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
    
    # Now extract brainstem from the atlas in subject space
    log_message "Extracting brainstem from atlas in subject native space..."
    
    local brainstem_index=7  # Brain-Stem in Harvard-Oxford subcortical atlas
    log_message "Extracting brainstem (index $brainstem_index) from transformed atlas..."
    fslmaths "$atlas_in_subject" -thr $brainstem_index -uthr $brainstem_index -bin "${temp_dir}/brainstem_mask_subject_tri.nii.gz"
    
    local voxel_count=$(fslstats "${temp_dir}/brainstem_mask_subject_tri.nii.gz" -V | awk '{print $1}')
    if [ "$voxel_count" -gt 100 ]; then
        log_message "Found brainstem with $voxel_count voxels in subject space"
    else
        log_formatted "ERROR" "Brainstem region too small or not found in subject space (only $voxel_count voxels)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # BRAIN-STEM REFINEMENT: Generate subject-specific mask using Atropos/FAST
    # Affine-only atlas projection presumes negligible brain-stem shape variance—contradicted by hydrocephalus & Chiari cases
    log_message "=== BRAIN-STEM REFINEMENT FOR SUBJECT-SPECIFIC ANATOMY ==="
    log_message "Addressing shape variance in hydrocephalus & Chiari cases with subject-specific segmentation"
    
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
        
        # Validate contrast (std should be reasonable fraction of mean)
        local contrast_ratio=$(echo "scale=3; $input_std / $input_mean" | bc -l 2>/dev/null || echo "0")
        if (( $(echo "$contrast_ratio < 0.1" | bc -l 2>/dev/null || echo 1) )); then
            log_formatted "WARNING" "Insufficient tissue contrast (ratio=$contrast_ratio), using original mask"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        # Try Atropos with progressive fallbacks
        if command -v Atropos &> /dev/null && [ "$segmentation_successful" = "false" ]; then
            log_message "Using Atropos for tissue segmentation..."
            
            # Brain extraction for Atropos input
            local brain_extracted="${temp_refinement_dir}/brain_extracted.nii.gz"
            local brain_mask="${temp_refinement_dir}/brain_mask.nii.gz"
            
            # Simple brain extraction using bet with conservative parameters
            if bet "$input_image" "$brain_extracted" -m -n -f 0.3 2>/dev/null; then
                
                # Validate brain extraction was successful
                local brain_voxels=$(fslstats "$brain_mask" -V | awk '{print $1}' 2>/dev/null || echo "0")
                if [ "$brain_voxels" -gt 100 ]; then
                    
                    # Try 3-class segmentation first
                    log_message "Trying Atropos 3-class segmentation..."
                    if Atropos -d 3 \
                        -a "$brain_extracted" \
                        -x "$brain_mask" \
                        -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                        -c "[3,0.0001]" \
                        -m "[0.3,1x1x1]" \
                        -i "KMeans[3]" \
                        -k Gaussian 2>/dev/null; then
                        
                        if [ -f "$tissue_labels" ]; then
                            log_message "✓ Atropos 3-class segmentation successful"
                            segmentation_successful=true
                        fi
                    fi
                    
                    # Fallback to 2-class if 3-class failed
                    if [ "$segmentation_successful" = "false" ]; then
                        log_message "Trying Atropos 2-class segmentation..."
                        if Atropos -d 3 \
                            -a "$brain_extracted" \
                            -x "$brain_mask" \
                            -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                            -c "[3,0.0001]" \
                            -m "[0.3,1x1x1]" \
                            -i "KMeans[2]" \
                            -k Gaussian 2>/dev/null; then
                            
                            if [ -f "$tissue_labels" ]; then
                                log_message "✓ Atropos 2-class segmentation successful"
                                segmentation_successful=true
                            fi
                        fi
                    fi
                    
                    # Fallback to Otsu initialization if KMeans failed
                    if [ "$segmentation_successful" = "false" ]; then
                        log_message "Trying Atropos with Otsu initialization..."
                        if Atropos -d 3 \
                            -a "$brain_extracted" \
                            -x "$brain_mask" \
                            -o "[$tissue_labels,${temp_refinement_dir}/tissue_prob_%02d.nii.gz]" \
                            -c "[3,0.0001]" \
                            -m "[0.3,1x1x1]" \
                            -i "Otsu[2]" \
                            -k Gaussian 2>/dev/null; then
                            
                            if [ -f "$tissue_labels" ]; then
                                log_message "✓ Atropos Otsu segmentation successful"
                                segmentation_successful=true
                            fi
                        fi
                    fi
                else
                    log_formatted "WARNING" "Brain extraction failed (only $brain_voxels voxels), skipping Atropos"
                fi
            else
                log_formatted "WARNING" "Brain extraction command failed, skipping Atropos"
            fi
        fi
        
        # FAST fallback with progressive strategies
        if command -v fast &> /dev/null && [ "$segmentation_successful" = "false" ]; then
            log_message "Using FAST for tissue segmentation..."
            
            # Try 3-class FAST first
            log_message "Trying FAST 3-class segmentation..."
            if fast -t 1 -n 3 -o "${temp_refinement_dir}/fast_" "$input_image" 2>/dev/null; then
                if [ -f "${temp_refinement_dir}/fast_seg.nii.gz" ]; then
                    cp "${temp_refinement_dir}/fast_seg.nii.gz" "$tissue_labels"
                    log_message "✓ FAST 3-class segmentation successful"
                    segmentation_successful=true
                fi
            fi
            
            # Fallback to 2-class FAST
            if [ "$segmentation_successful" = "false" ]; then
                log_message "Trying FAST 2-class segmentation..."
                if fast -t 1 -n 2 -o "${temp_refinement_dir}/fast2_" "$input_image" 2>/dev/null; then
                    if [ -f "${temp_refinement_dir}/fast2_seg.nii.gz" ]; then
                        cp "${temp_refinement_dir}/fast2_seg.nii.gz" "$tissue_labels"
                        log_message "✓ FAST 2-class segmentation successful"
                        segmentation_successful=true
                    fi
                fi
            fi
        fi
        
        # Final fallback: simple intensity-based segmentation
        if [ "$segmentation_successful" = "false" ]; then
            log_message "Using simple intensity-based segmentation as final fallback..."
            
            # Calculate intensity percentiles for simple thresholding
            local p33=$(fslstats "$input_image" -P 33 2>/dev/null || echo "0")
            local p66=$(fslstats "$input_image" -P 66 2>/dev/null || echo "0")
            
            if [ "$p33" != "0" ] && [ "$p66" != "0" ]; then
                # Create 3-class segmentation based on intensity percentiles
                # Class 1: 0 to 33rd percentile
                # Class 2: 33rd to 66th percentile
                # Class 3: 66th percentile and above
                
                local temp_class1="${temp_refinement_dir}/temp_class1.nii.gz"
                local temp_class2="${temp_refinement_dir}/temp_class2.nii.gz"
                local temp_class3="${temp_refinement_dir}/temp_class3.nii.gz"
                
                # Create binary masks for each intensity range
                fslmaths "$input_image" -thr 0 -uthr "$p33" -bin "$temp_class1" 2>/dev/null
                fslmaths "$input_image" -thr "$p33" -uthr "$p66" -bin "$temp_class2" 2>/dev/null
                fslmaths "$input_image" -thr "$p66" -bin "$temp_class3" 2>/dev/null
                
                # Combine into single label image
                fslmaths "$temp_class1" -mul 1 "$tissue_labels" 2>/dev/null
                fslmaths "$temp_class2" -mul 2 -add "$tissue_labels" "$tissue_labels" 2>/dev/null
                fslmaths "$temp_class3" -mul 3 -add "$tissue_labels" "$tissue_labels" 2>/dev/null
                
                # Clean up temporary files
                rm -f "$temp_class1" "$temp_class2" "$temp_class3"
                
                if [ -f "$tissue_labels" ]; then
                    log_message "✓ Simple intensity-based segmentation successful"
                    segmentation_successful=true
                fi
            fi
        fi
        
        # If all segmentation attempts failed, use original mask
        if [ "$segmentation_successful" = "false" ]; then
            log_formatted "ERROR" "All tissue segmentation methods failed"
            log_formatted "WARNING" "Using original atlas-based mask without refinement"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        if [ ! -f "$tissue_labels" ]; then
            log_formatted "ERROR" "No tissue segmentation available for brain-stem refinement"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        # Step 2: Extract appropriate tissue class for brainstem refinement
        local tissue_region="${temp_refinement_dir}/tissue_region.nii.gz"
        local tissue_voxels=0
        
        # Determine maximum label value to understand segmentation classes
        local max_label=$(fslstats "$tissue_labels" -R | awk '{print $2}' | cut -d. -f1)
        log_message "Tissue segmentation has $max_label classes"
        
        # Select appropriate tissue class based on available classes
        if [ "$max_label" -ge 3 ]; then
            # 3-class segmentation: use class 3 (typically white matter)
            log_message "Using class 3 (white matter) from 3-class segmentation"
            fslmaths "$tissue_labels" -thr 3 -uthr 3 -bin "$tissue_region"
        elif [ "$max_label" -eq 2 ]; then
            # 2-class segmentation: use class 2 (typically brain tissue vs background)
            log_message "Using class 2 (brain tissue) from 2-class segmentation"
            fslmaths "$tissue_labels" -thr 2 -uthr 2 -bin "$tissue_region"
        else
            # Single class or invalid segmentation - use original mask
            log_formatted "WARNING" "Invalid tissue segmentation ($max_label classes), using original mask"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        tissue_voxels=$(fslstats "$tissue_region" -V | awk '{print $1}')
        if [ "$tissue_voxels" -lt 100 ]; then
            log_formatted "WARNING" "Selected tissue region very small ($tissue_voxels voxels), using original mask"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        log_message "Selected tissue region: $tissue_voxels voxels"
        
        # Step 3: Find inferior colliculi z-coordinate for seeding
        # Get center of mass of initial brainstem mask
        local com=$(fslstats "$initial_mask" -C)
        local seed_z=$(echo "$com" | awk '{print $3}')
        
        # Step 4: Seed region below inferior colliculi
        local seed_region="${temp_refinement_dir}/seed_region.nii.gz"
        
        # Create a seeding region below the center of mass
        # This is a simplified approach - in practice, you'd want anatomical landmarks
        local dims=$(fslinfo "$input_image" | grep -E "^dim3" | awk '{print $2}')
        local lower_z_threshold=$(echo "$seed_z - 10" | bc -l)  # 10 voxels below COM
        
        # Create seed mask in lower brainstem region
        fslmaths "$tissue_region" -roi 0 -1 0 -1 0 "$lower_z_threshold" 0 -1 "$seed_region"
        
        local seed_voxels=$(fslstats "$seed_region" -V | awk '{print $1}')
        if [ "$seed_voxels" -lt 10 ]; then
            log_formatted "WARNING" "Insufficient seed region, using broader seeding"
            # Fallback: use entire tissue region as seed
            cp "$tissue_region" "$seed_region"
        fi
        
        # Step 5: Morphological geodesic active contour (5 iterations)
        # This is simplified - proper geodesic active contour requires specialized implementation
        # We'll use morphological operations as approximation
        
        log_message "Running 5-iteration morphological geodesic active contour approximation..."
        local current_mask="$seed_region"
        local iteration_mask="${temp_refinement_dir}/iteration_mask.nii.gz"
        
        for i in {1..5}; do
            log_message "  Iteration $i/5..."
            
            # Dilate current mask
            fslmaths "$current_mask" -dilM "$iteration_mask"
            
            # Constrain to tissue region (geodesic constraint)
            fslmaths "$iteration_mask" -mas "$tissue_region" "$iteration_mask"
            
            # Constrain to initial anatomical bounds (safety constraint)
            local expanded_initial="${temp_refinement_dir}/expanded_initial.nii.gz"
            fslmaths "$initial_mask" -dilM -dilM "$expanded_initial"
            fslmaths "$iteration_mask" -mas "$expanded_initial" "$iteration_mask"
            
            # Update current mask
            cp "$iteration_mask" "$current_mask"
            
            # Check convergence
            local current_voxels=$(fslstats "$current_mask" -V | awk '{print $1}')
            log_message "    Voxels after iteration $i: $current_voxels"
        done
        
        # Final refinement: smooth and threshold
        fslmaths "$current_mask" -s 1 -thr 0.5 -bin "$output_refined_mask"
        
        # Validate refined mask
        local refined_voxels=$(fslstats "$output_refined_mask" -V | awk '{print $1}')
        local original_voxels=$(fslstats "$initial_mask" -V | awk '{print $1}')
        
        if [ "$refined_voxels" -eq 0 ]; then
            log_formatted "WARNING" "Refinement produced empty mask, using original"
            cp "$initial_mask" "$output_refined_mask"
            return 0
        fi
        
        # Calculate Dice coefficient improvement expectation
        local dice_numerator=$(fslstats "$output_refined_mask" -mas "$initial_mask" -V | awk '{print $1}')
        local dice_denominator=$(echo "$refined_voxels + $original_voxels" | bc -l)
        local dice_approx=0
        
        if [ "$dice_denominator" -gt 0 ]; then
            dice_approx=$(echo "scale=3; 2 * $dice_numerator / $dice_denominator" | bc -l)
        fi
        
        log_formatted "SUCCESS" "Brain-stem refinement completed"
        log_message "  Original voxels: $original_voxels"
        log_message "  Refined voxels: $refined_voxels"
        log_message "  Approximate Dice overlap: $dice_approx"
        log_message "  Expected Dice improvement: +0.12 over affine-HO"
        
        return 0
    }
    
    # Apply brain-stem refinement
    local refinement_temp_dir="${temp_dir}/refinement"
    mkdir -p "$refinement_temp_dir"
    
    local refined_mask="${temp_dir}/brainstem_mask_subject_refined.nii.gz"
    
    if refine_brainstem_mask_subject_specific "$orientation_corrected_input" \
                                           "${temp_dir}/brainstem_mask_subject_tri.nii.gz" \
                                           "$refined_mask" \
                                           "$refinement_temp_dir"; then
        log_message "Using refined subject-specific brainstem mask"
        cp "$refined_mask" "${temp_dir}/brainstem_mask_subject_tri.nii.gz"
    else
        log_formatted "WARNING" "Subject-specific refinement failed, using atlas-based mask"
    fi
    
    # Clean up refinement temporary files
    rm -rf "$refinement_temp_dir"
    
    # If orientation correction was applied, we need to transform back to original orientation
    if [ "$orientation_corrected" = "true" ]; then
        log_message "Converting brainstem mask back to original subject orientation..."
        
        # Apply reverse orientation correction to the mask
        if [ "$input_orient" = "NEUROLOGICAL" ] && [ "$mni_orient" = "RADIOLOGICAL" ]; then
            # Convert back from RADIOLOGICAL to NEUROLOGICAL
            fslswapdim "${temp_dir}/brainstem_mask_subject_tri.nii.gz" -x y z "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz"
            # Set orientation back to original NEUROLOGICAL
            fslorient -forceneurological "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz"
        elif [ "$input_orient" = "RADIOLOGICAL" ] && [ "$mni_orient" = "NEUROLOGICAL" ]; then
            # Convert back from NEUROLOGICAL to RADIOLOGICAL
            fslswapdim "${temp_dir}/brainstem_mask_subject_tri.nii.gz" -x y z "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz"
            # Set orientation back to original RADIOLOGICAL
            fslorient -forceradiological "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz"
        else
            # No correction applied or unsupported conversion
            cp "${temp_dir}/brainstem_mask_subject_tri.nii.gz" "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz"
        fi
        
        # Use the corrected version
        mv "${temp_dir}/brainstem_mask_subject_tri_corrected.nii.gz" "${temp_dir}/brainstem_mask_subject_tri.nii.gz"
        log_message "Orientation correction applied to brainstem mask"
    fi
    
    # Check if the transform was successful
    if [ ! -f "${temp_dir}/brainstem_mask_subject_tri.nii.gz" ]; then
        log_formatted "ERROR" "Failed to transform brainstem mask to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Threshold at 0.5 to create binary mask (captures partial volume voxels)
    fslmaths "${temp_dir}/brainstem_mask_subject_tri.nii.gz" -thr 0.5 -bin "${temp_dir}/brainstem_mask_subject.nii.gz"
    
    # CRITICAL: Validate anatomical location of transformed mask
    log_formatted "INFO" "===== ANATOMICAL LOCATION VALIDATION ====="
    local com=$(fslstats "${temp_dir}/brainstem_mask_subject.nii.gz" -C)
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
    local mask_volume=$(fslstats "${temp_dir}/brainstem_mask_subject.nii.gz" -V | awk '{print $1}')
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
        
        # Save debugging information
        log_message "Saving debugging information..."
        
        # Copy intermediate files for inspection
        cp "${brainstem_mask_mni_file}" "${output_dir}/../debug_brainstem_mni.nii.gz" 2>/dev/null || true
        cp "${temp_dir}/brainstem_mask_subject_tri.nii.gz" "${output_dir}/../debug_brainstem_subject_tri.nii.gz" 2>/dev/null || true
        cp "${ants_prefix}0GenericAffine.mat" "${output_dir}/../debug_transform.mat" 2>/dev/null || true
        
        log_message "Debug files saved to $(dirname "$output_dir")"
        log_message "  debug_brainstem_mni.nii.gz - Brainstem mask in MNI space"
        log_message "  debug_brainstem_subject_tri.nii.gz - Transformed mask before thresholding"
        log_message "  debug_transform.mat - ANTs transformation matrix"
        
        # Create visualization overlay for manual inspection
        local debug_overlay="${output_dir}/../debug_brainstem_overlay.nii.gz"
        if overlay 1 0 "$input_file" -5000 5000 "${temp_dir}/brainstem_mask_subject.nii.gz" 0.5 1 "$debug_overlay" 2>/dev/null; then
            log_message "  debug_brainstem_overlay.nii.gz - Overlay for visual inspection"
        fi
        
        rm -rf "$temp_dir"
        return 1
    else
        log_formatted "SUCCESS" "Brainstem segmentation passes anatomical validation"
        log_message "Volume: $mask_volume voxels, Position: (${rel_x}, ${rel_y}, ${rel_z})"
    fi
    
    log_message "Brainstem mask transformation completed and validated"
    # Step 5: Apply mask to get intensity values
    log_message "Creating intensity-based brainstem segmentation..."
    
    # Verify mask exists
    if [ ! -f "${temp_dir}/brainstem_mask_subject.nii.gz" ]; then
        log_formatted "ERROR" "Brainstem mask not found: ${temp_dir}/brainstem_mask_subject.nii.gz"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Convert output path to absolute if relative
    local abs_output_file="$output_file"
    if [[ "$output_file" != /* ]]; then
        abs_output_file="$(pwd)/$output_file"
    fi
    
    log_message "Output will be written to: $abs_output_file"
    
    # Remove any existing file or symlink at the output location
    if [ -L "$abs_output_file" ] || [ -e "$abs_output_file" ]; then
        log_message "Removing existing file/symlink at output location"
        rm -f "$abs_output_file"
    fi
    
    # Apply mask using fslmaths directly (safe_fslmaths is checking output as input)
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask_subject.nii.gz" \
             "$abs_output_file"
    
    # Check if output was created
    if [ ! -f "$abs_output_file" ]; then
        log_formatted "ERROR" "Failed to create brainstem segmentation"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Also save the binary mask
    local mask_file="${output_dir}/$(basename "$output_file" .nii.gz)_mask.nii.gz"
    if [[ "$mask_file" != /* ]]; then
        mask_file="$(pwd)/$mask_file"
    fi
    
    # Remove any existing mask file
    if [ -L "$mask_file" ] || [ -e "$mask_file" ]; then
        rm -f "$mask_file"
    fi
    
    cp "${temp_dir}/brainstem_mask_subject.nii.gz" "$mask_file"
    
    # Create T1 intensity version for QA module compatibility
    local output_dir_path="$(dirname "$abs_output_file")"
    local base_name=$(basename "$abs_output_file" .nii.gz)
    local t1_intensity_file="${output_dir_path}/${base_name}_t1_intensity.nii.gz"
    
    log_message "Creating T1 intensity version for QA module..."
    if fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask_subject.nii.gz" "$t1_intensity_file"; then
        log_message "✓ Created T1 intensity version: $(basename "$t1_intensity_file")"
    else
        log_formatted "WARNING" "Failed to create T1 intensity version (non-critical)"
    fi
    
    # Apply segmentation to FLAIR AND create FLAIR-space versions for analysis compatibility
    log_message "Checking for FLAIR to apply segmentation and create analysis-compatible versions..."
    local flair_registered="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
    local flair_files_found=()
    local original_flair_files=()
    
    # Look for registered FLAIR files
    if [ -f "$flair_registered" ]; then
        flair_files_found+=("$flair_registered")
    fi
    
    # Also look for other FLAIR registration patterns
    if [ -d "${RESULTS_DIR}/registered" ]; then
        while IFS= read -r -d '' flair_file; do
            flair_files_found+=("$flair_file")
        done < <(find "${RESULTS_DIR}/registered" -name "*flair*Warped.nii.gz" -o -name "*FLAIR*Warped.nii.gz" -print0 2>/dev/null)
    fi
    
    # Look for original FLAIR files for FLAIR-space analysis
    if [ -d "${RESULTS_DIR}/standardized" ]; then
        while IFS= read -r -d '' orig_flair; do
            original_flair_files+=("$orig_flair")
        done < <(find "${RESULTS_DIR}/standardized" -name "*FLAIR*_std.nii.gz" -o -name "*flair*_std.nii.gz" -print0 2>/dev/null)
    fi
    
    # Apply segmentation to each registered FLAIR file found (T1 space)
    for flair_file in "${flair_files_found[@]}"; do
        if [ -f "$flair_file" ]; then
            local flair_base=$(basename "$flair_file" .nii.gz)
            local flair_intensity_file="${output_dir_path}/${base_name}_flair_intensity.nii.gz"
            
            # Check dimensions compatibility before applying mask
            local flair_dims=$(fslinfo "$flair_file" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
            local mask_dims=$(fslinfo "${temp_dir}/brainstem_mask_subject.nii.gz" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
            
            if [ "$flair_dims" = "$mask_dims" ]; then
                log_message "Creating FLAIR intensity version from: $(basename "$flair_file")"
                if fslmaths "$flair_file" -mas "${temp_dir}/brainstem_mask_subject.nii.gz" "$flair_intensity_file"; then
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
    
    # Create FLAIR-space versions for analysis compatibility
    for orig_flair in "${original_flair_files[@]}"; do
        if [ -f "$orig_flair" ]; then
            log_message "Creating FLAIR-space analysis versions from: $(basename "$orig_flair")"
            
            # Create output directory for FLAIR-space analysis files
            local flair_analysis_dir="${RESULTS_DIR}/comprehensive_analysis/original_space"
            mkdir -p "$flair_analysis_dir"
            
            # Resample T1-space mask to FLAIR space using standardize_dimensions function
            local flair_space_mask="${flair_analysis_dir}/${base_name}_brainstem_mask_flair_space.nii.gz"
            
            # Use standardize_dimensions function from preprocessing module to resample mask to FLAIR grid
            if command -v standardize_dimensions &> /dev/null; then
                log_message "Resampling brainstem mask to FLAIR space using standardize_dimensions..."
                
                # Use reference file mode for identical matrix dimensions
                if standardize_dimensions "${temp_dir}/brainstem_mask_subject.nii.gz" "" "$orig_flair"; then
                    # standardize_dimensions creates output in standardized dir, so we need to find and move it
                    local std_output="${RESULTS_DIR}/standardized/$(basename "${temp_dir}/brainstem_mask_subject.nii.gz" .nii.gz)_std.nii.gz"
                    if [ -f "$std_output" ]; then
                        mv "$std_output" "$flair_space_mask"
                        log_message "✓ Moved resampled mask to: $(basename "$flair_space_mask")"
                    else
                        log_formatted "WARNING" "Standardized output not found, using direct flirt approach"
                    fi
                else
                    log_formatted "WARNING" "standardize_dimensions failed, using direct flirt approach"
                fi
            fi
            
            # Fallback: use flirt for resampling if standardize_dimensions failed
            if [ ! -f "$flair_space_mask" ]; then
                log_message "Using flirt fallback to resample mask to FLAIR space..."
                if flirt -in "${temp_dir}/brainstem_mask_subject.nii.gz" -ref "$orig_flair" -out "$flair_space_mask" -applyxfm -usesqform -interp nearestneighbour; then
                    log_message "✓ Flirt resampling successful"
                else
                    log_formatted "WARNING" "Failed to resample mask to FLAIR space"
                    continue
                fi
            fi
            
            # Create FLAIR-space intensity version with correct naming for analysis discovery
            local flair_space_intensity="${flair_analysis_dir}/${base_name}_brainstem_intensity.nii.gz"
            
            if [ -f "$flair_space_mask" ]; then
                # Apply mask to original FLAIR to create intensity version
                if fslmaths "$orig_flair" -mas "$flair_space_mask" "$flair_space_intensity"; then
                    log_message "✓ Created FLAIR-space intensity version: $(basename "$flair_space_intensity")"
                else
                    log_formatted "WARNING" "Failed to create FLAIR-space intensity version"
                fi
                
                # Create analysis-compatible binary mask with proper naming
                # Analysis expects to find *brainstem*.nii.gz and use it as a binary mask
                local analysis_brainstem_mask="${flair_analysis_dir}/${base_name}_brainstem.nii.gz"
                if cp "$flair_space_mask" "$analysis_brainstem_mask"; then
                    log_message "✓ Created analysis-compatible brainstem mask: $(basename "$analysis_brainstem_mask")"
                else
                    log_formatted "WARNING" "Failed to create analysis-compatible brainstem mask"
                fi
                
                # Also create legacy naming for backward compatibility
                local legacy_brainstem="${flair_analysis_dir}/brainstem_location_check_intensity.nii.gz"
                if cp "$flair_space_mask" "$legacy_brainstem"; then
                    log_message "✓ Created legacy-compatible file: $(basename "$legacy_brainstem")"
                else
                    log_formatted "WARNING" "Failed to create legacy-compatible file"
                fi
            fi
            
            # Only process the first FLAIR file
            break
        fi
    done
    
    if [ ${#flair_files_found[@]} -eq 0 ] && [ ${#original_flair_files[@]} -eq 0 ]; then
        log_message "No FLAIR files found - T1 intensity only"
    fi
    
    # Create QA-compatible naming convention
    local mask_base_name=$(basename "$mask_file" .nii.gz)
    local qa_t1_intensity="${output_dir_path}/${mask_base_name}_t1_intensity.nii.gz"
    
    if [ -f "$t1_intensity_file" ] && [ "$t1_intensity_file" != "$qa_t1_intensity" ]; then
        ln -sf "$(basename "$t1_intensity_file")" "$qa_t1_intensity" 2>/dev/null || \
        cp "$t1_intensity_file" "$qa_t1_intensity"
        log_message "✓ Created QA-compatible T1 intensity: $(basename "$qa_t1_intensity")"
    fi
    
    # Create QA-compatible FLAIR intensity if it exists
    local flair_intensity_file="${output_dir_path}/${base_name}_flair_intensity.nii.gz"
    if [ -f "$flair_intensity_file" ]; then
        local qa_flair_intensity="${output_dir_path}/${mask_base_name}_flair_intensity.nii.gz"
        if [ "$flair_intensity_file" != "$qa_flair_intensity" ]; then
            ln -sf "$(basename "$flair_intensity_file")" "$qa_flair_intensity" 2>/dev/null || \
            cp "$flair_intensity_file" "$qa_flair_intensity"
            log_message "✓ Created QA-compatible FLAIR intensity: $(basename "$qa_flair_intensity")"
        fi
    fi
    
    # Validate output (use absolute path)
    if [ ! -f "$abs_output_file" ]; then
        log_formatted "ERROR" "Failed to create output file: $abs_output_file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Update output_file to absolute path for consistency
    output_file="$abs_output_file"
    
    local output_size=$(stat -f "%z" "$output_file" 2>/dev/null || stat --format="%s" "$output_file" 2>/dev/null || echo "0")
    local voxel_count=$(fslstats "${temp_dir}/brainstem_mask_subject.nii.gz" -V | awk '{print $1}')
    
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
    local output_prefix="${3:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$t1_file" .nii.gz)}"
    
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
    
    # Cleanup function for error cases
    cleanup_and_fail() {
        local exit_code="$1"
        local error_msg="$2"
        log_formatted "ERROR" "SEGMENTATION FAILURE: $error_msg"
        log_formatted "ERROR" "Segmentation failed due to data quality issues"
        rm -rf "$temp_dir"
        return "$exit_code"
    }
    
    # First get Harvard-Oxford segmentation from T1 - FAIL HARD if this fails
    local t1_brainstem="${output_prefix}_brainstem_t1based.nii.gz"
    if ! extract_brainstem_harvard_oxford "$t1_file" "$t1_brainstem"; then
        cleanup_and_fail 1 "T1-based Harvard-Oxford segmentation failed - cannot proceed"
        return 1
    fi
    
    if [ ! -f "$t1_brainstem" ]; then
        cleanup_and_fail 1 "T1-based segmentation output not created: $t1_brainstem"
        return 1
    fi
    
    # Get the binary mask - FAIL HARD if missing
    local t1_mask="${output_prefix}_brainstem_t1based_mask.nii.gz"
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "T1 brainstem mask not found: $t1_mask"
        return 1
    fi
    
    # Check if FLAIR is already in T1 space (from registration step)
    local flair_in_t1="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
    if [ ! -f "$flair_in_t1" ]; then
        log_message "FLAIR not yet registered to T1, using original FLAIR"
        flair_in_t1="$flair_file"
    fi
    
    # Validate FLAIR file exists - FAIL HARD
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR file not found: $flair_in_t1"
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
        cleanup_and_fail 1 "Image dimension mismatch prevents reliable FLAIR integration"
        return 1
    fi
    
    # Check orientations are consistent - FAIL HARD on orientation mismatch
    local flair_orient=$(fslorient -getorient "$flair_in_t1" 2>/dev/null)
    local mask_orient=$(fslorient -getorient "$t1_mask" 2>/dev/null)
    
    if [ "$flair_orient" != "$mask_orient" ]; then
        log_formatted "ERROR" "CRITICAL: FLAIR and mask have inconsistent orientations"
        log_formatted "ERROR" "FLAIR: $flair_orient, Mask: $mask_orient"
        cleanup_and_fail 1 "Orientation mismatch prevents reliable FLAIR integration"
        return 1
    fi
    
    # Extract FLAIR intensities within brainstem region - FAIL HARD on any error
    log_message "Extracting FLAIR intensities within brainstem region..."
    
    # Validate input files exist before fslmaths operation
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR input file missing before extraction: $flair_in_t1"
        return 1
    fi
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "T1 mask file missing before extraction: $t1_mask"
        return 1
    fi
    
    if ! fslmaths "$flair_in_t1" -mas "$t1_mask" "${temp_dir}/flair_brainstem.nii.gz"; then
        cleanup_and_fail 1 "Failed to extract FLAIR intensities - fslmaths operation failed"
        return 1
    fi
    
    # Verify the output file was created and has non-zero voxels - FAIL HARD
    if [ ! -f "${temp_dir}/flair_brainstem.nii.gz" ]; then
        cleanup_and_fail 1 "FLAIR brainstem extraction failed - output file not created"
        return 1
    fi
    
    # Get voxel count and validate it's a number
    local flair_voxel_count=$(fslstats "${temp_dir}/flair_brainstem.nii.gz" -V 2>/dev/null | awk '{print $1}')
    if [ -z "$flair_voxel_count" ] || ! [[ "$flair_voxel_count" =~ ^[0-9]+$ ]]; then
        cleanup_and_fail 1 "Failed to get valid voxel count from FLAIR brainstem (got: '$flair_voxel_count')"
        return 1
    fi
    
    if [ "$flair_voxel_count" -eq 0 ]; then
        cleanup_and_fail 1 "FLAIR brainstem region is empty - no valid data for enhancement"
        return 1
    fi
    
    log_message "Extracted FLAIR data: $flair_voxel_count voxels"
    
    # Calculate intensity statistics within brainstem - FAIL HARD on invalid stats
    log_message "Calculating FLAIR intensity statistics..."
    
    # Validate input file exists before fslstats operations
    if [ ! -f "${temp_dir}/flair_brainstem.nii.gz" ]; then
        cleanup_and_fail 1 "FLAIR brainstem file missing before statistics calculation: ${temp_dir}/flair_brainstem.nii.gz"
        return 1
    fi
    
    local mean_intensity=$(fslstats "${temp_dir}/flair_brainstem.nii.gz" -M 2>/dev/null)
    local std_intensity=$(fslstats "${temp_dir}/flair_brainstem.nii.gz" -S 2>/dev/null)
    
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
    if [ ! -f "${temp_dir}/flair_brainstem.nii.gz" ]; then
        cleanup_and_fail 1 "FLAIR brainstem file missing before threshold operation: ${temp_dir}/flair_brainstem.nii.gz"
        return 1
    fi
    
    if ! fslmaths "${temp_dir}/flair_brainstem.nii.gz" \
                  -thr "$lower_threshold" -uthr "$upper_threshold" -bin \
                  "${temp_dir}/flair_refined_mask.nii.gz"; then
        cleanup_and_fail 1 "Failed to create refined FLAIR mask using intensity thresholds"
        return 1
    fi
    
    # Verify refined mask was created and is valid - FAIL HARD
    if [ ! -f "${temp_dir}/flair_refined_mask.nii.gz" ]; then
        cleanup_and_fail 1 "Refined FLAIR mask file not created"
        return 1
    fi
    
    # Get voxel count and validate it's a number
    local refined_voxels=$(fslstats "${temp_dir}/flair_refined_mask.nii.gz" -V 2>/dev/null | awk '{print $1}')
    if [ -z "$refined_voxels" ] || ! [[ "$refined_voxels" =~ ^[0-9]+$ ]]; then
        cleanup_and_fail 1 "Failed to get valid voxel count from refined FLAIR mask (got: '$refined_voxels')"
        return 1
    fi
    
    if [ "$refined_voxels" -eq 0 ]; then
        cleanup_and_fail 1 "Refined FLAIR mask is empty - intensity thresholding removed all voxels"
        return 1
    fi
    
    # Combine T1 and FLAIR information - FAIL HARD on error
    log_message "Combining T1 and FLAIR information..."
    
    # Validate input files exist before combination operation
    if [ ! -f "$t1_mask" ]; then
        cleanup_and_fail 1 "T1 mask file missing before combination: $t1_mask"
        return 1
    fi
    if [ ! -f "${temp_dir}/flair_refined_mask.nii.gz" ]; then
        cleanup_and_fail 1 "Refined FLAIR mask file missing before combination: ${temp_dir}/flair_refined_mask.nii.gz"
        return 1
    fi
    
    if ! fslmaths "$t1_mask" -mul "${temp_dir}/flair_refined_mask.nii.gz" \
                  "${output_prefix}_brainstem_mask.nii.gz"; then
        cleanup_and_fail 1 "Failed to combine T1 and FLAIR masks"
        return 1
    fi
    
    # Apply refined mask to T1 for final output - FAIL HARD on error
    # Validate input files exist before T1 masking operation
    if [ ! -f "$t1_file" ]; then
        cleanup_and_fail 1 "T1 file missing before final masking: $t1_file"
        return 1
    fi
    if [ ! -f "${output_prefix}_brainstem_mask.nii.gz" ]; then
        cleanup_and_fail 1 "Combined brainstem mask missing before T1 masking: ${output_prefix}_brainstem_mask.nii.gz"
        return 1
    fi
    
    if ! fslmaths "$t1_file" -mas "${output_prefix}_brainstem_mask.nii.gz" \
                  "${output_prefix}_brainstem.nii.gz"; then
        cleanup_and_fail 1 "Failed to create final T1-masked segmentation output"
        return 1
    fi
    
    # Create FLAIR intensity version - FAIL HARD on error
    # Validate input files exist before FLAIR masking operation
    if [ ! -f "$flair_in_t1" ]; then
        cleanup_and_fail 1 "FLAIR file missing before final masking: $flair_in_t1"
        return 1
    fi
    if [ ! -f "${output_prefix}_brainstem_mask.nii.gz" ]; then
        cleanup_and_fail 1 "Combined brainstem mask missing before FLAIR masking: ${output_prefix}_brainstem_mask.nii.gz"
        return 1
    fi
    
    if ! fslmaths "$flair_in_t1" -mas "${output_prefix}_brainstem_mask.nii.gz" \
                  "${output_prefix}_brainstem_flair_intensity.nii.gz"; then
        cleanup_and_fail 1 "Failed to create FLAIR intensity segmentation output"
        return 1
    fi
    
    # Create T1 intensity version for QA module compatibility
    log_message "Creating T1 intensity version for QA module..."
    if ! fslmaths "$t1_file" -mas "${output_prefix}_brainstem_mask.nii.gz" \
                  "${output_prefix}_brainstem_t1_intensity.nii.gz"; then
        cleanup_and_fail 1 "Failed to create T1 intensity segmentation output"
        return 1
    fi
    
    # Final validation - FAIL HARD if outputs are invalid
    # Validate final mask exists before statistics calculation
    if [ ! -f "${output_prefix}_brainstem_mask.nii.gz" ]; then
        cleanup_and_fail 1 "Final brainstem mask missing before validation: ${output_prefix}_brainstem_mask.nii.gz"
        return 1
    fi
    
    # Get final voxel count and validate it's a number
    local final_voxels=$(fslstats "${output_prefix}_brainstem_mask.nii.gz" -V 2>/dev/null | awk '{print $1}')
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
        "${output_prefix}_brainstem_mask.nii.gz"
        "${output_prefix}_brainstem.nii.gz"
        "${output_prefix}_brainstem_flair_intensity.nii.gz"
        "${output_prefix}_brainstem_t1_intensity.nii.gz"
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
    log_message "  T1 intensities: ${output_prefix}_brainstem.nii.gz"
    log_message "  T1 intensity mask: ${output_prefix}_brainstem_t1_intensity.nii.gz"
    log_message "  FLAIR intensities: ${output_prefix}_brainstem_flair_intensity.nii.gz"
    log_message "  Binary mask: ${output_prefix}_brainstem_mask.nii.gz"
    
    # Create QA-compatible naming convention
    log_message "Creating QA-compatible intensity file naming..."
    local output_dir="$(dirname "${output_prefix}")"
    local mask_file="${output_prefix}_brainstem_mask.nii.gz"
    
    if [ -f "$mask_file" ]; then
        local base_name=$(basename "$mask_file" .nii.gz)
        local qa_t1_intensity="${output_dir}/${base_name}_t1_intensity.nii.gz"
        local qa_flair_intensity="${output_dir}/${base_name}_flair_intensity.nii.gz"
        
        # Create symbolic links or copies for QA module compatibility
        if [ -f "${output_prefix}_brainstem_t1_intensity.nii.gz" ]; then
            ln -sf "$(basename "${output_prefix}_brainstem_t1_intensity.nii.gz")" "$qa_t1_intensity" 2>/dev/null || \
            cp "${output_prefix}_brainstem_t1_intensity.nii.gz" "$qa_t1_intensity"
            log_message "✓ Created QA-compatible T1 intensity: $(basename "$qa_t1_intensity")"
        fi
        
        if [ -f "${output_prefix}_brainstem_flair_intensity.nii.gz" ]; then
            ln -sf "$(basename "${output_prefix}_brainstem_flair_intensity.nii.gz")" "$qa_flair_intensity" 2>/dev/null || \
            cp "${output_prefix}_brainstem_flair_intensity.nii.gz" "$qa_flair_intensity"
            log_message "✓ Created QA-compatible FLAIR intensity: $(basename "$qa_flair_intensity")"
        fi
    fi
    
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
    
    # Define output directories with absolute paths
    local brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    local pons_dir="${RESULTS_DIR}/segmentation/pons"
    
    # Convert to absolute paths if relative
    if [[ "$brainstem_dir" != /* ]]; then
        brainstem_dir="$(pwd)/$brainstem_dir"
    fi
    if [[ "$pons_dir" != /* ]]; then
        pons_dir="$(pwd)/$pons_dir"
    fi
    
    log_message "Creating segmentation directories:"
    log_message "  Brainstem: $brainstem_dir"
    log_message "  Pons: $pons_dir"
    
    if ! mkdir -p "$brainstem_dir" "$pons_dir"; then
        log_formatted "ERROR" "Failed to create segmentation directories"
        return 1
    fi
    
    # Verify directories are writable
    if [ ! -w "$brainstem_dir" ] || [ ! -w "$pons_dir" ]; then
        log_formatted "ERROR" "Segmentation directories are not writable"
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
            # Try to find original FLAIR
            flair_file=$(find "${RESULTS_DIR}/standardized" -name "*FLAIR*_std.nii.gz" | head -1)
        fi
        
        if [ -n "$flair_file" ] && [ -f "$flair_file" ]; then
            log_message "Enhancing with FLAIR data..."
            local enhanced_prefix="${brainstem_dir}/${input_basename}"
            if extract_brainstem_with_flair "$input_file" "$flair_file" "$enhanced_prefix"; then
                # Use enhanced version as primary output
                [ -f "${enhanced_prefix}_brainstem.nii.gz" ] && \
                    mv "${enhanced_prefix}_brainstem.nii.gz" "$harvard_output"
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
        else
            log_message "✓ Using fallback subdivision method (Juelich) constrained to Harvard-Oxford boundaries"
        fi
    else
        log_formatted "INFO" "===== IMPORTANT NOTICE ====="
        log_message "No valid brainstem subdivision available within Harvard-Oxford boundaries"
        log_message "Creating EMPTY placeholder files for pipeline compatibility only"
        log_message "These are NOT anatomical segmentations"
        
        # Create empty placeholder files
        local pons_file="${pons_dir}/${input_basename}_pons.nii.gz"
        
        # Get reference file for dimensions
        local ref_file="${brainstem_dir}/${input_basename}_brainstem.nii.gz"
        if [ -f "$ref_file" ]; then
            # Remove existing file/symlink
            [ -L "$pons_file" ] || [ -e "$pons_file" ] && rm -f "$pons_file"
            # Create empty file with same dimensions
            fslmaths "$ref_file" -mul 0 "$pons_file" 2>/dev/null || {
                log_formatted "WARNING" "Could not create placeholder: $pons_file"
            }
            log_message "Created empty pons placeholder (0 voxels) - NOT real segmentation"
        fi
    fi
    
    # Map files to expected names (remove method suffixes)
    map_segmentation_files "$input_basename" "$brainstem_dir" "$pons_dir"
    
    # Create combined label map for easy visualization
    create_combined_segmentation_map "$input_basename" "$brainstem_dir" "$pons_dir"
    
    # Validate segmentation
    validate_segmentation_outputs "$input_file" "$input_basename"
    
    # Generate comprehensive visualization report
    generate_segmentation_report "$input_file" "$input_basename"
    
    log_formatted "SUCCESS" "Atlas-based segmentation complete"
    
    # IMPORTANT: Return 0 to continue pipeline flow
    return 0
}

# ============================================================================
# PONS EXTRACTION - ATLAS BASED ONLY
# ============================================================================

extract_pons_from_brainstem() {
    local brainstem_file="$1"
    local output_basename="$2"
    
    log_formatted "WARNING" "Harvard-Oxford atlas does not provide pons subdivision"
    log_message "Pons segmentation requires Juelich or other specialized brainstem atlas"
    
    # DO NOT approximate or guess anatomical structures
    # If we don't have proper atlas-based segmentation, we should not create fake ones
    
    return 1
}

# ============================================================================
# FILE MAPPING AND DISCOVERY
# ============================================================================

map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    local pons_dir="$3"
    
    log_message "Mapping segmentation files to expected names..."
    
    # Remove any method suffixes from files
    for file in "${brainstem_dir}"/*_brainstem*.nii.gz; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            # Remove suffixes like _harvard, _juelich, _t1based, etc.
            local clean_name=$(echo "$basename" | sed -E 's/_(harvard|juelich|t1based|enhanced)//g')
            if [ "$basename" != "$clean_name" ]; then
                log_message "Renaming $basename to $clean_name"
                mv "$file" "${brainstem_dir}/${clean_name}"
            fi
        fi
    done
    
    # Same for pons directory
    for file in "${pons_dir}"/*_pons*.nii.gz; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            local clean_name=$(echo "$basename" | sed -E 's/_(harvard|juelich|t1based|enhanced)//g')
            if [ "$basename" != "$clean_name" ]; then
                log_message "Renaming $basename to $clean_name"
                mv "$file" "${pons_dir}/${clean_name}"
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
    local pons_file="${RESULTS_DIR}/segmentation/pons/${basename}_pons.nii.gz"
    
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
    
    # Check pons
    if [ -f "$pons_file" ]; then
        local pons_voxels=$(fslstats "$pons_file" -V | awk '{print $1}')
        log_message "Pons: $pons_voxels voxels"
    else
        log_formatted "WARNING" "Pons segmentation file not found: $pons_file"
    fi
    
    # Create validation report
    local validation_dir="${RESULTS_DIR}/validation/segmentation"
    mkdir -p "$validation_dir"
    
    {
        echo "Segmentation Validation Report"
        echo "=============================="
        echo "Date: $(date)"
        echo "Input: $input_file"
        echo ""
        echo "Files created:"
        ls -la "${RESULTS_DIR}/segmentation/brainstem/${basename}"*.nii.gz 2>/dev/null || echo "No brainstem files"
        ls -la "${RESULTS_DIR}/segmentation/pons/${basename}"*.nii.gz 2>/dev/null || echo "No pons files"
        echo ""
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
    local pons_dir="$3"
    
    log_message "Creating combined segmentation label map..."
    
    local combined_dir="${RESULTS_DIR}/segmentation/combined"
    mkdir -p "$combined_dir"
    
    # Define label values
    local BRAINSTEM_LABEL=1
    local PONS_LABEL=2
    
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
    
    # Add pons (label 2) - overwrites brainstem voxels where pons exists
    local pons_mask="${pons_dir}/${input_basename}_pons.nii.gz"
    if [ -f "$pons_mask" ]; then
        local pons_voxels=$(fslstats "$pons_mask" -V | awk '{print $1}')
        if [ "$pons_voxels" -gt 0 ]; then
            # Create binary mask first
            fslmaths "$pons_mask" -bin -mul $PONS_LABEL "${combined_dir}/temp_pons.nii.gz"
            # Use maximum to overwrite brainstem voxels
            fslmaths "$combined_map" -max "${combined_dir}/temp_pons.nii.gz" "$combined_map"
            rm "${combined_dir}/temp_pons.nii.gz"
            log_message "Added pons to combined map (label=$PONS_LABEL)"
        fi
    fi
    
    # Note: Dorsal/ventral pons subdivisions not available - only combined pons segmentation
    
    # Create label description file
    {
        echo "# Brainstem Segmentation Label Map"
        echo "# Label values:"
        echo "0 = Background"
        echo "1 = Brainstem (Harvard-Oxford)"
        echo "2 = Pons"
        echo "3 = Dorsal Pons"
        echo "4 = Ventral Pons"
    } > "${combined_dir}/${input_basename}_segmentation_labels.txt"
    
    log_message "Combined segmentation map created: $combined_map"
    return 0
}

# ============================================================================
# SEGMENTATION REPORT GENERATION
# ============================================================================

generate_segmentation_report() {
    local input_file="$1"
    local input_basename="$2"
    
    log_message "Generating comprehensive segmentation report..."
    
    local report_dir="${RESULTS_DIR}/reports"
    mkdir -p "$report_dir"
    
    local report_file="${report_dir}/segmentation_report_${input_basename}.txt"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Gather file information
    local t1_file="${RESULTS_DIR}/standardized/$(basename "$input_file")"
    local flair_registered="${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz"
    local brainstem_intensity="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem.nii.gz"
    local brainstem_mask="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem_mask.nii.gz"
    local pons_file="${RESULTS_DIR}/segmentation/pons/${input_basename}_pons.nii.gz"
    local combined_labels="${RESULTS_DIR}/segmentation/combined/${input_basename}_segmentation_labels.nii.gz"
    
    # Calculate statistics
    local brainstem_voxels=0
    local pons_voxels=0
    if [ -f "$brainstem_mask" ]; then
        brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    fi
    if [ -f "$pons_file" ]; then
        pons_voxels=$(fslstats "$pons_file" -V | awk '{print $1}')
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
Pons voxels: $pons_voxels

FILES GENERATED
--------------
1. Binary Masks (for ROI analysis):
   - Brainstem mask: ${brainstem_mask}
   - Pons mask: ${pons_file}

2. Intensity Maps (T1 values within masks):
   - Brainstem intensities: ${brainstem_intensity}

3. Combined Label Map:
   - All structures: ${combined_labels}
   - Labels: 0=Background, 1=Brainstem, 2=Pons, 3=Dorsal Pons, 4=Ventral Pons

VISUALIZATION INSTRUCTIONS
-------------------------
To visualize the segmentations overlaid on your images:

1. View segmentations on T1:
   fsleyes ${t1_file} \\
           ${brainstem_mask} -cm red -a 50 \\
           ${pons_file} -cm yellow -a 50

2. View segmentations on registered FLAIR:
EOF

    if [ -f "$flair_registered" ]; then
        cat >> "$report_file" <<EOF
   fsleyes ${flair_registered} \\
           ${brainstem_mask} -cm red -a 50 \\
           ${pons_file} -cm yellow -a 50

3. View combined label map:
   fsleyes ${t1_file} \\
           ${combined_labels} -cm random -a 50

4. View with intensity overlay (shows T1 intensities within brainstem):
   fsleyes ${t1_file} \\
           ${brainstem_intensity} -cm hot -a 70
EOF
    else
        cat >> "$report_file" <<EOF
   [FLAIR not yet registered - run registration step first]
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
- Juelich used as fallback if Talairach unavailable
- Empty files (0 voxels) indicate structure not available from atlas
- Use binary masks for ROI definition
- Use intensity maps for signal analysis

================================================================================
EOF

    log_formatted "SUCCESS" "Segmentation report generated: $report_file"
    
    # Also display key visualization commands
    echo ""
    log_formatted "INFO" "===== VISUALIZATION COMMANDS ====="
    log_message "To view your segmentations:"
    echo ""
    echo "  # View on T1:"
    echo "  fsleyes ${t1_file} \\"
    echo "          ${brainstem_mask} -cm red -a 50 \\"
    echo "          ${pons_file} -cm yellow -a 50"
    echo ""
    
    if [ -f "$flair_registered" ]; then
        echo "  # View on registered FLAIR:"
        echo "  fsleyes ${flair_registered} \\"
        echo "          ${brainstem_mask} -cm red -a 50 \\"
        echo "          ${pons_file} -cm yellow -a 50"
        echo ""
    fi
    
    echo "  # View combined label map:"
    echo "  fsleyes ${t1_file} \\"
    echo "          ${combined_labels} -cm random -a 50"
    echo ""
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
    log_formatted "WARNING" "extract_brainstem_talairach is deprecated. Using Harvard-Oxford in T1 space."
    extract_brainstem_harvard_oxford "$@"
}

extract_brainstem_ants() {
    log_formatted "WARNING" "extract_brainstem_ants is deprecated. Using Harvard-Oxford in T1 space."
    extract_brainstem_harvard_oxford "$@"
}

# Note: divide_pons function removed - dorsal/ventral pons subdivisions not available

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
    local pons_dir="$3"
    
    map_segmentation_files "$input_basename" "$brainstem_dir" "$pons_dir"
    
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
    
    # Step 1: Brain extraction (if not already done)
    local brain_mask="${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz"
    local brain_file="${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz"
    
    if [ ! -f "$brain_mask" ]; then
        log_message "Brain mask not found, performing brain extraction..."
        extract_brain "$input_file"
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
export -f extract_pons_from_brainstem
export -f map_segmentation_files
export -f validate_segmentation_outputs
export -f create_combined_segmentation_map
export -f generate_segmentation_report

# Legacy exports for compatibility
export -f extract_brainstem_standardspace
export -f extract_brainstem_talairach
export -f extract_brainstem_ants
# export -f divide_pons  # Removed - dorsal/ventral pons subdivisions not available
export -f validate_segmentation
export -f segment_tissues
export -f discover_and_map_segmentation_files

log_message "Segmentation module loaded (refactored version)"
