#!/usr/bin/env bash
#
# juelich_segmentation.sh - Clean Juelich atlas-based pons segmentation
#
# Simple FSL-based segmentation using the Juelich atlas for anatomically 
# accurate pons, midbrain, and medulla extraction without SUIT dependencies.
#

# Ensure RESULTS_DIR is absolute path
if [ -n "${RESULTS_DIR}" ] && [[ "$RESULTS_DIR" != /* ]]; then
    export RESULTS_DIR="$(cd "$(dirname "$RESULTS_DIR")" && pwd)/$(basename "$RESULTS_DIR")"
    log_message "Converted RESULTS_DIR to absolute path: $RESULTS_DIR"
fi

# Function to extract pons using Juelich atlas
extract_pons_juelich() {
    local input_file="$1"
    local output_file="${2:-${RESULTS_DIR}/segmentation/pons/$(basename "$input_file" .nii.gz)_pons.nii.gz}"
    
    # Check if input file exists
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $input_file does not exist"
        return 1
    fi
    
    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set - cannot determine output location"
        return 1
    fi
    
    # Create output directory and validate
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
    
    if [ ! -w "$output_dir" ]; then
        log_formatted "ERROR" "Output directory is not writable: $output_dir"
        return 1
    fi
    
    # Convert output_file to absolute path
    if [[ "$output_file" != /* ]]; then
        output_file="$(pwd)/$output_file"
    fi
    
    log_message "Extracting pons using Juelich atlas from $input_file"
    
    # Determine template resolution based on config
    local template_res="${DEFAULT_TEMPLATE_RES:-1mm}"
    local mni_template="${TEMPLATE_DIR}/${EXTRACTION_TEMPLATE}"
    
    # Check if Juelich atlas exists for the current resolution
    local juelich_atlas=""
    if [ "$template_res" = "2mm" ]; then
        juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-2mm.nii.gz"
    else
        juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
    fi
    
    # Fallback to other resolution if primary not found
    if [ ! -f "$juelich_atlas" ]; then
        log_formatted "WARNING" "Juelich atlas not found at $juelich_atlas"
        if [ "$template_res" = "1mm" ]; then
            juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-2mm.nii.gz"
            mni_template="${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz"
            log_message "Trying 2mm Juelich atlas instead..."
        else
            juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
            mni_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
            log_message "Trying 1mm Juelich atlas instead..."
        fi
    fi
    
    if [ ! -f "$juelich_atlas" ]; then
        log_formatted "WARNING" "No Juelich atlas found for any resolution"
        log_message "Falling back to Harvard-Oxford method"
        extract_pons_from_brainstem "$input_file" "$output_file"
        return $?
    fi
    
    log_message "Using Juelich atlas: $juelich_atlas"
    log_message "Using MNI template: $mni_template"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Step 1: Register input to MNI space
    log_message "Registering input to MNI space..."
    flirt -in "$input_file" -ref "$mni_template" -out "${temp_dir}/input_mni.nii.gz" -omat "${temp_dir}/input2mni.mat" -dof 12
    
    if [ $? -ne 0 ]; then
        log_formatted "ERROR" "Registration to MNI failed"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Step 2: Generate inverse transformation
    convert_xfm -omat "${temp_dir}/mni2input.mat" -inverse "${temp_dir}/input2mni.mat"
    
    # Step 3: Extract pons from Juelich atlas (index 105)
    log_message "Extracting pons from Juelich atlas (index 105)..."
    fslmaths "$juelich_atlas" -thr 105 -uthr 105 -bin "${temp_dir}/pons_mni.nii.gz"
    
    # Check if we got any voxels
    local pons_voxels=$(fslstats "${temp_dir}/pons_mni.nii.gz" -V | awk '{print $1}')
    if [ "$pons_voxels" -eq 0 ]; then
        log_formatted "WARNING" "No pons voxels found in Juelich atlas"
        log_message "Falling back to Harvard-Oxford method"
        rm -rf "$temp_dir"
        extract_pons_from_brainstem "$input_file" "$output_file"
        return $?
    fi
    
    log_message "Found $pons_voxels pons voxels in Juelich atlas"
    
    # Step 4: Transform pons mask to subject space
    log_message "Transforming pons mask to subject space..."
    # Use trilinear interpolation first, then threshold to maintain more voxels
    flirt -in "${temp_dir}/pons_mni.nii.gz" -ref "$input_file" -applyxfm -init "${temp_dir}/mni2input.mat" -out "${temp_dir}/pons_subject_tri.nii.gz" -interp trilinear
    
    # Threshold at 0.5 to create binary mask (captures partial volume voxels)
    fslmaths "${temp_dir}/pons_subject_tri.nii.gz" -thr 0.5 -bin "${temp_dir}/pons_subject.nii.gz"
    
    # Step 5: Apply mask to original image to create intensity version
    log_message "Creating intensity-based pons segmentation..."
    log_message "Output will be written to: $output_file"
    
    # Remove any existing file or symlink at the output location
    if [ -L "$output_file" ] || [ -e "$output_file" ]; then
        log_message "Removing existing file/symlink at output location"
        rm -f "$output_file"
    fi
    
    # Apply mask using fslmaths directly
    fslmaths "$input_file" -mas "${temp_dir}/pons_subject.nii.gz" "$output_file"
    
    # Validate output file was created successfully before cleanup
    if [ ! -f "$output_file" ]; then
        log_formatted "ERROR" "Output file was not created: $output_file"
        log_message "Temp directory preserved for debugging: $temp_dir"
        return 1
    fi
    
    # Validate output file has reasonable size
    local output_size=$(stat -f "%z" "$output_file" 2>/dev/null || stat --format="%s" "$output_file" 2>/dev/null || echo "0")
    if [ "$output_size" -lt 1024 ]; then
        log_formatted "ERROR" "Output file appears too small ($output_size bytes): $output_file"
        log_message "Temp directory preserved for debugging: $temp_dir"
        return 1
    fi
    
    # Only clean up after successful validation
    rm -rf "$temp_dir"
    
    log_message "Juelich-based pons extraction complete: $output_file ($(( output_size / 1024 )) KB)"
    return 0
}

# Function to extract all brainstem regions using Juelich atlas
extract_brainstem_juelich() {
    local input_file="$1"
    local output_prefix="${2:-$(basename "$input_file" .nii.gz)}"
    
    # Check if input file exists
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $input_file does not exist"
        return 1
    fi
    
    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set - cannot determine output location"
        return 1
    fi
    
    # Create output directories and validate
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
        log_formatted "ERROR" "Failed to create output directories"
        return 1
    fi
    
    if [ ! -w "$brainstem_dir" ] || [ ! -w "$pons_dir" ]; then
        log_formatted "ERROR" "Output directories are not writable: $brainstem_dir, $pons_dir"
        return 1
    fi
    
    log_message "Extracting brainstem regions using Juelich atlas from $input_file"
    
    # Determine template resolution based on config
    local template_res="${DEFAULT_TEMPLATE_RES:-1mm}"
    local mni_template="${TEMPLATE_DIR}/${EXTRACTION_TEMPLATE}"
    
    # Check if Juelich atlas exists for the current resolution
    local juelich_atlas=""
    if [ "$template_res" = "2mm" ]; then
        juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-2mm.nii.gz"
    else
        juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
    fi
    
    # Fallback to other resolution if primary not found
    if [ ! -f "$juelich_atlas" ]; then
        log_formatted "WARNING" "Juelich atlas not found at $juelich_atlas"
        if [ "$template_res" = "1mm" ]; then
            juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-2mm.nii.gz"
            mni_template="${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz"
            log_message "Trying 2mm Juelich atlas instead..."
        else
            juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
            mni_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
            log_message "Trying 1mm Juelich atlas instead..."
        fi
    fi
    
    if [ ! -f "$juelich_atlas" ]; then
        log_formatted "WARNING" "No Juelich atlas found for any resolution, falling back to standard methods"
        extract_brainstem_standardspace "$input_file"
        return $?
    fi
    
    log_message "Using Juelich atlas: $juelich_atlas"
    log_message "Using MNI template: $mni_template"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Step 1: Register input to MNI space
    log_message "Registering input to MNI space..."
    flirt -in "$input_file" -ref "$mni_template" -out "${temp_dir}/input_mni.nii.gz" -omat "${temp_dir}/input2mni.mat" -dof 12
    
    if [ $? -ne 0 ]; then
        log_formatted "ERROR" "Registration to MNI failed"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Step 2: Generate inverse transformation
    convert_xfm -omat "${temp_dir}/mni2input.mat" -inverse "${temp_dir}/input2mni.mat"
    
    # Step 3: Extract individual brainstem regions
    # Juelich indices: pons=105, midbrain=106, medulla=107
    
    # Extract pons (105)
    log_message "Extracting pons (index 105)..."
    fslmaths "$juelich_atlas" -thr 105 -uthr 105 -bin "${temp_dir}/pons_mni.nii.gz"
    
    # Extract midbrain (106) 
    log_message "Extracting midbrain (index 106)..."
    fslmaths "$juelich_atlas" -thr 106 -uthr 106 -bin "${temp_dir}/midbrain_mni.nii.gz"
    
    # Extract medulla (107)
    log_message "Extracting medulla (index 107)..."
    fslmaths "$juelich_atlas" -thr 107 -uthr 107 -bin "${temp_dir}/medulla_mni.nii.gz"
    
    # Combine all regions for total brainstem
    log_message "Combining regions for total brainstem..."
    fslmaths "${temp_dir}/pons_mni.nii.gz" -add "${temp_dir}/midbrain_mni.nii.gz" -add "${temp_dir}/medulla_mni.nii.gz" "${temp_dir}/brainstem_mni.nii.gz"
    
    # Step 4: Transform all masks to subject space
    local regions=("brainstem" "pons" "midbrain" "medulla")
    for region in "${regions[@]}"; do
        log_message "Transforming $region mask to subject space..."
        # Use trilinear interpolation first, then threshold to maintain more voxels
        flirt -in "${temp_dir}/${region}_mni.nii.gz" -ref "$input_file" -applyxfm -init "${temp_dir}/mni2input.mat" -out "${temp_dir}/${region}_subject_tri.nii.gz" -interp trilinear
        
        # Threshold at 0.5 to create binary mask (captures partial volume voxels)
        fslmaths "${temp_dir}/${region}_subject_tri.nii.gz" -thr 0.5 -bin "${temp_dir}/${region}_subject.nii.gz"
        
        # Create intensity version
        local output_dir
        if [ "$region" = "brainstem" ]; then
            output_dir="$brainstem_dir"
        else
            output_dir="$pons_dir"
        fi
        
        local output_file="${output_dir}/${output_prefix}_${region}.nii.gz"
        local mask_file="${output_dir}/${output_prefix}_${region}_mask.nii.gz"
        
        log_message "Creating $region intensity file: $output_file"
        
        # Remove any existing file or symlink at the output location
        if [ -L "$output_file" ] || [ -e "$output_file" ]; then
            log_message "Removing existing file/symlink for $region"
            rm -f "$output_file"
        fi
        
        # Apply mask using fslmaths directly
        fslmaths "$input_file" -mas "${temp_dir}/${region}_subject.nii.gz" "$output_file"
        
        # Remove any existing mask file
        if [ -L "$mask_file" ] || [ -e "$mask_file" ]; then
            rm -f "$mask_file"
        fi
        
        # Also save the binary mask
        cp "${temp_dir}/${region}_subject.nii.gz" "$mask_file"
        
        # Check if we got any voxels
        local voxel_count=$(fslstats "${temp_dir}/${region}_subject.nii.gz" -V | awk '{print $1}')
        log_message "$region: $voxel_count voxels"
    done
    
    # For compatibility with existing pipeline, create dorsal/ventral pons
    # Since Juelich doesn't subdivide pons, we'll copy pons to both for now
    log_message "Creating dorsal/ventral pons for pipeline compatibility..."
    
    local pons_file="${pons_dir}/${output_prefix}_pons.nii.gz"
    local dorsal_file="${pons_dir}/${output_prefix}_dorsal_pons.nii.gz"
    local ventral_file="${pons_dir}/${output_prefix}_ventral_pons.nii.gz"
    
    if [ -f "$pons_file" ]; then
        # Remove any existing files
        [ -L "$dorsal_file" ] || [ -e "$dorsal_file" ] && rm -f "$dorsal_file"
        [ -L "$ventral_file" ] || [ -e "$ventral_file" ] && rm -f "$ventral_file"
        
        cp "$pons_file" "$dorsal_file"
        
        # Create empty ventral file
        fslmaths "$pons_file" -mul 0 "$ventral_file"
    else
        log_formatted "ERROR" "Pons file not found: $pons_file"
        return 1
    fi
    
    # Validate critical output files exist before cleanup
    local critical_files=(
        "${brainstem_dir}/${output_prefix}_brainstem.nii.gz"
        "${pons_dir}/${output_prefix}_pons.nii.gz"
        "${pons_dir}/${output_prefix}_dorsal_pons.nii.gz"
        "${pons_dir}/${output_prefix}_ventral_pons.nii.gz"
    )
    
    local missing_files=()
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            missing_files+=("$file")
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        log_formatted "ERROR" "Critical output files missing: ${missing_files[*]}"
        log_message "Temp directory preserved for debugging: $temp_dir"
        return 1
    fi
    
    # Only clean up after successful validation
    rm -rf "$temp_dir"
    
    log_message "Juelich-based brainstem extraction complete - all files validated"
    return 0
}

# Export functions
export -f extract_pons_juelich
export -f extract_brainstem_juelich

log_message "Juelich segmentation module loaded"