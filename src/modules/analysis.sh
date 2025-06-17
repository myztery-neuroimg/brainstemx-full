#!/usr/bin/env bash
#
# analysis.sh - Analysis functions for the brain MRI processing pipeline
#
# This module contains:
# - Hyperintensity detection
# - Cluster analysis
# - Volume quantification
# - Analysis QA integration
#

# Function to detect hyperintensities with improved false positive reduction
detect_hyperintensities() {
    # Usage: detect_hyperintensities <FLAIR_input.nii.gz> <output_prefix> [<T1_input.nii.gz>]
    #
    # Enhanced version with:
    # 1) FSL FAST posterior probability maps for better WM gating
    # 2) Cluster-based filtering to remove speckles
    # 3) Connected-components size filter
    # 4) Cortical ribbon exclusion to reduce false positives
    #
    # Example:
    # detect_hyperintensities T2_SPACE_FLAIR_Sag.nii.gz results/hyper_flair T1_MPRAGE_SAG.nii.gz

    local flair_file="$1"
    local out_prefix="$2"
    local t1_file="${3}"   # optional

    if [ ! -f "$flair_file" ]; then
        log_formatted "ERROR" "FLAIR file not found: $flair_file"
        return 1
    fi

    mkdir -p "$(dirname "$out_prefix")"

    log_message "=== Enhanced Hyperintensity Detection ==="
    log_message "FLAIR input: $flair_file"
    if [ -n "$t1_file" ]; then
        log_message "Using T1 for segmentation: $t1_file"
    else
        log_message "No T1 file provided, will fallback to intensity-based segmentation"
    fi

    # 1) Brain extraction for the FLAIR
    local flair_basename
    flair_basename=$(basename "$flair_file" .nii.gz)
    local brainextr_dir
    brainextr_dir="$(dirname "$out_prefix")/${flair_basename}_brainextract"

    mkdir -p "$brainextr_dir"

    # Determine ANTs bin path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Execute brain extraction using enhanced ANTs command execution
    execute_ants_command "brain_extraction_flair" "Brain extraction for FLAIR hyperintensity analysis" \
      ${ants_bin}/antsBrainExtraction.sh \
      -d 3 \
      -a "$flair_file" \
      -o "${brainextr_dir}/" \
      -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
      -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
      -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
      -k 1

    local flair_brain="${brainextr_dir}/BrainExtractionBrain.nii.gz"
    local flair_mask="${brainextr_dir}/BrainExtractionMask.nii.gz"

    # 2) Improved Tissue Segmentation using FSL FAST
    # We'll use FAST for posterior probability maps for more accurate tissue segmentation
    local segmentation_out="${out_prefix}_fast_seg.nii.gz"
    local wm_mask="${out_prefix}_wm_mask.nii.gz"
    local gm_mask="${out_prefix}_gm_mask.nii.gz"
    local wm_prob="${out_prefix}_wm_prob.nii.gz"
    local supratentorial_mask="${out_prefix}_supratentorial_mask.nii.gz"
    local cortical_ribbon_mask="${out_prefix}_cortical_ribbon_mask.nii.gz"

    # Create a temporary directory for intermediate files
    local temp_dir=$(mktemp -d)

    if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
        log_message "Using T1 for high-quality tissue segmentation"
        t1_registered="${out_prefix}_T1_registered.nii.gz"
        
        # Check if T1 and FLAIR have matching dimensions, otherwise register
        local t1_dims=$(fslinfo "$t1_file" | grep ^dim | awk '{print $2}' | paste -sd ",")
        local flair_dims=$(fslinfo "$flair_brain" | grep ^dim | awk '{print $2}' | paste -sd ",")
        
        if [ "$t1_dims" = "$flair_dims" ]; then
            log_message "T1 and FLAIR have matching dimensions. Skipping registration."
            cp "$t1_file" "$t1_registered"
        else
            log_message "Registering T1 to FLAIR for consistent dimensionality"
            flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -dof 6
        fi

        # Run FSL FAST for high-quality tissue segmentation with posterior probability maps
        log_message "Running FSL FAST for tissue segmentation with posterior probability maps"
        
        # Extract T1 brain if not already extracted
        if [ ! -f "${out_prefix}_T1_brain.nii.gz" ]; then
            bet "$t1_registered" "${out_prefix}_T1_brain.nii.gz" -f 0.5 -R
        fi
        
        # Run FAST on T1 brain
        fast -t 1 -n 3 -o "${temp_dir}/fast" "${out_prefix}_T1_brain.nii.gz"
        
        # Copy segmentation to final location
        cp "${temp_dir}/fast_seg.nii.gz" "$segmentation_out"
        
        # Get tissue probability maps
        cp "${temp_dir}/fast_pve_0.nii.gz" "${out_prefix}_csf_prob.nii.gz"  # CSF
        cp "${temp_dir}/fast_pve_1.nii.gz" "$gm_mask"  # GM probability
        cp "${temp_dir}/fast_pve_2.nii.gz" "$wm_prob"  # WM probability
        
        # Create binary WM mask from probability map (threshold at 0.9)
        fslmaths "$wm_prob" -thr 0.9 -bin "$wm_mask"

    else
        # Fallback to FSL FAST on FLAIR directly
        log_message "No T1 provided; using FSL FAST segmentation on FLAIR"
        
        # Run FAST on FLAIR brain
        fast -t 2 -n 3 -o "${temp_dir}/fast" "$flair_brain"
        
        # Copy segmentation to final location
        cp "${temp_dir}/fast_seg.nii.gz" "$segmentation_out"
        
        # Get tissue probability maps
        cp "${temp_dir}/fast_pve_0.nii.gz" "${out_prefix}_csf_prob.nii.gz"  # CSF
        cp "${temp_dir}/fast_pve_1.nii.gz" "$gm_mask"  # GM probability
        cp "${temp_dir}/fast_pve_2.nii.gz" "$wm_prob"  # WM probability
        
        # Create binary WM mask from probability map (threshold at 0.9)
        fslmaths "$wm_prob" -thr 0.9 -bin "$wm_mask"
    fi
    
    # Create a supratentorial mask (excluding brainstem and cerebellum)
    # Erode the whole brain mask 3 times from the bottom to approximate supratentorial region
    local brain_mask="${out_prefix}_brain_mask.nii.gz"
    fslmaths "$flair_brain" -bin "$brain_mask"
    
    # Get dimensions
    local dims=($(fslinfo "$brain_mask" | grep ^dim | awk '{print $2}'))
    local z_dim=${dims[2]}
    local z_20percent=$(echo "$z_dim * 0.2" | bc | cut -d. -f1)
    
    # Create a mask excluding the lower 20% of the brain (approximating infratentorial regions)
    fslmaths "$brain_mask" -roi 0 -1 0 -1 $z_20percent -1 0 1 -binv -mul "$brain_mask" "$supratentorial_mask"
    
    # Create a cortical ribbon mask (GM/WM boundary)
    fslmaths "$wm_mask" -dilate -sub "$wm_mask" -mul "$gm_mask" -bin "$cortical_ribbon_mask"
    
    # 3) Compute WM stats to define threshold, using the WM probability map for weighting
    local mean_wm
    local sd_wm
    mean_wm=$(fslstats "$flair_brain" -k "$wm_mask" -M)
    sd_wm=$(fslstats "$flair_brain" -k "$wm_mask" -S)
    log_message "WM mean: $mean_wm   WM std: $sd_wm"

    # Use the global THRESHOLD_WM_SD_MULTIPLIER or default to 2.0 if not set
    local threshold_multiplier="${THRESHOLD_WM_SD_MULTIPLIER:-2.0}"
    log_message "Using threshold multiplier from config: $threshold_multiplier"
    
    # Create default thresholds along with the configured one
    local thresholds=(1.5 2.0 2.5 3.0)
    
    # Make sure the configured threshold is included
    local configured_included=false
    for thresh in "${thresholds[@]}"; do
        if [ "$thresh" = "$threshold_multiplier" ]; then
            configured_included=true
            break
        fi
    done
    
    # If configured threshold isn't in the defaults, add it
    if [ "$configured_included" = false ]; then
        thresholds+=("$threshold_multiplier")
        # Sort the thresholds
        IFS=$'\n' thresholds=($(sort -n <<<"${thresholds[*]}"))
        unset IFS
    fi
    
    log_message "Using thresholds: ${thresholds[*]}"
    
    # Create multiple thresholds with improved filtering
    for mult in "${thresholds[@]}"; do
        local thr_val
        thr_val=$(echo "$mean_wm + $mult * $sd_wm" | bc -l)
        log_message "Threshold = WM_mean + $mult * WM_SD = $thr_val"
        
        # Threshold FLAIR brain
        local init_thr="${out_prefix}_init_thr_${mult}.nii.gz"
        ThresholdImage 3 "$flair_brain" "$init_thr" "$thr_val" 999999 "$flair_mask"
        
        # Combine with tissue masks - focus on supratentorial white matter
        # Weight by WM probability to prioritize hyperintensities in WM
        local tissue_mask="${out_prefix}_target_tissue_${mult}.nii.gz"
        
        # Combine WM probability (weighted) with the supratentorial mask
        fslmaths "$wm_prob" -mul "$supratentorial_mask" -thr 0.5 "$tissue_mask"
        
        # Exclude cortical ribbon to reduce false positives at GM/CSF boundary
        fslmaths "$tissue_mask" -sub "$cortical_ribbon_mask" -thr 0 "$tissue_mask"
        
        # Apply tissue mask to thresholded image
        local combined_thr="${out_prefix}_combined_thr_${mult}.nii.gz"
        fslmaths "$init_thr" -mas "$tissue_mask" "$combined_thr"
        
        # Improved morphological cleanup
        local cleaned="${out_prefix}_cleaned_${mult}.nii.gz"
        
        # Use FSL's -cluster option to remove speckles
        # Default threshold of 2 voxels for initial cleaning
        fslmaths "$combined_thr" -bin -cluster --thresh=2 -oindex "$cleaned"
        
        # Further cleanup with connected components analysis
        # Use configurable minimum cluster size from the config file (default: 2)
        local min_size="${MIN_HYPERINTENSITY_SIZE:-2}"
        log_message "Using minimum hyperintensity size from config: $min_size"
        
        local final_mask="${out_prefix}_thresh${mult}.nii.gz"
        
        # Using cluster command for more efficient connected components analysis
        cluster --in="$cleaned" --thresh=0.5 --osize="${out_prefix}_cluster_sizes_${mult}" \
                --connectivity=26 --minextent=$min_size --oindex="$final_mask"
        
        log_message "Final hyperintensity mask (threshold $mult) saved to: $final_mask"
        
        # Create binary version for analysis
        fslmaths "$final_mask" -bin "${out_prefix}_thresh${mult}_bin.nii.gz"
    done
    
    # Clean up temporary files
    rm -rf "$temp_dir"

    # 5) Optional: Convert to .mgz or create a freeview script
    local flair_norm_mgz="${out_prefix}_flair.mgz"
    local hyper_clean_mgz="${out_prefix}_hyper.mgz"
    mri_convert "$flair_brain" "$flair_norm_mgz"
    mri_convert "${out_prefix}_thresh2.0.nii.gz" "$hyper_clean_mgz"

    cat > "${out_prefix}_view_in_freeview.sh" << EOC
#!/usr/bin/env bash
freeview -v "$flair_norm_mgz" \\
         -v "$hyper_clean_mgz":colormap=heat:opacity=0.5
EOC
    chmod +x "${out_prefix}_view_in_freeview.sh"

    log_message "Hyperintensity detection complete. To view in freeview, run: ${out_prefix}_view_in_freeview.sh"
    
    # Perform cluster analysis using the configured threshold
    analyze_clusters "${out_prefix}_thresh${threshold_multiplier}_bin.nii.gz" "${out_prefix}_clusters"
    
    # Quantify volumes
    quantify_volumes "$out_prefix"
    
    return 0
}

