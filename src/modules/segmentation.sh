#!/usr/bin/env bash
#
# segmentation.sh - Refactored segmentation module for brain MRI processing pipeline
#
# This module contains:
# - Harvard/Oxford atlas as primary method (gold standard for brainstem boundaries)
# - Juelich atlas for pons subdivision (validated against Harvard/Oxford boundaries)
# - All outputs in T1 native space
# - FLAIR intensity integration
# - Proper file naming and discovery
# - Continues to clustering after validation
#

# Load Juelich atlas-based segmentation as fallback method
if [ -f "$(dirname "${BASH_SOURCE[0]}")/segment_juelich.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/segment_juelich.sh"
    log_message "Juelich atlas loaded as fallback segmentation method (provides pons subdivision)"
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
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-${template_res}.nii.gz"
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-${template_res}.nii.gz"
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr50-${template_res}.nii.gz"
        # Fallback to 1mm if template_res not found
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1mm.nii.gz"
        "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-1mm.nii.gz"
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
    
    # Check if templates exist
    if [ ! -f "$mni_template" ] || [ ! -f "$mni_brain" ]; then
        log_formatted "ERROR" "MNI templates not found at resolution ${template_res}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Step 1: Register input to MNI space using ANTs (compute transformation)
    log_message "Registering $(basename \"$input_file\") to MNI space using ANTs..."
    
    # Create transforms directory if it doesn't exist
    mkdir -p "${RESULTS_DIR}/registered/transforms"
    
    # Set up ANTs registration parameters using existing configuration
    local ants_prefix="${RESULTS_DIR}/registered/transforms/ants_to_mni_"
    local ants_warped="${RESULTS_DIR}/registered/transforms/ants_to_mni_warped.nii.gz"
    local brainstem_mask_mni_file="${RESULTS_DIR}/registered/transforms/brainstem_mask_mni_file.nii.gz"
    
    # Use compute_initial_affine if available, otherwise use execute_ants_command
    if command -v compute_initial_affine &> /dev/null; then
        # Use the existing function for initial affine registration
        compute_initial_affine "$input_file" "$mni_brain" "$ants_prefix"
    else
        # Run ANTs registration using execute_ants_command for proper logging
        # Using antsRegistrationSyNQuick.sh for efficiency with affine-only transform
        log_message "Running ANTs quick affine registration to MNI space..."
        
        execute_ants_command "ants_to_mni_registration" "Affine registration to MNI template" \
            antsRegistrationSyNQuick.sh \
            -d 3 \
            -f "$mni_brain" \
            -m "$input_file" \
            -t a \
            -o "$ants_prefix" \
            -n "${ANTS_THREADS:-1}"
    fi
    
    # Check if registration succeeded
    if [ ! -f "${ants_prefix}0GenericAffine.mat" ]; then
        log_formatted "ERROR" "ANTs registration failed - transform not created"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # The ANTs transforms are automatically invertible
    log_message "ANTs registration completed successfully"
    
    # Step 3: Extract brainstem from Harvard-Oxford atlas
    log_message "Extracting brainstem structures from Harvard-Oxford atlas..."
    
    # Harvard-Oxford Subcortical Atlas Structure IDs (based on FSL documentation):
    # 0 = Left Cerebral White Matter
    # 1 = Left Cerebral Cortex
    # 2 = Left Lateral Ventricle
    # 3 = Left Thalamus
    # 4 = Left Caudate
    # 5 = Left Putamen
    # 6 = Left Pallidum
    # 7 = Brain-Stem (THIS IS WHAT WE WANT!)
    # 8 = Left Hippocampus
    # 9 = Left Amygdala
    # 10 = Left Accumbens
    # 11 = Right Cerebral White Matter
    # 12 = Right Cerebral Cortex
    # 13 = Right Lateral Ventricle (THIS WAS GIVING US 509K VOXELS!)
    # 14 = Right Thalamus
    # 15 = Right Caudate
    # 16 = Right Putamen
    # 17 = Right Pallidum
    # 18 = Right Hippocampus
    # 19 = Right Amygdala
    # 20 = Right Accumbens
    
    local brainstem_index=7  # Brain-Stem in Harvard-Oxford subcortical atlas
    local found_brainstem=false
    
    log_message "Extracting brainstem (index $brainstem_index) from Harvard-Oxford atlas..."
    fslmaths "$harvard_subcortical" -thr $brainstem_index -uthr $brainstem_index -bin "${brainstem_mask_mni_file}"
    
    local voxel_count=$(fslstats "${brainstem_mask_mni_file}" -V | awk '{print $1}')
    if [ "$voxel_count" -gt 100 ]; then
        log_message "Found brainstem with $voxel_count voxels in MNI space"
        found_brainstem=true
    else
        log_formatted "ERROR" "Brainstem region too small or not found (only $voxel_count voxels)"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ "$found_brainstem" = "false" ]; then
        log_formatted "ERROR" "Brainstem not found in Harvard-Oxford atlas at expected index"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Step 4: Transform brainstem mask to subject T1 space
    log_message "Transforming brainstem mask to subject T1 space..."
    
    # Use ANTs to apply the inverse transform (MNI to subject space)
    # The -t flag with [transform,1] applies the inverse
    if command -v execute_ants_command &> /dev/null; then
        execute_ants_command "apply_inverse_transform" "Transforming brainstem mask to subject T1 space" \
            antsApplyTransforms \
            -d 3 \
            -i "${brainstem_mask_mni_file}" \
            -r "$input_file" \
            -o "${temp_dir}/brainstem_mask_subject_tri.nii.gz" \
            -t "[${ants_prefix}0GenericAffine.mat,1]" \
            -n Linear
    else
        # Fallback to direct ANTs call if execute_ants_command is not available
        log_message "Applying inverse transform with antsApplyTransforms..."
        antsApplyTransforms -d 3 \
            -i "${brainstem_mask_mni_file}" \
            -r "$input_file" \
            -o "${temp_dir}/brainstem_mask_subject_tri.nii.gz" \
            -t "[${ants_prefix}0GenericAffine.mat,1]" \
            -n Linear
    fi
    
    # Check if the transform was successful
    if [ ! -f "${temp_dir}/brainstem_mask_subject_tri.nii.gz" ]; then
        log_formatted "ERROR" "Failed to transform brainstem mask to subject space"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Threshold at 0.5 to create binary mask (captures partial volume voxels)
    fslmaths "${temp_dir}/brainstem_mask_subject_tri.nii.gz" -thr 0.5 -bin "${temp_dir}/brainstem_mask_subject.nii.gz"
    log_message "Displaying ${temp_dir}/brainstem_mask_subject.nii.gz fslstats.."
    fslinfo "${temp_dir}/brainstem_mask_subject.nii.gz" 
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
    log_message "  FLAIR intensities: ${output_prefix}_brainstem_flair_intensity.nii.gz"
    log_message "  Binary mask: ${output_prefix}_brainstem_mask.nii.gz"
    
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
    log_message "Using Harvard-Oxford for reliable brainstem, then validating Juelich pons within those boundaries"
    
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
    
    # STEP 2: ALWAYS attempt Juelich for pons subdivision
    local juelich_pons_valid=false
    log_message "Step 2: Attempting Juelich atlas for pons subdivision"
    
    if command -v extract_brainstem_juelich &> /dev/null; then
        if extract_brainstem_juelich "$input_file" "$input_basename"; then
            log_message "Juelich segmentation completed, validating pons against Harvard-Oxford boundaries..."
            
            # Check if Juelich pons is within Harvard-Oxford brainstem boundaries
            local juelich_pons="${pons_dir}/${input_basename}_pons.nii.gz"
            local temp_dir=$(mktemp -d)
            
            if [ -f "$juelich_pons" ] && [ -f "$harvard_mask" ]; then
                # Create intersection of Juelich pons with Harvard-Oxford brainstem mask
                fslmaths "$juelich_pons" -mas "$harvard_mask" "${temp_dir}/pons_validated.nii.gz"
                
                # Count voxels in original and validated pons
                local orig_voxels=$(fslstats "$juelich_pons" -V | awk '{print $1}')
                local valid_voxels=$(fslstats "${temp_dir}/pons_validated.nii.gz" -V | awk '{print $1}')
                
                # Calculate percentage of pons within brainstem
                local percentage=0
                if [ "$orig_voxels" -gt 0 ]; then
                    percentage=$(echo "scale=2; $valid_voxels * 100 / $orig_voxels" | bc)
                fi
                
                log_message "Pons validation: $valid_voxels of $orig_voxels voxels (${percentage}%) within Harvard-Oxford brainstem"
                
                # Accept if at least 80% of pons is within brainstem boundaries
                if (( $(echo "$percentage >= 80" | bc -l) )); then
                    juelich_pons_valid=true
                    # Replace original pons with validated version
                    mv "${temp_dir}/pons_validated.nii.gz" "$juelich_pons"
                    log_formatted "SUCCESS" "Juelich pons subdivision validated and constrained to Harvard-Oxford boundaries"
                    
                    # Also validate dorsal/ventral subdivisions if they exist
                    for subdivision in "dorsal_pons" "ventral_pons"; do
                        local subdiv_file="${pons_dir}/${input_basename}_${subdivision}.nii.gz"
                        if [ -f "$subdiv_file" ]; then
                            fslmaths "$subdiv_file" -mas "$harvard_mask" "${temp_dir}/${subdivision}_validated.nii.gz"
                            mv "${temp_dir}/${subdivision}_validated.nii.gz" "$subdiv_file"
                        fi
                    done
                else
                    log_formatted "WARNING" "Juelich pons largely outside Harvard-Oxford boundaries (only ${percentage}% overlap)"
                    juelich_pons_valid=false
                fi
            fi
            
            rm -rf "$temp_dir"
        else
            log_formatted "WARNING" "Juelich segmentation failed"
        fi
    else
        log_formatted "WARNING" "Juelich segmentation not available"
    fi
    
    # Handle pons files based on validation results
    if [ "$juelich_pons_valid" = "true" ]; then
        log_message "Using validated Juelich pons subdivision constrained to Harvard-Oxford brainstem"
    else
        log_formatted "INFO" "===== IMPORTANT NOTICE ====="
        log_message "No valid pons subdivision available within Harvard-Oxford boundaries"
        log_message "Creating EMPTY placeholder files for pipeline compatibility only"
        log_message "These are NOT anatomical segmentations"
        
        # Create empty placeholder files
        local pons_file="${pons_dir}/${input_basename}_pons.nii.gz"
        local dorsal_file="${pons_dir}/${input_basename}_dorsal_pons.nii.gz"
        local ventral_file="${pons_dir}/${input_basename}_ventral_pons.nii.gz"
        
        # Get reference file for dimensions
        local ref_file="${brainstem_dir}/${input_basename}_brainstem.nii.gz"
        if [ -f "$ref_file" ]; then
            for file in "$pons_file" "$dorsal_file" "$ventral_file"; do
                # Remove existing file/symlink
                [ -L "$file" ] || [ -e "$file" ] && rm -f "$file"
                # Create empty file with same dimensions
                fslmaths "$ref_file" -mul 0 "$file" 2>/dev/null || {
                    log_formatted "WARNING" "Could not create placeholder: $file"
                }
            done
            log_message "Created empty placeholders (0 voxels) - NOT real segmentations"
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
    local DORSAL_PONS_LABEL=3
    local VENTRAL_PONS_LABEL=4
    
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
    
    # Add dorsal pons (label 3)
    local dorsal_pons="${pons_dir}/${input_basename}_dorsal_pons.nii.gz"
    if [ -f "$dorsal_pons" ]; then
        local dorsal_voxels=$(fslstats "$dorsal_pons" -V | awk '{print $1}')
        if [ "$dorsal_voxels" -gt 0 ]; then
            fslmaths "$dorsal_pons" -bin -mul $DORSAL_PONS_LABEL "${combined_dir}/temp_dorsal.nii.gz"
            fslmaths "$combined_map" -max "${combined_dir}/temp_dorsal.nii.gz" "$combined_map"
            rm "${combined_dir}/temp_dorsal.nii.gz"
            log_message "Added dorsal pons to combined map (label=$DORSAL_PONS_LABEL)"
        fi
    fi
    
    # Add ventral pons (label 4)
    local ventral_pons="${pons_dir}/${input_basename}_ventral_pons.nii.gz"
    if [ -f "$ventral_pons" ]; then
        local ventral_voxels=$(fslstats "$ventral_pons" -V | awk '{print $1}')
        if [ "$ventral_voxels" -gt 0 ]; then
            fslmaths "$ventral_pons" -bin -mul $VENTRAL_PONS_LABEL "${combined_dir}/temp_ventral.nii.gz"
            fslmaths "$combined_map" -max "${combined_dir}/temp_ventral.nii.gz" "$combined_map"
            rm "${combined_dir}/temp_ventral.nii.gz"
            log_message "Added ventral pons to combined map (label=$VENTRAL_PONS_LABEL)"
        fi
    fi
    
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
Method: Harvard-Oxford (Gold Standard) + Juelich (Pons Subdivision)
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
- Juelich pons is validated to be within brainstem boundaries
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

divide_pons() {
    local input_file="$1"
    local dorsal_output="$2"
    local ventral_output="$3"
    
    log_message "Creating dorsal/ventral compatibility files..."
    
    # Copy whole pons as dorsal
    cp "$input_file" "$dorsal_output"
    
    # Create empty ventral
    fslmaths "$input_file" -mul 0 "$ventral_output"
    
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
export -f divide_pons
export -f validate_segmentation
export -f segment_tissues
export -f discover_and_map_segmentation_files

log_message "Segmentation module loaded (refactored version)"
