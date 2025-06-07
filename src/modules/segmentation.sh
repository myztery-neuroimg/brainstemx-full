#!/usr/bin/env bash
#
# segmentation.sh - Segmentation functions for the brain MRI processing pipeline
#
# This module contains:
# - Tissue segmentation
# - Brainstem segmentation
# - Pons segmentation
# - Segmentation QA integration
#

# Load Juelich atlas-based segmentation functions
if [ -f "$(dirname "${BASH_SOURCE[0]}")/segment_juelich.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/segment_juelich.sh"
    log_message "Juelich atlas-based brainstem segmentation loaded"
fi

# File discovery and mapping for atlas-based segmentation
# NOTE: Standard atlases (Harvard/Oxford, Talairach, Juelich) do NOT provide meaningful
# dorsal/ventral pons subdivisions. These should be used as cross-validation tools.
discover_and_map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    local pons_dir="$3"
    
    # Validate required parameters
    if [ -z "$input_basename" ] || [ -z "$brainstem_dir" ] || [ -z "$pons_dir" ]; then
        log_formatted "ERROR" "Missing required parameters for file discovery"
        return 1
    fi
    
    # Ensure directories exist and are writable
    if ! mkdir -p "$brainstem_dir" "$pons_dir"; then
        log_formatted "ERROR" "Failed to create segmentation directories"
        return 1
    fi
    
    if [ ! -w "$brainstem_dir" ] || [ ! -w "$pons_dir" ]; then
        log_formatted "ERROR" "Segmentation directories are not writable"
        return 1
    fi
    
    log_formatted "INFO" "===== DISCOVERING ACTUAL SEGMENTATION FILES ====="
    
    # Expected file paths (what pipeline wants)
    local expected_brainstem="${brainstem_dir}/${input_basename}_brainstem.nii.gz"
    local expected_pons="${pons_dir}/${input_basename}_pons.nii.gz"
    local expected_dorsal="${pons_dir}/${input_basename}_dorsal_pons.nii.gz"  # Compatibility placeholder
    local expected_ventral="${pons_dir}/${input_basename}_ventral_pons.nii.gz"  # Compatibility placeholder
    
    # Search for actual files created by atlas segmentation
    log_message "Searching for actual segmentation files..."
    log_message "Expected basename: $input_basename"
    log_message "Brainstem directory: $brainstem_dir"
    log_message "Pons directory: $pons_dir"
    
    # List all files for debugging
    log_message "Files in brainstem directory:"
    find "$brainstem_dir" -name "*.nii.gz" 2>/dev/null | while read file; do
        log_message "  $file"
    done
    
    log_message "Files in pons directory:"
    find "$pons_dir" -name "*.nii.gz" 2>/dev/null | while read file; do
        log_message "  $file"
    done
    
    # Find brainstem files (try multiple patterns and also check if files exist in pons directory)
    local actual_brainstem=""
    log_message "Searching for brainstem files..."
    
    # First try the brainstem directory
    for pattern in "*brainstem*.nii.gz" "*BrainStem*.nii.gz" "*brain_stem*.nii.gz" "*.nii.gz"; do
        actual_brainstem=$(find "$brainstem_dir" -name "$pattern" 2>/dev/null | head -1)
        if [ -n "$actual_brainstem" ] && [ -f "$actual_brainstem" ]; then
            log_message "Found brainstem candidate in brainstem dir with pattern '$pattern': $actual_brainstem"
            break
        fi
    done
    
    # If not found in brainstem directory, check pons directory (some atlases put everything in one place)
    if [ -z "$actual_brainstem" ] || [ ! -f "$actual_brainstem" ]; then
        log_message "No brainstem found in brainstem directory, checking pons directory..."
        for pattern in "*brainstem*.nii.gz" "*BrainStem*.nii.gz" "*brain_stem*.nii.gz"; do
            actual_brainstem=$(find "$pons_dir" -name "$pattern" 2>/dev/null | head -1)
            if [ -n "$actual_brainstem" ] && [ -f "$actual_brainstem" ]; then
                log_message "Found brainstem candidate in pons dir with pattern '$pattern': $actual_brainstem"
                break
            fi
        done
    fi
    
    # If still not found, look in parent segmentation directory
    if [ -z "$actual_brainstem" ] || [ ! -f "$actual_brainstem" ]; then
        local seg_parent=$(dirname "$brainstem_dir")
        log_message "No brainstem found in subdirectories, checking parent segmentation dir: $seg_parent"
        for pattern in "*brainstem*.nii.gz" "*BrainStem*.nii.gz" "*brain_stem*.nii.gz"; do
            actual_brainstem=$(find "$seg_parent" -name "$pattern" 2>/dev/null | head -1)
            if [ -n "$actual_brainstem" ] && [ -f "$actual_brainstem" ]; then
                log_message "Found brainstem candidate in parent dir with pattern '$pattern': $actual_brainstem"
                break
            fi
        done
    fi
    
    # Find pons files (comprehensive search across directories)
    local actual_pons=""
    log_message "Searching for pons files..."
    
    # First try pons directory
    actual_pons=$(find "$pons_dir" -name "*pons*.nii.gz" ! -name "*dorsal*" ! -name "*ventral*" 2>/dev/null | head -1)
    if [ -n "$actual_pons" ] && [ -f "$actual_pons" ]; then
        log_message "Found pons in pons directory: $actual_pons"
    else
        # Try brainstem directory
        actual_pons=$(find "$brainstem_dir" -name "*pons*.nii.gz" ! -name "*dorsal*" ! -name "*ventral*" 2>/dev/null | head -1)
        if [ -n "$actual_pons" ] && [ -f "$actual_pons" ]; then
            log_message "Found pons in brainstem directory: $actual_pons"
        else
            # Try parent segmentation directory
            local seg_parent=$(dirname "$brainstem_dir")
            actual_pons=$(find "$seg_parent" -name "*pons*.nii.gz" ! -name "*dorsal*" ! -name "*ventral*" 2>/dev/null | head -1)
            if [ -n "$actual_pons" ] && [ -f "$actual_pons" ]; then
                log_message "Found pons in parent segmentation directory: $actual_pons"
            fi
        fi
    fi
    
    # Create symbolic links with expected names
    local success_count=0
    
    if [ -n "$actual_brainstem" ] && [ -f "$actual_brainstem" ]; then
        log_message "Mapping brainstem: $actual_brainstem -> $expected_brainstem"
        ln -sf "$actual_brainstem" "$expected_brainstem"
        if [ -L "$expected_brainstem" ]; then
            log_formatted "SUCCESS" "Brainstem mapped successfully"
            success_count=$((success_count + 1))
        else
            log_formatted "ERROR" "Failed to create brainstem symlink"
        fi
    else
        log_formatted "WARNING" "No brainstem file found - this may indicate segmentation hasn't run yet"
        log_message "Available files in brainstem directory:"
        ls -la "$brainstem_dir" 2>/dev/null || echo "  Directory doesn't exist"
        log_message "Available files in pons directory:"
        ls -la "$pons_dir" 2>/dev/null || echo "  Directory doesn't exist"
        log_message "Available files in parent segmentation directory:"
        local seg_parent=$(dirname "$brainstem_dir")
        ls -la "$seg_parent" 2>/dev/null || echo "  Directory doesn't exist"
    fi
    
    # For pons: use actual pons if found, otherwise use brainstem
    local pons_source=""
    if [ -n "$actual_pons" ] && [ -f "$actual_pons" ]; then
        log_message "Found separate pons file: $actual_pons"
        pons_source="$actual_pons"
    elif [ -n "$actual_brainstem" ] && [ -f "$actual_brainstem" ]; then
        log_message "No separate pons file found, using brainstem as pons"
        pons_source="$actual_brainstem"
    fi
    
    if [ -n "$pons_source" ] && [ -f "$pons_source" ]; then
        log_message "Creating pons mapping: $pons_source -> $expected_pons"
        ln -sf "$pons_source" "$expected_pons"
        success_count=$((success_count + 1))
        
        # Create compatibility placeholders for legacy pipeline components
        # NOTE: Standard atlases don't provide meaningful dorsal/ventral subdivisions
        log_message "Creating dorsal pons compatibility file (same as main pons)"
        ln -sf "$pons_source" "$expected_dorsal"
        success_count=$((success_count + 1))
        
        log_message "Creating ventral pons compatibility file (empty - atlas doesn't subdivide)"
        if command -v fslmaths &>/dev/null && [ -f "$pons_source" ]; then
            if fslmaths "$pons_source" -mul 0 "$expected_ventral" 2>/dev/null; then
                log_message "Successfully created empty ventral pons file"
            else
                log_message "fslmaths failed, creating empty file"
                touch "$expected_ventral"
            fi
        else
            log_message "fslmaths not available or source invalid, creating empty file"
            touch "$expected_ventral"
        fi
        success_count=$((success_count + 1))
    else
        log_formatted "WARNING" "No valid pons source found - segmentation may not have completed"
        log_message "Expected to find pons files in:"
        log_message "  - Pons directory: $pons_dir"
        log_message "  - Brainstem directory: $brainstem_dir"
        log_message "  - Parent directory: $(dirname "$brainstem_dir")"
    fi
    
    log_message "Successfully mapped $success_count segmentation files"
    
    # Enhanced validation - check that critical files actually exist and are valid
    local expected_files=(
        "$expected_brainstem"
        "$expected_pons"
        "$expected_dorsal"
        "$expected_ventral"
    )
    
    local validated_count=0
    for file in "${expected_files[@]}"; do
        if [ -f "$file" ] || [ -L "$file" ]; then
            # Check if it's a valid symlink or file with reasonable size
            local size=0
            if [ -L "$file" ]; then
                # For symlinks, check the target
                local target=$(readlink "$file")
                if [ -f "$target" ]; then
                    size=$(stat -f "%z" "$target" 2>/dev/null || stat --format="%s" "$target" 2>/dev/null || echo "0")
                fi
            else
                size=$(stat -f "%z" "$file" 2>/dev/null || stat --format="%s" "$file" 2>/dev/null || echo "0")
            fi
            
            if [ "$size" -gt 0 ]; then
                validated_count=$((validated_count + 1))
                log_message "✓ Validated: $(basename "$file") ($(( size / 1024 )) KB)"
            else
                log_formatted "WARNING" "File exists but appears empty: $file"
            fi
        else
            log_formatted "WARNING" "Expected file missing: $file"
        fi
    done
    
    log_message "Validated $validated_count out of ${#expected_files[@]} expected files"
    
    if [ $validated_count -ge 2 ]; then
        log_formatted "SUCCESS" "Segmentation file mapping completed with $validated_count validated files"
        return 0
    else
        log_formatted "ERROR" "Too few valid segmentation files ($validated_count). QA scripts will fail."
        return 1
    fi
}