# Function to analyze clusters
analyze_clusters() {
    local input_mask="$1"
    local output_prefix="$2"
    
    if [ ! -f "$input_mask" ]; then
        log_formatted "ERROR" "Input mask not found: $input_mask"
        return 1
    fi
    
    log_message "Analyzing clusters in $input_mask"
    
    # Create output directory
    mkdir -p "$(dirname "$output_prefix")"
    
    # Run cluster analysis
    cluster --in="$input_mask" \
            --thresh=0.5 \
            --oindex="${output_prefix}" \
            --connectivity=26 \
            --mm > "${output_prefix}.txt"
    
    # Get number of clusters
    local num_clusters=$(wc -l < "${output_prefix}.txt")
    num_clusters=$((num_clusters - 1))  # Subtract header line
    
    log_message "Found $num_clusters clusters"
    
    # Create cluster visualization
    if [ -f "${output_prefix}.nii.gz" ]; then
        # Create overlay command for fsleyes
        echo "fsleyes $input_mask ${output_prefix}.nii.gz -cm random -a 80" > "${output_prefix}_view.sh"
        chmod +x "${output_prefix}_view.sh"
    fi
    
    # Analyze cluster sizes
    if [ -f "${output_prefix}.txt" ]; then
        # Skip header line and sort by cluster size (descending)
        tail -n +2 "${output_prefix}.txt" | sort -k2,2nr > "${output_prefix}_sorted.txt"
        
        # Get largest cluster size
        local largest_cluster=$(head -1 "${output_prefix}_sorted.txt" | awk '{print $2}')
        
        # Get total volume
        local total_volume=$(awk '{sum+=$2} END {print sum}' "${output_prefix}_sorted.txt")
        
        # Calculate statistics
        local mean_volume=$(awk '{sum+=$2; count+=1} END {print sum/count}' "${output_prefix}_sorted.txt")
        
        # Create summary report
        {
            echo "Cluster Analysis Report"
            echo "======================="
            echo "Input mask: $input_mask"
            echo "Number of clusters: $num_clusters"
            echo "Total volume: $total_volume mm³"
            echo "Largest cluster: $largest_cluster mm³"
            echo "Mean cluster size: $mean_volume mm³"
            echo ""
            echo "Top 10 clusters by size:"
            head -10 "${output_prefix}_sorted.txt"
            echo ""
            echo "Analysis completed: $(date)"
        } > "${output_prefix}_report.txt"
        
        log_message "Cluster analysis complete. Report saved to: ${output_prefix}_report.txt"
    else
        log_formatted "WARNING" "Cluster analysis failed. No output file created."
        return 1
    fi
    
    return 0
}

