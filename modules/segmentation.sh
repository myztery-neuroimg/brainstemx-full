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

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
    
    # Path to Harvard-Oxford Subcortical atlas (more reliable than Talairach for this task)
    harvard_subcortical="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1m.nii.gz"
    
    if [ ! -f "$standard_template" ]; then
        log_formatted "ERROR" "Standard template not found at $standard_template"
        return 1
    fi
    
    if [ ! -f "$harvard_subcortical" ]; then
        log_formatted "ERROR" "Harvard-Oxford subcortical atlas not found at $harvard_subcortical"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    log_message "Processing $input_file..."
    
    # Step 1: Register input to standard space
    log_message "Registering input to standard space..."
    flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
    
    # Step 2: Generate inverse transformation matrix
    log_message "Generating inverse transformation..."
    convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
    
    # Step 3: Extract brainstem from Harvard-Oxford subcortical atlas
    log_message "Extracting brainstem mask from Harvard-Oxford atlas..."
    # In Harvard-Oxford subcortical atlas, brainstem is index 16
    fslmaths "$harvard_subcortical" -thr 16 -uthr 16 -bin "${temp_dir}/brainstem_mask_std.nii.gz"
    
    # Step 4: Transform brainstem mask to input space
    log_message "Transforming brainstem mask to input space..."
    flirt -in "${temp_dir}/brainstem_mask_std.nii.gz" -ref "$input_file" -applyxfm -init "${temp_dir}/std2input.mat" -out "${temp_dir}/brainstem_mask_input.nii.gz" -interp nearestneighbour
    
    # Step 5: Apply mask to input image
    log_message "Applying mask to input image..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask_input.nii.gz" "$output_file"
    
    # Step 6: Clean up temporary files
    rm -rf "$temp_dir"
    
    log_message "Brainstem extraction complete: $output_file"
    return 0
}

# Function to extract brainstem in Talairach space (using FSL/FIRST)
extract_brainstem_talairach() {
    # This function uses FSL/FIRST for brainstem segmentation
    # It will be conditionally bypassed in favor of ANTs-based methods
    
    log_formatted "WARNING" "extract_brainstem_talairach uses FSL/FIRST and is deprecated"
    log_message "Please use extract_brainstem_ants instead"
    
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem_talairach.nii.gz"
    
    log_message "This function is deprecated and will not perform any operation"
    log_message "Please use extract_brainstem_ants instead"
    
    # Return success without doing anything
    return 0
}

# Function for final brainstem extraction
extract_brainstem_final() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filenames
    brainstem_file="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem.nii.gz"
    pons_file="${RESULTS_DIR}/segmentation/pons/${input_basename}_pons.nii.gz"
    dorsal_pons_file="${RESULTS_DIR}/segmentation/pons/${input_basename}_dorsal_pons.nii.gz"
    ventral_pons_file="${RESULTS_DIR}/segmentation/pons/${input_basename}_ventral_pons.nii.gz"
    
    # Create output directories
    mkdir -p "${RESULTS_DIR}/segmentation/brainstem"
    mkdir -p "${RESULTS_DIR}/segmentation/pons"
    
    # Use ANTs-based method for brainstem extraction
    log_message "Extracting brainstem using ANTs..."
    extract_brainstem_ants "$input_file" "$brainstem_file"
    
    # Extract pons from brainstem
    log_message "Extracting pons from brainstem..."
    extract_pons_from_brainstem "$brainstem_file" "$pons_file"
    
    # Divide pons into dorsal and ventral regions
    log_message "Dividing pons into dorsal and ventral regions..."
    divide_pons "$pons_file" "$dorsal_pons_file" "$ventral_pons_file"
    
    # Validate segmentation
    log_message "Validating segmentation..."
    validate_segmentation "$input_file" "$brainstem_file" "$pons_file" "$dorsal_pons_file" "$ventral_pons_file"
    
    log_message "Brainstem extraction complete"
    return 0
}

# Function to extract brainstem using ANTs
extract_brainstem_ants() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    # Get input filename and directory
    input_file="$1"
    output_file="${2:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$input_file" .nii.gz)_brainstem.nii.gz}"
    
    # Create output directory
    mkdir -p "$(dirname "$output_file")"
    
    log_message "Extracting brainstem using ANTs from $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Step 1: Brain extraction
    log_message "Performing brain extraction..."
    antsBrainExtraction.sh -d 3 \
        -a "$input_file" \
        -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
        -o "${temp_dir}/brain_"
    
    # Step 2: Register to template
    log_message "Registering to template..."
    antsRegistrationSyN.sh -d 3 \
        -f "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "${temp_dir}/brain_BrainExtractionBrain.nii.gz" \
        -o "${temp_dir}/reg_" \
        -t s
    
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
    
    # Step 5: Clean up temporary files
    rm -rf "$temp_dir"
    
    log_message "Brainstem extraction complete: $output_file"
    return 0
}

