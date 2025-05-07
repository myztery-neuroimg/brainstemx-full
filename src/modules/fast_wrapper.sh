#!/usr/bin/env bash
#
# fast_wrapper.sh - Wrapper functions for FSL FAST
#
# This module provides robust wrappers for FAST tissue segmentation
# with parallel processing capabilities and compatibility checks

# Process a single file with FAST using ANTs fallback if available
process_tissue_segmentation() {
    local input_file="$1"
    local output_prefix="${2:-}"
    local modality="${3:-T1}"  # T1, T2, SWI, DWI, etc.
    local num_classes="${4:-3}"
    
    # Determine the image type for FAST
    local type_opt=1  # Default to T1 (1=T1, 2=T2, 3=PD)
    case "$modality" in
        T1|t1|MPRAGE|mprage)
            type_opt=1
            ;;
        T2|t2|FLAIR|flair|SPACE|space)
            type_opt=2
            ;;
        PD|pd)
            type_opt=3
            ;;
        SWI|swi|GRE|gre|"T2*"|"t2*")
            # SWI/GRE/T2* - treat as T2 for segmentation purposes
            log_message "Processing $modality as T2-weighted for segmentation"
            type_opt=2
            ;;
        DWI|dwi|DTI|dti|ADC|adc|FA|fa)
            # Diffusion images - intensity properties are different
            log_message "Processing $modality as diffusion-weighted image with special handling"
            # For DWI, use ANTs-only (FAST often fails with diffusion images)
            type_opt=1  # Use T1 setting as fallback but prefer ANTs
            ;;
        *)
            log_formatted "WARNING" "Unknown modality $modality, using filename-based detection"
            
            # Extract basename for pattern matching
            local basename=$(basename "$input_file" .nii.gz | tr '[:upper:]' '[:lower:]')
            
            # Prioritize detection of T1/MPRAGE and FLAIR sequences in filenames
            if [[ "$basename" =~ t1 ]] || [[ "$basename" =~ mprage ]] || [[ "$basename" =~ mp-rage ]] ||
               [[ "$basename" =~ mp_rage ]] || [[ "$basename" =~ t1w ]] || [[ "$basename" =~ "3d_t1" ]]; then
                log_message "T1/MPRAGE pattern detected in filename: $basename"
                type_opt=1
            elif [[ "$basename" =~ flair ]] || [[ "$basename" =~ "t2_flair" ]] || [[ "$basename" =~ "t2-flair" ]] ||
                 [[ "$basename" =~ "space_flair" ]] || [[ "$basename" =~ "t2_space" ]]; then
                log_message "FLAIR pattern detected in filename: $basename"
                type_opt=2
            elif [[ "$basename" =~ t2 ]] || [[ "$basename" =~ tse ]] || [[ "$basename" =~ space ]]; then
                log_message "T2/TSE/SPACE pattern detected in filename: $basename"
                type_opt=2
            elif [[ "$basename" =~ pd ]] || [[ "$basename" =~ proton ]]; then
                log_message "PD pattern detected in filename: $basename"
                type_opt=3
            elif [[ "$basename" =~ swi ]] || [[ "$basename" =~ gre ]] || [[ "$basename" =~ t2[\*] ]]; then
                log_message "SWI/GRE/T2* pattern detected in filename: $basename"
                type_opt=2
            elif [[ "$basename" =~ dwi ]] || [[ "$basename" =~ dti ]] || [[ "$basename" =~ diffusion ]]; then
                log_message "DWI/DTI pattern detected in filename: $basename"
                type_opt=1 # Use T1 setting for diffusion as fallback
            else
                # Final fallback - T1 is usually safer for tissue segmentation
                log_message "No specific modality pattern found in filename, defaulting to T1"
                type_opt=1
            fi
            ;;
    esac
    
    # If no output prefix is provided, create one
    if [ -z "$output_prefix" ]; then
        local dirname=$(dirname "$input_file")
        local basename=$(basename "$input_file" .nii.gz)
        output_prefix="${dirname}/${basename}_seg"
    fi
    
    log_message "Running tissue segmentation on $input_file (modality: $modality)"
    mkdir -p "$(dirname "$output_prefix")"
    
    # First preference: Use ANTs if available
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    if command -v ${ants_bin}/Atropos &>/dev/null; then
        log_message "Using ANTs Atropos for segmentation (preferred)"
        
        # Create a fixed directory within the output directory for intermediate files
        local work_dir="$(dirname "$output_prefix")/work_files"
        mkdir -p "$work_dir"
        
        # Create brain mask using ANTs ThresholdImage
        local brain_mask="${work_dir}/brain_mask.nii.gz"
        ${ants_bin}/ThresholdImage 3 "$input_file" "$brain_mask" 0.01 Inf 1 0
        
        # Run ANTs Atropos for tissue segmentation with better error handling
        log_message "Running ANTs Atropos with robust error handling..."
        
        # First check if the input file has enough variation to support segmentation
        # This helps prevent the "Not enough classes detected to init KMeans" error
        local intensity_range=$(fslstats "$input_file" -R)
        local min_val=$(echo "$intensity_range" | awk '{print $1}')
        local max_val=$(echo "$intensity_range" | awk '{print $2}')
        local range_diff=$(echo "$max_val - $min_val" | bc -l)
        
        if (( $(echo "$range_diff < 0.001" | bc -l) )); then
            log_formatted "WARNING" "Image has insufficient intensity range for segmentation: $range_diff"
            log_message "Creating simple segmentation mask instead of using Atropos"
            
            # Create a simple binary mask instead
            fslmaths "$input_file" -bin "${output_prefix}.nii.gz"
            local result=$?
        else
            # Run Atropos with proper intensity range
            ${ants_bin}/Atropos -d 3 \
                -a "$input_file" \
                -o "${output_prefix}.nii.gz" \
                -c "$num_classes" \
                -m [0.2,1x1x1] \
                -i kmeans[$num_classes] \
                -x "$brain_mask"
            
            local result=$?
        fi
        
        # Keep work files for debugging
        log_message "Keeping work files in $work_dir for debugging"
        
        # If ANTs was successful, create compatibility symlinks for FAST outputs
        if [ $result -eq 0 ]; then
            # Create symbolic links for compatibility with code expecting FAST outputs
            for i in $(seq 0 $((num_classes-1))); do
                # Extract tissue class probability maps using ThresholdImage
                ${ants_bin}/ThresholdImage 3 "${output_prefix}.nii.gz" "${output_prefix}_pve_${i}.nii.gz" $((i+1)) $((i+1)) 1 0
            done
            return 0
        else
            log_formatted "WARNING" "ANTs Atropos failed, falling back to FSL FAST"
        fi
    fi
    
    # Second preference: Use FSL FAST with appropriate options
    log_message "Using FSL FAST for segmentation"
    
    # First check if FAST has pve output option to avoid the -m error
    local has_pve_option=true
    fast -h 2>&1 | grep -q "\-g.*outputs a separate binary image" || has_pve_option=false
    
    # Build the FAST command with safe options
    local fast_cmd="fast -t $type_opt -n $num_classes"
    
    # Use -g (segments) as a safer alternative to -p (pve) which was removed in newer FSL
    # Older FSL used -p, newer uses --pve or just outputs PVE by default
    if [ "$has_pve_option" = "true" ]; then
        fast_cmd="$fast_cmd -g"
    fi
    
    # Execute FAST with appropriate options
    log_message "Running: $fast_cmd -o \"$output_prefix\" \"$input_file\""
    $fast_cmd -o "$output_prefix" "$input_file"
    local result=$?
    
    # Check if the segmentation was successful
    if [ $result -ne 0 ]; then
        log_formatted "ERROR" "FSL FAST segmentation failed with status $result"
        # Create empty files to allow pipeline to continue
        touch "${output_prefix}.nii.gz"
        for i in $(seq 0 $((num_classes-1))); do
            touch "${output_prefix}_pve_${i}.nii.gz"
        done
        return $result
    fi
    
    log_formatted "SUCCESS" "Tissue segmentation completed successfully"
    return 0
}

