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

# Function to detect hyperintensities
detect_hyperintensities() {
    # Usage: detect_hyperintensities <FLAIR_input.nii.gz> <output_prefix> [<T1_input.nii.gz>]
    #
    # 1) Brain-extract the FLAIR
    # 2) Optional: If T1 provided, use Atropos segmentation from T1 or cross-modality
    # 3) Threshold + morphological operations => final hyperintensity mask
    # 4) Produce .mgz overlays for quick Freeview
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

    log_message "=== Hyperintensity Detection ==="
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

    antsBrainExtraction.sh \
      -d 3 \
      -a "$flair_file" \
      -o "${brainextr_dir}/" \
      -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
      -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
      -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
      -k 1

    local flair_brain="${brainextr_dir}/BrainExtractionBrain.nii.gz"
    local flair_mask="${brainextr_dir}/BrainExtractionMask.nii.gz"

    # 2) Tissue Segmentation
    # If T1 is provided, you can do cross-modality with Atropos
    local segmentation_out="${out_prefix}_atropos_seg.nii.gz"
    local wm_mask="${out_prefix}_wm_mask.nii.gz"
    local gm_mask="${out_prefix}_gm_mask.nii.gz"

    if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
        # Register T1 to FLAIR or vice versa, or assume they match dimensions
        log_message "Registering ${flair_brain} to ${t1_file}"
        
        t1_registered="${out_prefix}_T1_registered.nii.gz"

        # Verify alignment: Check if T1 and FLAIR have identical headers
        echo "T1 and FLAIR appear to have matching dimensions. Skipping registration."
        cp "$t1_file" "$t1_registered"  # Just copy it if already aligned

        # Then run Atropos on FLAIR using T1 as additional input if needed, or just on FLAIR alone.
        Atropos -d 3 \
          -a "$flair_brain" \
          -a "$t1_file" \
          -s 2 \
          -x "$flair_mask" \
          -o "[$segmentation_out,${out_prefix}_atropos_prob%02d.nii.gz]" \
          -c "[${ATROPOS_CONVERGENCE}]" \
          -m "${ATROPOS_MRF}" \
          -i "${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}]" \
          -k Gaussian

        # Typical labeling: 1=CSF, 2=GM, 3=WM, 4=Lesion? (depends on your config)

        # Verify which label is which
        fslstats "$segmentation_out" -R

        ThresholdImage 3 "$segmentation_out" "$wm_mask" 3 3
        ThresholdImage 3 "$segmentation_out" "$gm_mask" 2 2

    else
        # Fallback to intensity-based segmentation (Otsu or simple approach)
        log_message "No T1 provided; using Otsu-based 3-class segmentation"

        ThresholdImage 3 "$flair_brain" "${out_prefix}_otsu.nii.gz" Otsu 3 "$flair_mask"
        # Typically label 3 => brightest intensities => approximate WM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$wm_mask" 3 3
        # Label 2 => GM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$gm_mask" 2 2
    fi

    # 3) Compute WM stats to define threshold
    local mean_wm
    local sd_wm
    mean_wm=$(fslstats "$flair_brain" -k "$wm_mask" -M)
    sd_wm=$(fslstats "$flair_brain" -k "$wm_mask" -S)
    log_message "WM mean: $mean_wm   WM std: $sd_wm"

    # You can define a multiplier or use the global THRESHOLD_WM_SD_MULTIPLIER
    local threshold_multiplier="$THRESHOLD_WM_SD_MULTIPLIER"
    
    # Create multiple thresholds
    for mult in 1.5 2.0 2.5 3.0; do
        local thr_val
        thr_val=$(echo "$mean_wm + $mult * $sd_wm" | bc -l)
        log_message "Threshold = WM_mean + $mult * WM_SD = $thr_val"
        
        # Threshold + morphological operations
        local init_thr="${out_prefix}_init_thr_${mult}.nii.gz"
        ThresholdImage 3 "$flair_brain" "$init_thr" "$thr_val" 999999 "$flair_mask"
        
        # Combine with WM + GM if you want to exclude CSF
        local tissue_mask="${out_prefix}_brain_tissue.nii.gz"
        ImageMath 3 "$tissue_mask" + "$wm_mask" "$gm_mask"
        
        local combined_thr="${out_prefix}_combined_thr_${mult}.nii.gz"
        ImageMath 3 "$combined_thr" m "$init_thr" "$tissue_mask"
        
        # Morphological cleanup
        local eroded="${out_prefix}_eroded_${mult}.nii.gz"
        local eroded_dilated="${out_prefix}_eroded_dilated_${mult}.nii.gz"
        ImageMath 3 "$eroded" ME "$combined_thr" 1
        ImageMath 3 "$eroded_dilated" MD "$eroded" 1
        
        # Remove small islands with connected components
        local final_mask="${out_prefix}_thresh${mult}.nii.gz"
        
        c3d "$eroded_dilated" \
         -connected-components 26 \
         -threshold $MIN_HYPERINTENSITY_SIZE inf 1 0 \
         -o "$final_mask"
        
        log_message "Final hyperintensity mask (threshold $mult) saved to: $final_mask"
        
        # Create binary version for cluster analysis
        fslmaths "$final_mask" -bin "${out_prefix}_thresh${mult}_bin.nii.gz"
    done

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
    
    # Perform cluster analysis
    analyze_clusters "${out_prefix}_thresh2.0_bin.nii.gz" "${out_prefix}_clusters"
    
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

# Export functions
export -f detect_hyperintensities
export -f analyze_clusters
export -f quantify_volumes
export -f create_multi_threshold_comparison
export -f create_3d_rendering
export -f create_intensity_profiles

log_message "Analysis module loaded"