# Function to quantify volumes
quantify_volumes() {
    local prefix="$1"
    local output_file="${prefix}_volumes.csv"
    
    log_message "Quantifying volumes for $prefix"
    
    # Create CSV header
    echo "Threshold,Volume (mm³),NumClusters,LargestCluster (mm³)" > "$output_file"
    
    # Process each threshold
    for mult in 1.5 2.0 2.5 3.0; do
        local mask_file="${prefix}_thresh${mult}_bin.nii.gz"
        local cluster_file="${prefix}_clusters.txt"
        
        if [ ! -f "$mask_file" ]; then
            log_formatted "WARNING" "Mask file not found: $mask_file"
            continue
        fi
        
        # Get total volume
        local total_volume=$(fslstats "$mask_file" -V | awk '{print $1}')
        
        # Get number of clusters and largest cluster size
        local num_clusters=0
        local largest_cluster=0
        
        if [ -f "${prefix}_clusters_sorted.txt" ]; then
            num_clusters=$(wc -l < "${prefix}_clusters_sorted.txt")
            largest_cluster=$(head -1 "${prefix}_clusters_sorted.txt" | awk '{print $2}')
        fi
        
        # Add to CSV
        echo "${mult},${total_volume},${num_clusters},${largest_cluster}" >> "$output_file"
    done
    
    log_message "Volume quantification complete. Results saved to: $output_file"
    return 0
}