# Run tissue segmentation in parallel
run_parallel_tissue_segmentation() {
    local input_dir="$1"
    local file_pattern="${2:-*brain.nii.gz}"
    local modality="${3:-T1}"
    local num_classes="${4:-3}"
    local jobs="${5:-$PARALLEL_JOBS}"
    
    log_message "Running parallel tissue segmentation on $input_dir/$file_pattern"
    
    # Define the wrapper function for GNU parallel
    tissue_segmentation_wrapper() {
        local file="$1"
        local mod="$2"
        local classes="$3"
        
        # Create output prefix
        local dirname=$(dirname "$file")
        local basename=$(basename "$file" .nii.gz)
        local output_prefix="${dirname}/${basename}_seg"
        
        # Run segmentation
        process_tissue_segmentation "$file" "$output_prefix" "$mod" "$classes"
        return $?
    }
    
    # Export the function for parallel use
    export -f tissue_segmentation_wrapper
    export -f process_tissue_segmentation
    export -f log_message
    export -f log_formatted
    
    # Run in parallel if GNU parallel is available
    if [ "$jobs" -gt 0 ] && check_parallel &>/dev/null; then
        log_message "Running tissue segmentation in parallel with $jobs jobs"
        
        # Create file list
        find "$input_dir" -name "$file_pattern" -print0 | \
        parallel -0 -j "$jobs" --halt "$PARALLEL_HALT_MODE",fail=1 \
          "tissue_segmentation_wrapper {} \"$modality\" $num_classes"
    else
        log_message "Running tissue segmentation sequentially"
        
        # Process each file sequentially
        find "$input_dir" -name "$file_pattern" | while read -r file; do
            tissue_segmentation_wrapper "$file" "$modality" "$num_classes"
        done
    fi
    
    return 0
}

# Export functions
export -f process_tissue_segmentation
export -f run_parallel_tissue_segmentation

log_message "Fast wrapper module loaded"