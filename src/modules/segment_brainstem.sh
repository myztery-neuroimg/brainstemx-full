#!/bin/bash

extract_brainstem() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to Juelich atlas - adjust if your FSL installation has it elsewhere
    juelich_atlas="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.nii.gz"
    juelich_xml="${FSLDIR}/data/atlases/Juelich/Juelich-maxprob-thr25-1mm.xml"
    
    if [ ! -f "$juelich_atlas" ]; then
        echo "Error: Juelich atlas not found at $juelich_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir="./temp"
    mkdir -p "$temp_dir"
    
    echo "Processing $input_file..."
    
    # Get indices for pons, midbrain, and medulla from Juelich atlas
    pons_index=$(atlasquery -a "$juelich_xml" | grep -i "Pons" | head -n 1 | sed 's/.*<index>\([0-9]*\)<\/index>.*/\1/')
    midbrain_index=$(atlasquery -a "$juelich_xml" | grep -i "Midbrain" | head -n 1 | sed 's/.*<index>\([0-9]*\)<\/index>.*/\1/')
    medulla_index=$(atlasquery -a "$juelich_xml" | grep -i "Medulla" | head -n 1 | sed 's/.*<index>\([0-9]*\)<\/index>.*/\1/')
    
    # If indices not found, use default values that are commonly associated with these regions
    if [ -z "$pons_index" ]; then pons_index=105; fi
    if [ -z "$midbrain_index" ]; then midbrain_index=106; fi 
    if [ -z "$medulla_index" ]; then medulla_index=107; fi
    
    echo "Using atlas indices: Pons=$pons_index, Midbrain=$midbrain_index, Medulla=$medulla_index"
    
    # Extract each region and combine
    echo "Extracting brainstem regions..."
    fslmaths "$juelich_atlas" -thr "$pons_index" -uthr "$pons_index" -bin "${temp_dir}/pons_mask.nii.gz"
    fslmaths "$juelich_atlas" -thr "$midbrain_index" -uthr "$midbrain_index" -bin "${temp_dir}/midbrain_mask.nii.gz"
    fslmaths "$juelich_atlas" -thr "$medulla_index" -uthr "$medulla_index" -bin "${temp_dir}/medulla_mask.nii.gz"
    
    # Combine all regions
    fslmaths "${temp_dir}/pons_mask.nii.gz" -add "${temp_dir}/midbrain_mask.nii.gz" -add "${temp_dir}/medulla_mask.nii.gz" -bin "${temp_dir}/brainstem_mask.nii.gz"
    
    # First let's check and display the dimensions of both images
    echo "Input image dimensions:"
    fslinfo "$input_file" | grep dim
    echo "Atlas mask dimensions:"
    fslinfo "${temp_dir}/brainstem_mask.nii.gz" | grep dim
    
    # Resample the mask to match the input image dimensions
    echo "Resampling mask to match input dimensions..."
    flirt -in "${temp_dir}/brainstem_mask.nii.gz" -ref "$input_file" -out "${temp_dir}/resampled_mask.nii.gz" -interp nearestneighbour

    
    # Ensure the mask is binary after resampling
    fslmaths "${temp_dir}/resampled_mask.nii.gz" -bin "${temp_dir}/resampled_mask.nii.gz"
    
    # Apply the resampled mask to the input
    echo "Applying resampled mask to image..."
    fslmaths "$input_file" -mas "${temp_dir}/resampled_mask.nii.gz" "$output_file"
    
    echo "Completed. Brainstem extracted to: $output_file"
    return 0
}

extract_brainstem "$1"