# Function to create multi-threshold comparison
create_multi_threshold_comparison() {
    local t2flair="$1"
    local prefix="$2"
    local output_dir="${3:-$(dirname "$prefix")}"
    
    log_message "Creating multi-threshold comparison for hyperintensities"
    mkdir -p "$output_dir"
    
    # Check if input file exists
    if [ ! -f "$t2flair" ]; then
        log_formatted "ERROR" "T2-FLAIR file not found: $t2flair"
        return 1
    fi
    
    # Define thresholds and colors
    local thresholds=(1.5 2.0 2.5 3.0)
    local colors=("red" "orange" "yellow" "green")
    
    # Create command for viewing all thresholds together
    local fsleyes_cmd="fsleyes $t2flair"
    
    for i in "${!thresholds[@]}"; do
        local mult="${thresholds[$i]}"
        local color="${colors[$i]}"
        local hyper="${prefix}_thresh${mult}.nii.gz"
        
        if [ -f "$hyper" ]; then
            fsleyes_cmd="$fsleyes_cmd $hyper -cm $color -a 50"
        fi
    done
    
    echo "$fsleyes_cmd" > "${output_dir}/view_all_thresholds.sh"
    chmod +x "${output_dir}/view_all_thresholds.sh"
    
    # Create a composite image showing all thresholds
    if [ -f "${prefix}_thresh1.5.nii.gz" ]; then
        # Start with lowest threshold
        fslmaths "${prefix}_thresh1.5.nii.gz" -bin -mul 1 "${output_dir}/multi_thresh.nii.gz"
        
        # Add higher thresholds with increasing values
        if [ -f "${prefix}_thresh2.0.nii.gz" ]; then
            fslmaths "${prefix}_thresh2.0.nii.gz" -bin -mul 2 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        if [ -f "${prefix}_thresh2.5.nii.gz" ]; then
            fslmaths "${prefix}_thresh2.5.nii.gz" -bin -mul 3 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        if [ -f "${prefix}_thresh3.0.nii.gz" ]; then
            fslmaths "${prefix}_thresh3.0.nii.gz" -bin -mul 4 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        # Create overlay command for multi-threshold visualization
        echo "fsleyes $t2flair ${output_dir}/multi_thresh.nii.gz -cm hot -a 80" > "${output_dir}/view_multi_thresh.sh"
        chmod +x "${output_dir}/view_multi_thresh.sh"
        
        # Create slices for quick visual inspection
        slicer "$t2flair" "${output_dir}/multi_thresh.nii.gz" -a "${output_dir}/multi_threshold.png"
    fi
    
    log_message "Multi-threshold comparison complete"
    return 0
}