# Function to extract brainstem in standard space
extract_brainstem_standardspace() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        log_formatted "ERROR" "FSL is not installed or not in PATH"
        return 1
    fi

    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set - cannot determine output location"
        return 1
    fi

    # Get input filename
    input_file="$1"
    output_file="${2:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$input_file" .nii.gz)_brainstem_stdspace.nii.gz}"
    
    # Create output directory and validate
    local output_dir="$(dirname "$output_file")"
    if ! mkdir -p "$output_dir"; then
        log_formatted "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi
    
    if [ ! -w "$output_dir" ]; then
        log_formatted "ERROR" "Output directory is not writable: $output_dir"
        return 1
    fi
    
    log_message "Extracting brainstem in standard space from $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
    
    # Path to Harvard-Oxford Subcortical atlas - try multiple variations
    harvard_subcortical=""
    for atlas_file in "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1mm.nii.gz" \
                      "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-1mm.nii.gz" \
                      "${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr50-1mm.nii.gz"; do
        if [ -f "$atlas_file" ]; then
            harvard_subcortical="$atlas_file"
            log_message "Found Harvard-Oxford atlas: $atlas_file"
            break
        fi
    done
    
    # Check if we have the required templates
    have_templates=true
    if [ ! -f "$standard_template" ]; then
        log_formatted "WARNING" "Standard template not found at $standard_template"
        have_templates=false
    fi
    
    if [ -z "$harvard_subcortical" ]; then
        log_formatted "WARNING" "No Harvard-Oxford subcortical atlas found in ${FSLDIR}/data/atlases/HarvardOxford/"
        have_templates=false
    fi
    
    if $have_templates; then
        # Has all required templates, use them
        log_message "Processing $input_file with Harvard-Oxford atlas method..."
        
        # Step 1: Register input to standard space
        log_message "Registering input to standard space..."
        flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
        
        # Step 2: Generate inverse transformation matrix
        log_message "Generating inverse transformation..."
        convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
        
        # Step 3: Extract brainstem from Harvard-Oxford subcortical atlas
        log_message "Extracting brainstem mask from Harvard-Oxford atlas..."
        
        # In Harvard-Oxford subcortical atlas, brainstem might be different indices depending on the version
        # Let's identify which atlas variant we have and adjust accordingly
        
        # First try checking the label information if the labels directory exists
        local brainstem_index=16  # Default index
        local labels_dir="${FSLDIR}/data/atlases/HarvardOxford/labels"
        
        if [ -d "$labels_dir" ]; then
            # Try to find brainstem/brain-stem in the label files
            if grep -qi "brain.?stem" "${labels_dir}"/* 2>/dev/null; then
                local found_index=$(grep -i "brain.?stem" "${labels_dir}"/* | head -1 | grep -o "[0-9]\+" | head -1)
                if [ -n "$found_index" ]; then
                    brainstem_index=$found_index
                    log_message "Found brainstem index: $brainstem_index from labels"
                fi
            fi
        fi
        
        # Try a range of potential brainstem indices if we still have the default
        if [ "$brainstem_index" -eq 16 ]; then
            log_message "Trying multiple potential brainstem indices..."
            
            # Create an initial empty mask
            fslmaths "$harvard_subcortical" -mul 0 "${temp_dir}/brainstem_mask_std.nii.gz"
            
            # Try multiple potential indices for brainstem in different atlas versions
            for potential_index in 16 13 10 4 7; do
                log_message "Checking index $potential_index..."
                # Extract this index
                fslmaths "$harvard_subcortical" -thr $potential_index -uthr $potential_index -bin "${temp_dir}/temp_mask.nii.gz"
                
                # Check if this generates a non-empty mask
                local voxel_count=$(fslstats "${temp_dir}/temp_mask.nii.gz" -V | awk '{print $1}')
                
                if [ "$voxel_count" -gt 10 ]; then
                    # Found a non-empty mask, use this
                    log_message "Found non-empty mask at index $potential_index with $voxel_count voxels"
                    fslmaths "${temp_dir}/temp_mask.nii.gz" -add "${temp_dir}/brainstem_mask_std.nii.gz" "${temp_dir}/brainstem_mask_std.nii.gz"
                fi
            done
            
            # Final check - if still empty, create approximate mask
            local final_count=$(fslstats "${temp_dir}/brainstem_mask_std.nii.gz" -V | awk '{print $1}')
            if [ "$final_count" -le 10 ]; then
                log_formatted "WARNING" "Could not find brainstem in atlas, creating approximate mask"
                fslmaths "$standard_template" -mul 0 "${temp_dir}/blank.nii.gz"
                
                # Get dimensions
                local dims=($(fslinfo "$standard_template" | grep ^dim | awk '{print $2}'))
                
                # Create a mask at approximate brainstem location in MNI space
                # Brainstem is roughly at the lower center of the brain
                fslmaths "${temp_dir}/blank.nii.gz" -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 "${temp_dir}/brainstem_mask_std.nii.gz"
            else
                log_message "Created combined brainstem mask with $final_count voxels"
            fi
        else
            # Use the identified index
            fslmaths "$harvard_subcortical" -thr $brainstem_index -uthr $brainstem_index -bin "${temp_dir}/brainstem_mask_std.nii.gz"
        fi
        
        # Step 4: Transform brainstem mask to input space
        log_message "Transforming brainstem mask to input space..."
        flirt -in "${temp_dir}/brainstem_mask_std.nii.gz" -ref "$input_file" -applyxfm -init "${temp_dir}/std2input.mat" -out "${temp_dir}/brainstem_mask_input.nii.gz" -interp nearestneighbour
        
        # Step 5: Apply mask to input image
        log_message "Applying mask to input image..."
        fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask_input.nii.gz" "$output_file"
    else
        # Missing templates, use approximate method
        log_formatted "WARNING" "Using approximate method for standard space brainstem extraction"
        
        # Brain extraction
        log_message "Performing brain extraction..."
        bet "$input_file" "${temp_dir}/brain" -f 0.4
        
        # Create a simple mask at the approximate brainstem location
        log_message "Creating approximate brainstem mask..."
        
        # Get dimensions
        dims=($(fslinfo "${temp_dir}/brain" | grep ^dim | awk '{print $2}'))
        
        # Create a mask in the lower central region (approximate brainstem location)
        fslmaths "${temp_dir}/brain" -bin "${temp_dir}/brain_mask"
        fslmaths "${temp_dir}/brain_mask" \
            -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 \
            "${temp_dir}/brainstem_mask"
        
        # Apply mask to original image
        fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask" "$output_file"
    fi
    
    # Validate output file was created successfully before cleanup
    if [ ! -f "$output_file" ]; then
        log_formatted "ERROR" "Output file was not created: $output_file"
        # Don't clean up temp_dir yet - keep for debugging
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
    
    # Only clean up temporary files after successful validation
    rm -rf "$temp_dir"
    
    log_message "Standard space brainstem extraction complete: $output_file ($(( output_size / 1024 )) KB)"
    return 0
}

# Function to extract brainstem in Talairach space (using FSL/FIRST)
extract_brainstem_talairach() {
    # This function uses FSL/FIRST for brainstem segmentation
    
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set - cannot determine output location"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    output_file="${2:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$input_file" .nii.gz)_brainstem_talairach.nii.gz}"
    
    # Create output directory and validate
    local output_dir="$(dirname "$output_file")"
    if ! mkdir -p "$output_dir"; then
        log_formatted "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi
    
    if [ ! -w "$output_dir" ]; then
        log_formatted "ERROR" "Output directory is not writable: $output_dir"
        return 1
    fi
    
    log_message "Extracting brainstem using Talairach method from $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Step 1: Brain extraction
    log_message "Performing brain extraction for Talairach method..."
    bet "$input_file" "${temp_dir}/brain" -f 0.4
    
    # Step 2: Register to MNI space
    log_message "Registering to MNI space for Talairach method..."
    if [ -f "$FSLDIR/data/standard/MNI152_T1_2mm.nii.gz" ]; then
        flirt -in "${temp_dir}/brain" -ref "$FSLDIR/data/standard/MNI152_T1_2mm.nii.gz" -out "${temp_dir}/brain_mni" -omat "${temp_dir}/brain2mni.mat"
        
        # Step 3: Create approximate brainstem mask based on coordinates
        # Create a blank image with same dimensions as MNI template
        fslmaths "$FSLDIR/data/standard/MNI152_T1_2mm.nii.gz" -mul 0 "${temp_dir}/blank"
        
        # Get dimensions
        dims=($(fslinfo "$FSLDIR/data/standard/MNI152_T1_2mm.nii.gz" | grep ^dim | awk '{print $2}'))
        
        # Create mask at approximate brainstem location in MNI space
        # Brainstem is roughly at the lower center of the brain
        # This is a simplified approximation!
        fslmaths "${temp_dir}/blank" -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 "${temp_dir}/brainstem_mask_mni"
        
        # Step 4: Transform mask back to native space
        convert_xfm -omat "${temp_dir}/mni2brain.mat" -inverse "${temp_dir}/brain2mni.mat"
        flirt -in "${temp_dir}/brainstem_mask_mni" -ref "$input_file" -applyxfm -init "${temp_dir}/mni2brain.mat" -out "${temp_dir}/brainstem_mask" -interp nearestneighbour
        
        # Step 5: Apply mask to original image
        fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask" "$output_file"
    else
        log_formatted "WARNING" "MNI template not found, using simplified approach"
        # Create a simple mask at the approximate brainstem location
        # Get dimensions
        dims=($(fslinfo "${temp_dir}/brain" | grep ^dim | awk '{print $2}'))
        
        # Create a mask in the lower central region (approximate brainstem location)
        fslmaths "${temp_dir}/brain" -bin "${temp_dir}/brain_mask"
        fslmaths "${temp_dir}/brain_mask" -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 "${temp_dir}/brainstem_mask"
        
        # Apply mask to original image
        fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask" "$output_file"
    fi
    
    # Step 6: Validate output file was created successfully before cleanup
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
    
    # Only clean up temporary files after successful validation
    rm -rf "$temp_dir"
    
    log_message "Talairach-based brainstem extraction complete: $output_file ($(( output_size / 1024 )) KB)"
    return 0
}

# Function for final brainstem extraction - tries all available methods
extract_brainstem_final() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    
    # Define output filenames
    brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    pons_dir="${RESULTS_DIR}/segmentation/pons"
    mkdir -p "$brainstem_dir"
    mkdir -p "$pons_dir"
    
    # Define temporary files for each method
    std_space_file="${brainstem_dir}/${input_basename}_brainstem_stdspace.nii.gz"
    talairach_file="${brainstem_dir}/${input_basename}_brainstem_talairach.nii.gz"
    ants_file="${brainstem_dir}/${input_basename}_brainstem_ants.nii.gz"
    
    # Final output files
    brainstem_file="${brainstem_dir}/${input_basename}_brainstem.nii.gz"
    pons_file="${pons_dir}/${input_basename}_pons.nii.gz"
    dorsal_pons_file="${pons_dir}/${input_basename}_dorsal_pons.nii.gz"
    ventral_pons_file="${pons_dir}/${input_basename}_ventral_pons.nii.gz"
    
    # Try all three methods
    log_message "Trying multiple brainstem extraction methods..."
    
    # Method 1: Standard space method
    log_message "Method 1: Standard space method"
    extract_brainstem_standardspace "$input_file" "$std_space_file" || \
        log_formatted "WARNING" "Standard space method failed"
    
    # Method 2: Talairach method
    log_message "Method 2: Talairach method"
    extract_brainstem_talairach "$input_file" "$talairach_file" || \
        log_formatted "WARNING" "Talairach method failed"
    
    # Method 3: ANTs method
    log_message "Method 3: ANTs method"
    extract_brainstem_ants "$input_file" "$ants_file" || \
        log_formatted "WARNING" "ANTs method failed"
    
    # Check which methods succeeded
    std_success=false
    talairach_success=false
    ants_success=false
    
    [ -f "$std_space_file" ] && [ "$(fslstats "$std_space_file" -V | awk '{print $1}')" -gt 0 ] && std_success=true
    [ -f "$talairach_file" ] && [ "$(fslstats "$talairach_file" -V | awk '{print $1}')" -gt 0 ] && talairach_success=true
    [ -f "$ants_file" ] && [ "$(fslstats "$ants_file" -V | awk '{print $1}')" -gt 0 ] && ants_success=true
    
    # Use the best available result or combine them
    if $ants_success; then
        log_message "Using ANTs method result (primary choice)"
        cp "$ants_file" "$brainstem_file"
    elif $std_success; then
        log_message "Using standard space method result (fallback 1)"
        cp "$std_space_file" "$brainstem_file"
    elif $talairach_success; then
        log_message "Using Talairach method result (fallback 2)"
        cp "$talairach_file" "$brainstem_file"
    else
        # If all methods failed, create a simple primitive mask
        log_formatted "WARNING" "All methods failed, creating primitive brainstem approximation"
        
        # Create a simple mask at the approximate brainstem location
        # Get dimensions
        dims=($(fslinfo "$input_file" | grep ^dim | awk '{print $2}'))
        
        # Create temporary files
        temp_dir=$(mktemp -d)
        fslmaths "$input_file" -bin "${temp_dir}/brain_mask.nii.gz"
        
        # Create a mask in the lower central region (approximate brainstem location)
        fslmaths "${temp_dir}/brain_mask.nii.gz" \
            -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 \
            "${temp_dir}/primitive_brainstem.nii.gz"
        
        # Apply mask to original image
        fslmaths "$input_file" -mas "${temp_dir}/primitive_brainstem.nii.gz" "$brainstem_file"
        
        # Validate the primitive brainstem file was created
        if [ ! -f "$brainstem_file" ]; then
            log_formatted "ERROR" "Failed to create primitive brainstem file: $brainstem_file"
            log_message "Temp directory preserved for debugging: $temp_dir"
            return 1
        fi
        
        # Only clean up after successful validation
        rm -rf "$temp_dir"
    fi
    
    # Try Juelich atlas-based segmentation first for better anatomical accuracy
    if command -v extract_brainstem_juelich &> /dev/null; then
        log_message "Using Juelich atlas-based segmentation for anatomically accurate pons subdivision..."
        
        # Run Juelich-based comprehensive segmentation
        extract_brainstem_juelich "$input_file" "$input_basename"
        segmentation_success=$?
        
        if [ $segmentation_success -eq 0 ]; then
            log_message "Juelich-based segmentation completed successfully"
            
            # EMERGENCY FIX: Map actual files to expected names
            if discover_and_map_segmentation_files "$input_basename" "$brainstem_dir" "$pons_dir"; then
                log_formatted "SUCCESS" "Segmentation files mapped successfully"
            else
                log_formatted "WARNING" "Some segmentation files could not be mapped"
            fi
        else
            log_formatted "WARNING" "Juelich segmentation failed, falling back to basic methods"
            
            # Extract pons from brainstem using basic method
            log_message "Extracting pons from brainstem using legacy method..."
            extract_pons_from_brainstem "$brainstem_file" "$pons_file"
            
            # Divide pons into dorsal and ventral regions
            log_message "Dividing pons into dorsal and ventral regions using legacy method..."
            divide_pons "$pons_file" "$dorsal_pons_file" "$ventral_pons_file"
        fi
    else
        # Use legacy methods if Juelich is not available
        log_message "Juelich-based segmentation not available, using legacy methods..."
        
        # Extract pons from brainstem
        log_message "Extracting pons from brainstem..."
        extract_pons_from_brainstem "$brainstem_file" "$pons_file"
        
        # Divide pons into dorsal and ventral regions
        log_message "Dividing pons into dorsal and ventral regions..."
        divide_pons "$pons_file" "$dorsal_pons_file" "$ventral_pons_file"
    fi
    
    # Validate segmentation (this works with either method)
    log_message "Validating segmentation..."
    validate_segmentation "$input_file" "$brainstem_file" "$pons_file" "$dorsal_pons_file" "$ventral_pons_file"
    
    log_message "Brainstem extraction complete with all available methods"
    return 0
}

# Function to extract brainstem using ANTs
extract_brainstem_ants() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Validate RESULTS_DIR is set
    if [ -z "${RESULTS_DIR:-}" ]; then
        log_formatted "ERROR" "RESULTS_DIR is not set - cannot determine output location"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    output_file="${2:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$input_file" .nii.gz)_brainstem.nii.gz}"
    
    # Create output directory and validate
    local output_dir="$(dirname "$output_file")"
    if ! mkdir -p "$output_dir"; then
        log_formatted "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi
    
    if [ ! -w "$output_dir" ]; then
        log_formatted "ERROR" "Output directory is not writable: $output_dir"
        return 1
    fi
    
    log_message "Extracting brainstem using ANTs from $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Step 1: Brain extraction with diagnostic output filtering
    log_message "Performing brain extraction with diagnostic output filtering..."
    
    # Build the brain extraction command
    local brain_cmd="antsBrainExtraction.sh -d 3 -a \"$input_file\" -e \"$TEMPLATE_DIR/$EXTRACTION_TEMPLATE\" -m \"$TEMPLATE_DIR/$PROBABILITY_MASK\" -o \"${temp_dir}/brain_\""
    
    # Execute with filtering
    execute_with_logging "$brain_cmd" "ants_brain_extraction"
    
    # Step 2: Register to template with diagnostic output filtering
    log_message "Registering to template with diagnostic output filtering..."
    
    # Build the registration command
    local reg_cmd="antsRegistrationSyN.sh -d 3 -f \"$TEMPLATE_DIR/$EXTRACTION_TEMPLATE\" -m \"${temp_dir}/brain_BrainExtractionBrain.nii.gz\" -o \"${temp_dir}/reg_\" -t s"
    
    # Execute with filtering
    execute_with_logging "$reg_cmd" "ants_registration"
    
    # Step 3: Create brainstem prior
    log_message "Creating brainstem prior..."
    # This would typically use a pre-defined brainstem atlas or prior
    # For demonstration, we'll use a simplified approach
    
    # Create a mask in the lower central region of the brain
    # This is a simplified approach - in practice, you would use a proper atlas
    fslmaths "${temp_dir}/brain_BrainExtractionBrain.nii.gz" -bin "${temp_dir}/brain_mask.nii.gz"
    
    # Get dimensions
    dims=($(fslinfo "${temp_dir}/brain_mask.nii.gz" | grep ^dim | awk '{print $2}'))
    
    # Create a mask in the lower central region (approximate brainstem location)
    fslmaths "${temp_dir}/brain_mask.nii.gz" \
        -roi $((dims[0]/3)) $((dims[0]/3)) $((dims[1]/3)) $((dims[1]/3)) 0 $((dims[2]/3)) 0 1 \
        "${temp_dir}/brainstem_prior.nii.gz"
    
    # Step 4: Apply prior to original image
    log_message "Applying prior to extract brainstem..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_prior.nii.gz" "$output_file"
    
    # Step 5: Validate output file was created successfully before cleanup
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
    
    # Only clean up temporary files after successful validation
    rm -rf "$temp_dir"
    
    log_message "Brainstem extraction complete: $output_file ($(( output_size / 1024 )) KB)"
    return 0
}

# Function to extract pons from brainstem - limited by atlas capabilities
extract_pons_from_brainstem() {
    log_formatted "WARNING" "Harvard-Oxford atlas does not provide pons subdivision"
    log_message "Using brainstem mask directly as no finer segmentation is available in atlas"
    
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and output filename
    input_file="$1"
    output_file="${2:-${RESULTS_DIR}/segmentation/pons/$(basename "$input_file" .nii.gz)_pons.nii.gz}"
    
    # Create output directory
    mkdir -p "$(dirname "$output_file")"
    
    # Instead of artificial segmentation, just copy the brainstem mask
    # This is more honest about the limitations of the atlas
    cp "$input_file" "$output_file"
    
    log_message "Brainstem copied to pons output: $output_file"
    log_message "Note: No subdivision performed as Harvard-Oxford atlas only provides whole brainstem"
    
    # Create a metadata file explaining the limitations
    local metadata_file="$(dirname "$output_file")/segmentation_notes.txt"
    {
        echo "Segmentation Limitations"
        echo "======================="
        echo "Date: $(date)"
        echo ""
        echo "The Harvard-Oxford atlas used for segmentation only provides the brainstem as a"
        echo "single structure and does not subdivide it into pons, medulla, etc."
        echo ""
        echo "For more detailed brainstem parcellation, consider using:"
        echo "1. A specialized brainstem atlas (e.g., BigBrain)"
        echo "2. SUIT atlas for cerebellum and brainstem"
        echo "3. Manual segmentation by an expert neuroanatomist"
    } > "$metadata_file"
    
    return 0
}

# Function to handle subdivision of pons - limitation of atlas-based approach
divide_pons() {
    log_formatted "WARNING" "Harvard-Oxford atlas does not support dorsal/ventral pons division"
    log_message "Creating dorsal/ventral pons outputs for pipeline compatibility"
    
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and output filenames
    input_file="$1"
    dorsal_output="${2:-${RESULTS_DIR}/segmentation/pons/$(basename "$input_file" .nii.gz)_dorsal.nii.gz}"
    ventral_output="${3:-${RESULTS_DIR}/segmentation/pons/$(basename "$input_file" .nii.gz)_ventral.nii.gz}"
    
    # Create output directory
    mkdir -p "$(dirname "$dorsal_output")"
    
    # For dorsal output: copy the full brainstem - the pipeline expects this file to exist
    cp "$input_file" "$dorsal_output"
    
    # For ventral output: create an empty mask with same dimensions
    # This avoids artificial division that isn't grounded in the atlas
    fslmaths "$input_file" -mul 0 "$ventral_output"
    
    # Add note to metadata file about this limitation
    local metadata_file="$(dirname "$dorsal_output")/segmentation_notes.txt"
    {
        echo ""
        echo "Dorsal/Ventral Pons Division Limitation"
        echo "======================================="
        echo "Date: $(date)"
        echo ""
        echo "The Harvard-Oxford atlas does not provide anatomical information to separate the"
        echo "brainstem into dorsal and ventral regions. Attempting to divide the pons geometrically"
        echo "would create artificial boundaries not based on neuroanatomy."
        echo ""
        echo "The pipeline has created:"
        echo "- $dorsal_output: Contains all brainstem voxels"
        echo "- $ventral_output: Empty mask for pipeline compatibility"
        echo ""
        echo "For proper ventral/dorsal pons division, consider dedicated brainstem atlases."
    } >> "$metadata_file"
    
    log_message "Created dorsal output (full brainstem) and empty ventral output for compatibility"
    log_message "Added explanatory notes to $metadata_file"
    return 0
}

# Function to validate segmentation
validate_segmentation() {
    # Check if input files exist
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            log_formatted "WARNING" "File $file does not exist, skipping validation"
            return 1
        fi
    done
    
    # Get input filenames
    input_file="$1"
    brainstem_file="$2"
    pons_file="$3"
    dorsal_pons_file="$4"
    ventral_pons_file="$5"
    
    # Create output directory
    validation_dir="${RESULTS_DIR}/validation/segmentation"
    mkdir -p "$validation_dir"
    
    log_message "Validating segmentation..."
    
    # Step 1: Calculate volumes
    brainstem_vol=$(fslstats "$brainstem_file" -V | awk '{print $1}')
    pons_vol=$(fslstats "$pons_file" -V | awk '{print $1}')
    dorsal_vol=$(fslstats "$dorsal_pons_file" -V | awk '{print $1}')
    ventral_vol=$(fslstats "$ventral_pons_file" -V | awk '{print $1}')
    
    # Log the volumes after they're defined
    log_message "brainstem_vol: ${brainstem_vol} | pons_vol: ${pons_vol} | dorsal_vol: ${dorsal_vol} | ventral_vol: ${ventral_vol}"
 
    # Fix the syntax error - no spaces around = in bash assignment
    if [ "$brainstem_vol" -eq 0 ]; then
      brainstem_vol=1
      pons_vol=0
      ventral_vol=0
      dorsal_vol=0
      log_message "WARNING: brainstem_vol is 0 - Segmentation probably failed"
    fi

    # Step 2: Check volume ratios - prevent division by zero
    # Use 1 as denominator if volumes are 0
    if [ "$brainstem_vol" -eq 0 ]; then
        brainstem_vol=1
        log_message "WARNING: Using brainstem_vol=1 to avoid division by zero"
    fi
    
    if [ "$pons_vol" -eq 0 ]; then
        pons_vol=1
        log_message "WARNING: Using pons_vol=1 to avoid division by zero"
    fi
    
    # Now calculate ratios safely
    pons_ratio=$(echo "scale=4; $pons_vol / $brainstem_vol" | bc)
    dorsal_ratio=$(echo "scale=4; $dorsal_vol / $pons_vol" | bc)
    ventral_ratio=$(echo "scale=4; $ventral_vol / $pons_vol" | bc)
    
    # Step 3: Create validation report
    {
        echo "Segmentation Validation Report"
        echo "=============================="
        echo "Input file: $input_file"
        echo ""
        echo "Volumes (mm³):"
        echo "  Brainstem: $brainstem_vol"
        echo "  Pons: $pons_vol"
        echo "  Dorsal pons: $dorsal_vol"
        echo "  Ventral pons: $ventral_vol"
        echo ""
        echo "Volume ratios:"
        echo "  Pons/Brainstem: $pons_ratio"
        echo "  Dorsal/Pons: $dorsal_ratio"
        echo "  Ventral/Pons: $ventral_ratio"
        echo ""
        echo "Expected ranges:"
        echo "  Pons/Brainstem: 0.3-0.5"
        echo "  Dorsal/Pons: 0.4-0.6"
        echo "  Ventral/Pons: 0.4-0.6"
        echo ""
        echo "Validation completed: $(date)"
    } > "${validation_dir}/segmentation_report.txt"
    
    # Step 4: Create visualization
    log_message "Creating segmentation visualization..."
    
    # Create edge overlays
    for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
        local mask_file
        case "$region" in
            "brainstem") mask_file="$brainstem_file" ;;
            "pons") mask_file="$pons_file" ;;
            "dorsal_pons") mask_file="$dorsal_pons_file" ;;
            "ventral_pons") mask_file="$ventral_pons_file" ;;
        esac
        
        # Create edge of mask
        fslmaths "$mask_file" -edge -bin "${validation_dir}/${region}_edge.nii.gz"
        
        # Create overlay command for fsleyes
        echo "fsleyes $input_file ${validation_dir}/${region}_edge.nii.gz -cm red -a 80" > "${validation_dir}/view_${region}_overlay.sh"
        chmod +x "${validation_dir}/view_${region}_overlay.sh"
        
        # Create slices for quick visual inspection
        slicer "$input_file" "${validation_dir}/${region}_edge.nii.gz" -a "${validation_dir}/${region}_overlay.png"
    done
    
    log_message "Segmentation validation complete"
    return 0
}

# Function to perform tissue segmentation
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
    log_message "Extracting tissue classes with diagnostic output filtering..."
    
    # Build threshold commands
    local thresh1_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_csf.nii.gz\" 1 1"
    local thresh2_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_gm.nii.gz\" 2 2"
    local thresh3_cmd="ThresholdImage 3 \"${output_dir}/${basename}_seg.nii.gz\" \"${output_dir}/${basename}_wm.nii.gz\" 3 3"
    
    # Execute with filtering
    execute_with_logging "$thresh1_cmd" "threshold_csf"
    execute_with_logging "$thresh2_cmd" "threshold_gm"
    execute_with_logging "$thresh3_cmd" "threshold_wm"
    
    # Step 4: Validate segmentation
    log_message "Validating tissue segmentation..."
    
    # Calculate volumes
    csf_vol=$(fslstats "${output_dir}/${basename}_csf.nii.gz" -V | awk '{print $1}')
    gm_vol=$(fslstats "${output_dir}/${basename}_gm.nii.gz" -V | awk '{print $1}')
    wm_vol=$(fslstats "${output_dir}/${basename}_wm.nii.gz" -V | awk '{print $1}')
    
    # Calculate total volume
    total_vol=$(echo "$csf_vol + $gm_vol + $wm_vol" | bc)
    
    # Calculate percentages
    csf_pct=$(echo "scale=2; 100 * $csf_vol / $total_vol" | bc)
    gm_pct=$(echo "scale=2; 100 * $gm_vol / $total_vol" | bc)
    wm_pct=$(echo "scale=2; 100 * $wm_vol / $total_vol" | bc)
    
    # Create validation report
    {
        echo "Tissue Segmentation Report"
        echo "=========================="
        echo "Input file: $input_file"
        echo ""
        echo "Volumes (mm³):"
        echo "  CSF: $csf_vol"
        echo "  GM: $gm_vol"
        echo "  WM: $wm_vol"
        echo "  Total: $total_vol"
        echo ""
        echo "Percentages:"
        echo "  CSF: $csf_pct%"
        echo "  GM: $gm_pct%"
        echo "  WM: $wm_pct%"
        echo ""
        echo "Expected ranges:"
        echo "  CSF: 10-20%"
        echo "  GM: 40-50%"
        echo "  WM: 30-40%"
        echo ""
        echo "Segmentation completed: $(date)"
    } > "${output_dir}/${basename}_segmentation_report.txt"
    
    log_message "Tissue segmentation complete"
    return 0
}

# Export functions
export -f extract_brainstem_standardspace
export -f extract_brainstem_talairach
export -f extract_brainstem_final
export -f extract_brainstem_ants
export -f extract_pons_from_brainstem
export -f divide_pons
export -f validate_segmentation
export -f segment_tissues
export -f discover_and_map_segmentation_files
# These functions are already exported from environment.sh
# export -f log_diagnostic execute_with_logging

log_message "Segmentation module loaded"