# Function to extract pons from brainstem
extract_pons_from_brainstem() {
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
    
    log_message "Extracting pons from brainstem: $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Step 1: Get dimensions of brainstem
    dims=($(fslinfo "$input_file" | grep ^dim | awk '{print $2}'))
    
    # Step 2: Create a mask for the middle third of the brainstem (approximate pons location)
    # This is a simplified approach - in practice, you would use a proper atlas
    fslmaths "$input_file" -bin "${temp_dir}/brainstem_mask.nii.gz"
    
    # Create a mask for the middle third in the z-direction
    fslmaths "${temp_dir}/brainstem_mask.nii.gz" \
        -roi 0 ${dims[0]} 0 ${dims[1]} $((dims[2]/3)) $((dims[2]/3)) 0 1 \
        "${temp_dir}/pons_mask.nii.gz"
    
    # Step 3: Apply mask to brainstem
    fslmaths "$input_file" -mas "${temp_dir}/pons_mask.nii.gz" "$output_file"
    
    # Step 4: Clean up temporary files
    rm -rf "$temp_dir"
    
    log_message "Pons extraction complete: $output_file"
    return 0
}

# Function to divide pons into dorsal and ventral regions
divide_pons() {
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
    
    log_message "Dividing pons into dorsal and ventral regions: $input_file"
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    # Step 1: Get dimensions of pons
    dims=($(fslinfo "$input_file" | grep ^dim | awk '{print $2}'))
    
    # Step 2: Create masks for dorsal and ventral regions
    # This is a simplified approach - in practice, you would use a proper atlas
    
    # Create a mask for the upper half (dorsal)
    fslmaths "$input_file" -bin "${temp_dir}/pons_mask.nii.gz"
    
    # Divide in the anterior-posterior direction (y-axis)
    fslmaths "${temp_dir}/pons_mask.nii.gz" \
        -roi 0 ${dims[0]} 0 $((dims[1]/2)) 0 ${dims[2]} 0 1 \
        "${temp_dir}/dorsal_mask.nii.gz"
    
    fslmaths "${temp_dir}/pons_mask.nii.gz" \
        -roi 0 ${dims[0]} $((dims[1]/2)) $((dims[1]/2)) 0 ${dims[2]} 0 1 \
        "${temp_dir}/ventral_mask.nii.gz"
    
    # Step 3: Apply masks to pons
    fslmaths "$input_file" -mas "${temp_dir}/dorsal_mask.nii.gz" "$dorsal_output"
    fslmaths "$input_file" -mas "${temp_dir}/ventral_mask.nii.gz" "$ventral_output"
    
    # Step 4: Clean up temporary files
    rm -rf "$temp_dir"
    
    log_message "Pons division complete: $dorsal_output, $ventral_output"
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
    
    # Step 2: Check volume ratios
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
    
    Atropos -d 3 \
        -a "$brain_file" \
        -x "$brain_mask" \
        -o "[${output_dir}/${basename}_seg.nii.gz,${output_dir}/${basename}_prob%02d.nii.gz]" \
        -c "[${ATROPOS_CONVERGENCE}]" \
        -m "${ATROPOS_MRF}" \
        -i "${ATROPOS_INIT_METHOD}[${ATROPOS_T1_CLASSES}]" \
        -k Gaussian
    
    # Step 3: Extract tissue classes
    log_message "Extracting tissue classes..."
    
    # Typical labeling: 1=CSF, 2=GM, 3=WM
    ThresholdImage 3 "${output_dir}/${basename}_seg.nii.gz" "${output_dir}/${basename}_csf.nii.gz" 1 1
    ThresholdImage 3 "${output_dir}/${basename}_seg.nii.gz" "${output_dir}/${basename}_gm.nii.gz" 2 2
    ThresholdImage 3 "${output_dir}/${basename}_seg.nii.gz" "${output_dir}/${basename}_wm.nii.gz" 3 3
    
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

log_message "Segmentation module loaded"