# Function to create 3D rendering of hyperintensities
create_3d_rendering() {
    local hyper_file="$1"
    local pons_file="$2"
    local output_dir="${3:-$(dirname "$hyper_file")}"
    
    log_message "Creating 3D rendering of hyperintensities"
    mkdir -p "$output_dir"
    
    # Check if input files exist
    if [ ! -f "$hyper_file" ] || [ ! -f "$pons_file" ]; then
        log_formatted "ERROR" "Input files not found"
        return 1
    fi
    
    # Create binary mask of hyperintensities
    fslmaths "$hyper_file" -bin "${output_dir}/hyper_bin.nii.gz"
    
    # Create binary mask of pons
    fslmaths "$pons_file" -bin "${output_dir}/pons_bin.nii.gz"
    
    # Create surface meshes if FreeSurfer is available
    if command -v mris_convert &> /dev/null; then
        # Convert binary volumes to surface meshes
        mri_tessellate "${output_dir}/pons_bin.nii.gz" 1 "${output_dir}/pons.stl"
        mri_tessellate "${output_dir}/hyper_bin.nii.gz" 1 "${output_dir}/hyper.stl"
        
        # Create command for viewing in FreeView
        echo "freeview -v ${output_dir}/pons_bin.nii.gz \
             -f ${output_dir}/pons.stl:edgecolor=blue:color=blue:opacity=0.3 \
             -f ${output_dir}/hyper.stl:edgecolor=red:color=red:opacity=0.8" > "${output_dir}/view_3d.sh"
        chmod +x "${output_dir}/view_3d.sh"
        
        log_message "3D rendering complete. To view, run: ${output_dir}/view_3d.sh"
    else
        log_formatted "WARNING" "FreeSurfer's mris_convert not found. 3D rendering skipped."
        return 1
    fi
    
    return 0
}

# Function to create intensity profile plots
create_intensity_profiles() {
    local input_file="$1"
    local output_dir="${2:-$(dirname "$input_file")/intensity_profiles}"
    
    log_message "Creating intensity profile plots for $input_file"
    mkdir -p "$output_dir"
    
    # Check if input file exists
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file not found: $input_file"
        return 1
    fi
    
    # Get dimensions
    local dims=($(fslinfo "$input_file" | grep ^dim | awk '{print $2}'))
    local center_x=$((dims[0] / 2))
    local center_y=$((dims[1] / 2))
    local center_z=$((dims[2] / 2))
    
    # Extract intensity profiles along three principal axes
    # X-axis profile (sagittal)
    fslroi "$input_file" "${output_dir}/x_line.nii.gz" \
           0 ${dims[0]} $center_y 1 $center_z 1
    
    # Y-axis profile (coronal)
    fslroi "$input_file" "${output_dir}/y_line.nii.gz" \
           $center_x 1 0 ${dims[1]} $center_z 1
    
    # Z-axis profile (axial)
    fslroi "$input_file" "${output_dir}/z_line.nii.gz" \
           $center_x 1 $center_y 1 0 ${dims[2]}
    
    # Extract intensity values along each axis
    for axis in "x" "y" "z"; do
        # Get values using fslmeants
        fslmeants -i "${output_dir}/${axis}_line.nii.gz" \
                  > "${output_dir}/${axis}_profile.txt"
        
        # Create simple plot script using gnuplot if available
        if command -v gnuplot &> /dev/null; then
            {
                echo "set terminal png size 800,600"
                echo "set output '${output_dir}/${axis}_profile.png'"
                echo "set title 'Intensity Profile Along ${axis}-axis'"
                echo "set xlabel 'Position'"
                echo "set ylabel 'Intensity'"
                echo "set grid"
                echo "plot '${output_dir}/${axis}_profile.txt' with lines title '${axis}-axis profile'"
            } > "${output_dir}/${axis}_plot.gnuplot"
            
            # Generate the plot
            gnuplot "${output_dir}/${axis}_plot.gnuplot"
        fi
    done
    
    log_message "Intensity profiles created in $output_dir"
    return 0
}

# Function to transform segmentation from standard space to original space
transform_segmentation_to_original() {
    local segmentation_file="$1"  # From standard space
    local reference_file="$2"     # Original T1 or FLAIR file
    local output_file="$3"        # Where to save the transformed segmentation
    local transform_file="$4"     # Transform file (from registration)
    
    # Check files exist
    if [[ ! -f "$segmentation_file" || ! -f "$reference_file" ]]; then
        log_formatted "ERROR" "Missing input files for transformation. Segmentation: $segmentation_file, Reference: $reference_file"
        return 1
    fi
    
    log_message "Transforming segmentation from standard to original space"
    
    # Check if transform file is provided and exists
    if [[ -n "$transform_file" && -f "$transform_file" ]]; then
        # Use the provided transform
        log_message "Using provided transform: $transform_file"
    else
        # Look for transform in the registered directory
        transform_file="${RESULTS_DIR}/registered/std2orig_0GenericAffine.mat"
        
        # If not found, try to find any transform file
        if [[ ! -f "$transform_file" ]]; then
            log_message "Looking for transform file in registered directory..."
            transform_file=$(find "${RESULTS_DIR}/registered" -name "*GenericAffine.mat" | head -1)
        fi
        
        if [[ ! -f "$transform_file" ]]; then
            log_formatted "ERROR" "Cannot find transform file to move between spaces"
            log_message "Creating a new transform file..."
            
            # Create transform from standard to original space
            local temp_dir=$(mktemp -d)
            local std_to_orig="${temp_dir}/std2orig"
            
            # Find standardized and original T1 files
            local std_t1=$(find "${RESULTS_DIR}/standardized" -name "*T1*std.nii.gz" | head -1)
            local orig_t1=$(find "${RESULTS_DIR}/bias_corrected" -name "*T1*.nii.gz" | head -1)
            
            if [[ -f "$std_t1" && -f "$orig_t1" ]]; then
                log_message "Creating registration from standard to original space..."
                log_message "Standard T1: $std_t1"
                log_message "Original T1: $orig_t1"
                
                # Create the transform using ANTs
                antsRegistrationSyN.sh \
                  -d 3 \
                  -f "$orig_t1" \
                  -m "$std_t1" \
                  -o "${std_to_orig}_" \
                  -t a
                
                # Check if transform was created
                if [[ -f "${std_to_orig}_0GenericAffine.mat" ]]; then
                    transform_file="${std_to_orig}_0GenericAffine.mat"
                    log_message "Transform file created: $transform_file"
                else
                    log_formatted "ERROR" "Failed to create transform file"
                    rm -rf "$temp_dir"
                    return 1
                fi
            else
                log_formatted "ERROR" "Cannot find T1 files to create transform"
                rm -rf "$temp_dir"
                return 1
            fi
        fi
    fi
    
    # Create directory for output file
    mkdir -p "$(dirname "$output_file")"
    
    # Apply transform using ANTs
    log_message "Applying transform to convert segmentation to original space..."
    log_message "Input segmentation: $segmentation_file"
    log_message "Reference: $reference_file"
    log_message "Output: $output_file"
    log_message "Transform: $transform_file"
    
    # Determine ANTs bin path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Execute transform using enhanced ANTs command execution
    execute_ants_command "transform_segmentation" "Transforming segmentation from standard to original space" \
        ${ants_bin}/antsApplyTransforms \
        -d 3 \
        -i "$segmentation_file" \
        -r "$reference_file" \
        -o "$output_file" \
        -t "$transform_file" \
        -n NearestNeighbor
    
    local status=$?
    if [[ $status -eq 0 ]]; then
        log_message "Segmentation successfully transformed to original space: $output_file"
    else
        log_formatted "ERROR" "Failed to transform segmentation (status: $status)"
        return 1
    fi
    
    # Clean up temporary directory if it exists
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
    fi
    
    return 0
}

# Function to analyze hyperintensities in Talairach brainstem regions
analyze_talairach_hyperintensities() {
    local flair_file="$1"
    local analysis_dir="$2"
    local output_basename="$3"
    
    log_formatted "INFO" "===== TALAIRACH HYPERINTENSITY ANALYSIS ====="
    log_message "FLAIR input: $flair_file"
    log_message "Analysis directory: $analysis_dir"
    log_message "Output basename: $output_basename"
    
    # Validate inputs
    if [ ! -f "$flair_file" ]; then
        log_formatted "ERROR" "FLAIR file not found: $flair_file"
        return 1
    fi
    
    if [ ! -d "$analysis_dir" ]; then
        log_formatted "ERROR" "Analysis directory not found: $analysis_dir"
        return 1
    fi
    
    # Create hyperintensities output directory
    local hyper_dir="${RESULTS_DIR}/comprehensive_analysis/hyperintensities"
    mkdir -p "$hyper_dir"
    
    # Find all Talairach region masks
    local talairach_regions=(
        "left_medulla"
        "right_medulla"
        "left_pons"
        "right_pons"
        "left_midbrain"
        "right_midbrain"
        "pons"  # combined pons
    )
    
    log_message "Analyzing hyperintensities in Talairach brainstem regions..."
    
    # Process each Talairach region
    for region in "${talairach_regions[@]}"; do
        # Look for region mask files
        local region_mask=""
        local region_files=(
            "${analysis_dir}/${output_basename}_${region}_flair_space.nii.gz"
            "${analysis_dir}/${output_basename}_${region}.nii.gz"
        )
        
        for mask_file in "${region_files[@]}"; do
            if [ -f "$mask_file" ]; then
                region_mask="$mask_file"
                break
            fi
        done
        
        if [ -z "$region_mask" ] || [ ! -f "$region_mask" ]; then
            log_message "Skipping $region - mask not found"
            continue
        fi
        
        log_message "Processing hyperintensities in $region..."
        log_message "Using mask: $(basename "$region_mask")"
        
        # Create region-specific output directory
        local region_hyper_dir="${hyper_dir}/${region}"
        mkdir -p "$region_hyper_dir"
        
        # Create masked FLAIR for this region
        local region_flair="${region_hyper_dir}/${region}_flair.nii.gz"
        if ! fslmaths "$flair_file" -mas "$region_mask" "$region_flair"; then
            log_formatted "WARNING" "Failed to create masked FLAIR for $region"
            continue
        fi
        
        # Get region statistics for adaptive thresholding
        local region_stats=$(fslstats "$region_flair" -k "$region_mask" -M -S)
        local region_mean=$(echo "$region_stats" | awk '{print $1}')
        local region_std=$(echo "$region_stats" | awk '{print $2}')
        
        if [ "$region_mean" = "0.000000" ] || [ -z "$region_std" ]; then
            log_message "Skipping $region - no signal detected"
            continue
        fi
        
        log_message "$region statistics - Mean: $region_mean, StdDev: $region_std"
        
        # Apply hyperintensity detection with region-specific thresholds
        local threshold_multiplier="${THRESHOLD_WM_SD_MULTIPLIER:-2.0}"
        local threshold_val=$(echo "$region_mean + $threshold_multiplier * $region_std" | bc -l)
        
        log_message "Using threshold: $threshold_val for $region"
        
        # Create hyperintensity mask
        local region_hyper_mask="${region_hyper_dir}/${region}_hyperintensities.nii.gz"
        if ! fslmaths "$region_flair" -thr "$threshold_val" -bin "$region_hyper_mask"; then
            log_formatted "WARNING" "Failed to create hyperintensity mask for $region"
            continue
        fi
        
        # Apply minimum cluster size filtering
        local min_size="${MIN_HYPERINTENSITY_SIZE:-4}"
        local filtered_mask="${region_hyper_dir}/${region}_hyperintensities_filtered.nii.gz"
        
        if cluster --in="$region_hyper_mask" --thresh=0.5 \
                   --connectivity=26 --minextent="$min_size" \
                   --oindex="$filtered_mask" > /dev/null 2>&1; then
            log_message "✓ Applied clustering filter (min size: $min_size voxels) to $region"
        else
            log_message "Clustering failed for $region, using unfiltered mask"
            cp "$region_hyper_mask" "$filtered_mask"
        fi
        
        # Create intensity version
        local region_hyper_intensity="${region_hyper_dir}/${region}_hyperintensities_intensity.nii.gz"
        fslmaths "$region_flair" -mas "$filtered_mask" "$region_hyper_intensity"
        
        # Create RGB overlay for visualization
        local overlay="${region_hyper_dir}/overlay.nii.gz"
        log_message "Creating RGB overlay for $region..."
        
        # Check dimensions match
        local flair_dims=$(fslinfo "$region_flair" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        local mask_dims=$(fslinfo "$filtered_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        
        if [ "$flair_dims" = "$mask_dims" ]; then
            # Create RGB channels
            local temp_dir=$(mktemp -d)
            
            # Red channel - background FLAIR
            fslmaths "$region_flair" -div $(fslstats "$region_flair" -k "$region_mask" -R | awk '{print $2}') "${temp_dir}/r.nii.gz"
            
            # Green channel - hyperintensities
            fslmaths "$filtered_mask" -mul 0.8 "${temp_dir}/g.nii.gz"
            
            # Blue channel - mask outline
            fslmaths "$region_mask" -edge -bin -mul 0.3 "${temp_dir}/b.nii.gz"
            
            # Merge RGB channels
            if fslmerge -t "$overlay" "${temp_dir}/r.nii.gz" "${temp_dir}/g.nii.gz" "${temp_dir}/b.nii.gz"; then
                log_message "✓ Created RGB overlay for $region"
            else
                log_formatted "WARNING" "Failed to create RGB overlay for $region"
                # Create fallback overlay
                fslmaths "$region_flair" -add "$filtered_mask" "$overlay"
            fi
            
            rm -rf "$temp_dir"
        else
            log_formatted "WARNING" "Dimension mismatch for $region overlay - creating fallback"
            fslmaths "$region_flair" -add "$filtered_mask" "$overlay"
        fi
        
        # Quantify results
        local hyper_voxels=$(fslstats "$filtered_mask" -V | awk '{print $1}')
        local hyper_volume=$(fslstats "$filtered_mask" -V | awk '{print $2}')
        local region_voxels=$(fslstats "$region_mask" -V | awk '{print $1}')
        local region_volume=$(fslstats "$region_mask" -V | awk '{print $2}')
        
        local percentage="0"
        if [ "$region_voxels" -gt 0 ]; then
            percentage=$(echo "scale=2; $hyper_voxels * 100 / $region_voxels" | bc)
        fi
        
        log_message "✓ $region results:"
        log_message "   Hyperintensity voxels: $hyper_voxels ($hyper_volume mm³)"
        log_message "   Region coverage: ${percentage}%"
        
        # Create region summary
        {
            echo "Talairach Region Hyperintensity Analysis"
            echo "======================================="
            echo "Region: $region"
            echo "Date: $(date)"
            echo ""
            echo "Input files:"
            echo "  FLAIR: $(basename "$flair_file")"
            echo "  Mask: $(basename "$region_mask")"
            echo ""
            echo "Analysis parameters:"
            echo "  Threshold multiplier: $threshold_multiplier"
            echo "  Threshold value: $threshold_val"
            echo "  Minimum cluster size: $min_size voxels"
            echo ""
            echo "Results:"
            echo "  Region volume: $region_volume mm³ ($region_voxels voxels)"
            echo "  Hyperintensity volume: $hyper_volume mm³ ($hyper_voxels voxels)"
            echo "  Percentage affected: ${percentage}%"
            echo ""
            echo "Output files:"
            echo "  Hyperintensity mask: $(basename "$filtered_mask")"
            echo "  Hyperintensity intensity: $(basename "$region_hyper_intensity")"
            echo "  RGB overlay: $(basename "$overlay")"
        } > "${region_hyper_dir}/${region}_hyperintensity_report.txt"
        
        log_message "✓ Created analysis report: ${region_hyper_dir}/${region}_hyperintensity_report.txt"
    done
    
    # Create combined summary across all Talairach regions
    log_message "Creating combined Talairach hyperintensity summary..."
    
    local combined_report="${hyper_dir}/talairach_hyperintensity_summary.txt"
    {
        echo "Talairach Brainstem Hyperintensity Analysis Summary"
        echo "=================================================="
        echo "Date: $(date)"
        echo "FLAIR input: $(basename "$flair_file")"
        echo ""
        echo "Region | Volume (mm³) | Hyperintensities (mm³) | % Affected"
        echo "-------|--------------|-------------------------|----------"
        
        for region in "${talairach_regions[@]}"; do
            local region_report="${hyper_dir}/${region}/${region}_hyperintensity_report.txt"
            if [ -f "$region_report" ]; then
                local region_vol=$(grep "Region volume:" "$region_report" | awk '{print $3}')
                local hyper_vol=$(grep "Hyperintensity volume:" "$region_report" | awk '{print $3}')
                local percentage=$(grep "Percentage affected:" "$region_report" | awk '{print $3}')
                printf "%-6s | %12s | %23s | %8s\n" "$region" "$region_vol" "$hyper_vol" "$percentage"
            else
                printf "%-6s | %12s | %23s | %8s\n" "$region" "N/A" "N/A" "N/A"
            fi
        done
    } > "$combined_report"
    
    log_formatted "SUCCESS" "Talairach hyperintensity analysis complete"
    log_message "Combined summary: $combined_report"
    log_message "Individual reports in: $hyper_dir"
    
    return 0
}

# Export functions
export -f detect_hyperintensities
export -f analyze_clusters
export -f quantify_volumes
export -f create_multi_threshold_comparison
export -f create_3d_rendering
export -f create_intensity_profiles
export -f transform_segmentation_to_original
export -f analyze_talairach_hyperintensities

log_message "Analysis module loaded"