#!/usr/bin/env bash
#
# visualization.sh - Visualization functions for the brain MRI processing pipeline
#
# This module contains:
# - QC visualizations
# - Multi-threshold overlays
# - HTML report generation
# - 3D visualization
#

# Function to generate QC visualizations
generate_qc_visualizations() {
    local subject_id="$1"
    local subject_dir="$2"
    local output_dir="${subject_dir}/qc_visualizations"
    
    echo "Generating QC visualizations for subject $subject_id"
    mkdir -p "$output_dir"
    
    # Get input files
    local t2_flair=$(find "${subject_dir}" -name "*T2_SPACE_FLAIR*.nii.gz" | head -1)
    local t1=$(find "${subject_dir}" -name "*MPRAGE*.nii.gz" | head -1)
    
    # Create edge overlays for segmentation validation
    for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
        local mask="${subject_dir}/segmentation/${region}/${subject_id}_${region}.nii.gz"
        local t2flair="${subject_dir}/registered/${subject_id}_${region}_t2flair.nii.gz"
        
        if [ -f "$mask" ] && [ -f "$t2flair" ]; then
            echo "Creating edge overlay for $region..."
            
            # Create edge of mask
            fslmaths "$mask" -edge -bin "${output_dir}/${region}_edge.nii.gz"
            
            # Create RGB overlay for better visualization
            local overlay="${output_dir}/${region}_overlay.nii.gz"
            
            # Create a 3-volume RGB image
            # Red channel: Edge of mask
            # Green channel: Empty
            # Blue channel: Empty
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 1 "${output_dir}/r.nii.gz"
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 0 "${output_dir}/g.nii.gz"
            fslmaths "${output_dir}/${region}_edge.nii.gz" -mul 0 "${output_dir}/b.nii.gz"
            
            # Merge channels
            fslmerge -t "$overlay" "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Clean up temporary files
            rm "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Create overlay command for fsleyes
            echo "fsleyes $t2flair ${output_dir}/${region}_edge.nii.gz -cm red -a 80" > "${output_dir}/view_${region}_overlay.sh"
            chmod +x "${output_dir}/view_${region}_overlay.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/${region}_edge.nii.gz" -a "${output_dir}/${region}_overlay.png"
        fi
    done
    
    # Create hyperintensity overlays at different thresholds
    for mult in 1.5 2.0 2.5 3.0; do
        local hyper="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
        local t2flair="${subject_dir}/registered/${subject_id}_dorsal_pons_t2flair.nii.gz"
        
        if [ -f "$hyper" ] && [ -f "$t2flair" ]; then
            echo "Creating hyperintensity overlay for threshold ${mult}..."
            
            # Create binary mask of hyperintensities
            fslmaths "$hyper" -bin "${output_dir}/hyper_${mult}_bin.nii.gz"
            
            # Create RGB overlay
            # Red channel: Hyperintensity
            # Green channel: Empty
            # Blue channel: Empty
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 1 "${output_dir}/r.nii.gz"
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 0 "${output_dir}/g.nii.gz"
            fslmaths "${output_dir}/hyper_${mult}_bin.nii.gz" -mul 0 "${output_dir}/b.nii.gz"
            
            # Merge channels
            fslmerge -t "${output_dir}/hyper_${mult}_overlay.nii.gz" "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Clean up temporary files
            rm "${output_dir}/r.nii.gz" "${output_dir}/g.nii.gz" "${output_dir}/b.nii.gz"
            
            # Create overlay command for fsleyes
            echo "fsleyes $t2flair $hyper -cm hot -a 80" > "${output_dir}/view_hyperintensity_${mult}.sh"
            chmod +x "${output_dir}/view_hyperintensity_${mult}.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/hyper_${mult}_bin.nii.gz" -a "${output_dir}/hyperintensity_${mult}.png"
        fi
    done
    
    # Create registration check visualization
    if [ -f "$t2_flair" ] && [ -f "${subject_dir}/registered/t1_to_flairWarped.nii.gz" ]; then
        echo "Creating registration check visualization..."
        
        local fixed="$t2_flair"
        local moving_reg="${subject_dir}/registered/t1_to_flairWarped.nii.gz"
        
        # Create checkerboard pattern for registration check
        local checker="${output_dir}/t1_t2_checkerboard.nii.gz"
        
        # Use FSL's checkerboard function
        fslcpgeom "$fixed" "$moving_reg"  # Ensure geometry is identical
        fslmaths "$fixed" -mul 0 "$checker"  # Initialize empty volume
        
        # Create 5x5x5 checkerboard
        local dim_x=$(fslval "$fixed" dim1)
        local dim_y=$(fslval "$fixed" dim2)
        local dim_z=$(fslval "$fixed" dim3)
        
        local block_x=$((dim_x / 5))
        local block_y=$((dim_y / 5))
        local block_z=$((dim_z / 5))
        
        for ((x=0; x<5; x++)); do
            for ((y=0; y<5; y++)); do
                for ((z=0; z<5; z++)); do
                    if [ $(( (x+y+z) % 2 )) -eq 0 ]; then
                        # Use fixed image for this block
                        fslmaths "$fixed" -roi $((x*block_x)) $block_x $((y*block_y)) $block_y $((z*block_z)) $block_z 0 1 \
                                 -add "$checker" "$checker"
                    else
                        # Use moving image for this block
                        fslmaths "$moving_reg" -roi $((x*block_x)) $block_x $((y*block_y)) $block_y $((z*block_z)) $block_z 0 1 \
                                 -add "$checker" "$checker"
                    fi
                done
            done
        done
        
        # Create overlay command for fsleyes
        echo "fsleyes $checker" > "${output_dir}/view_registration_check.sh"
        chmod +x "${output_dir}/view_registration_check.sh"
        
        # Create slices for quick visual inspection
        slicer "$checker" -a "${output_dir}/registration_check.png"
    fi
    
    # Create difference map for registration quality assessment
    if [ -f "$t2_flair" ] && [ -f "${subject_dir}/registered/t1_to_flairWarped.nii.gz" ]; then
        echo "Creating registration difference map..."
        
        local fixed="$t2_flair"
        local moving_reg="${subject_dir}/registered/t1_to_flairWarped.nii.gz"
        
        # Normalize both images to 0-1 range for comparable intensity
        fslmaths "$fixed" -inm 1 "${output_dir}/fixed_norm.nii.gz"
        fslmaths "$moving_reg" -inm 1 "${output_dir}/moving_norm.nii.gz"
        
        # Calculate absolute difference
        fslmaths "${output_dir}/fixed_norm.nii.gz" -sub "${output_dir}/moving_norm.nii.gz" -abs "${output_dir}/reg_diff.nii.gz"
        
        # Create overlay command for fsleyes
        echo "fsleyes $fixed ${output_dir}/reg_diff.nii.gz -cm hot -a 80" > "${output_dir}/view_reg_diff.sh"
        chmod +x "${output_dir}/view_reg_diff.sh"
        
        # Create slices for quick visual inspection
        slicer "${output_dir}/reg_diff.nii.gz" -a "${output_dir}/registration_diff.png"
        
        # Clean up temporary files
        rm "${output_dir}/fixed_norm.nii.gz" "${output_dir}/moving_norm.nii.gz"
    fi
    
    # Create multi-threshold comparison for hyperintensities
    if [ -f "${subject_dir}/registered/${subject_id}_dorsal_pons_t2flair.nii.gz" ]; then
        echo "Creating multi-threshold comparison for hyperintensities..."
        
        local t2flair="${subject_dir}/registered/${subject_id}_dorsal_pons_t2flair.nii.gz"
        local thresholds=(1.5 2.0 2.5 3.0)
        local colors=("red" "orange" "yellow" "green")
        
        # Create command for viewing all thresholds together
        local fsleyes_cmd="fsleyes $t2flair"
        
        for i in "${!thresholds[@]}"; do
            local mult="${thresholds[$i]}"
            local color="${colors[$i]}"
            local hyper="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
            
            if [ -f "$hyper" ]; then
                fsleyes_cmd="$fsleyes_cmd $hyper -cm $color -a 50"
            fi
        done
        
        echo "$fsleyes_cmd" > "${output_dir}/view_all_thresholds.sh"
        chmod +x "${output_dir}/view_all_thresholds.sh"
        
        # Create a composite image showing all thresholds
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" ]; then
            # Start with lowest threshold
            fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" -bin -mul 1 "${output_dir}/multi_thresh.nii.gz"
            
            # Add higher thresholds with increasing values
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -bin -mul 2 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" -bin -mul 3 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" ]; then
                fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" -bin -mul 4 \
                         -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
            fi
            
            # Create overlay command for multi-threshold visualization
            echo "fsleyes $t2flair ${output_dir}/multi_thresh.nii.gz -cm hot -a 80" > "${output_dir}/view_multi_thresh.sh"
            chmod +x "${output_dir}/view_multi_thresh.sh"
            
            # Create slices for quick visual inspection
            slicer "$t2flair" "${output_dir}/multi_thresh.nii.gz" -a "${output_dir}/multi_threshold.png"
        fi
    fi
    
    echo "QC visualizations generated in $output_dir"
    return 0
}

# Function to create multi-threshold overlays
create_multi_threshold_overlays() {
    local subject_id="$1"
    local subject_dir="$2"
    local output_dir="${subject_dir}/overlays"
    
    echo "Creating multi-threshold overlays for subject $subject_id"
    mkdir -p "$output_dir"
    
    # Get T2-FLAIR image
    local t2flair="${subject_dir}/registered/${subject_id}_dorsal_pons_t2flair.nii.gz"
    
    if [ ! -f "$t2flair" ]; then
        log_formatted "ERROR" "T2-FLAIR image not found: $t2flair"
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
        local hyper="${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh${mult}.nii.gz"
        
        if [ -f "$hyper" ]; then
            fsleyes_cmd="$fsleyes_cmd $hyper -cm $color -a 50"
        fi
    done
    
    echo "$fsleyes_cmd" > "${output_dir}/view_all_thresholds.sh"
    chmod +x "${output_dir}/view_all_thresholds.sh"
    
    # Create a composite image showing all thresholds
    if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" ]; then
        # Start with lowest threshold
        fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh1.5.nii.gz" -bin -mul 1 "${output_dir}/multi_thresh.nii.gz"
        
        # Add higher thresholds with increasing values
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" ]; then
            fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.0.nii.gz" -bin -mul 2 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" ]; then
            fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh2.5.nii.gz" -bin -mul 3 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        if [ -f "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" ]; then
            fslmaths "${subject_dir}/hyperintensities/${subject_id}_dorsal_pons_thresh3.0.nii.gz" -bin -mul 4 \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi
        
        # Create overlay command for multi-threshold visualization
        echo "fsleyes $t2flair ${output_dir}/multi_thresh.nii.gz -cm hot -a 80" > "${output_dir}/view_multi_thresh.sh"
        chmod +x "${output_dir}/view_multi_thresh.sh"
        
        # Create slices for quick visual inspection
        slicer "$t2flair" "${output_dir}/multi_thresh.nii.gz" -a "${output_dir}/multi_threshold.png"
    fi
    
    echo "Multi-threshold overlays created in $output_dir"
    return 0
}

# Function to generate HTML report
generate_html_report() {
    local subject_id="$1"
    local subject_dir="$2"
    local output_file="${subject_dir}/reports/${subject_id}_report.html"
    
    echo "Creating HTML report for subject $subject_id"
    mkdir -p "$(dirname "$output_file")"
    
    # Create HTML report
    {
        echo "<!DOCTYPE html>"
        echo "<html lang='en'>"
        echo "<head>"
        echo "  <meta charset='UTF-8'>"
        echo "  <meta name='viewport' content='width=device-width, initial-scale=1.0'>"
        echo "  <title>Brainstem Analysis QC Report - Subject ${subject_id}</title>"
        echo "  <style>"
        echo "    body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; color: #333; }"
        echo "    h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }"
        echo "    h2 { color: #2980b9; margin-top: 30px; }"
        echo "    h3 { color: #3498db; }"
        echo "    .container { max-width: 1200px; margin: 0 auto; }"
        echo "    .section { margin-bottom: 40px; }"
        echo "    .image-container { display: flex; flex-wrap: wrap; gap: 20px; margin: 20px 0; }"
        echo "    .image-box { border: 1px solid #ddd; padding: 10px; border-radius: 5px; }"
        echo "    .image-box img { max-width: 100%; height: auto; }"
        echo "    .image-box p { margin: 10px 0 0; font-weight: bold; text-align: center; }"
        echo "    table { width: 100%; border-collapse: collapse; margin: 20px 0; }"
        echo "    th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #ddd; }"
        echo "    th { background-color: #f8f9fa; }"
        echo "    tr:hover { background-color: #f1f1f1; }"
        echo "    .metric-good { color: green; }"
        echo "    .metric-warning { color: orange; }"
        echo "    .metric-bad { color: red; }"
        echo "    .summary-box { background-color: #f8f9fa; border-left: 4px solid #3498db; padding: 15px; margin: 20px 0; }"
        echo "  </style>"
        echo "</head>"
        echo "<body>"
        echo "  <div class='container'>"
        echo "    <h1>Brainstem Analysis QC Report</h1>"
        echo "    <div class='summary-box'>"
        echo "      <h2>Subject: ${subject_id}</h2>"
        echo "      <p>Report generated: $(date)</p>"
        
        # Add overall quality assessment if available
        if [ -f "${subject_dir}/validation/registration/quality.txt" ]; then
            local reg_quality=$(cat "${subject_dir}/validation/registration/quality.txt")
            local quality_class="metric-warning"
            
            if [ "$reg_quality" == "EXCELLENT" ] || [ "$reg_quality" == "GOOD" ]; then
                quality_class="metric-good"
            elif [ "$reg_quality" == "POOR" ]; then
                quality_class="metric-bad"
            fi
            
            echo "      <p>Registration Quality: <span class='${quality_class}'>${reg_quality}</span></p>"
        fi
        
        echo "    </div>"
        
        # Section 1: Segmentation Results
        echo "    <div class='section'>"
        echo "      <h2>1. Brainstem Segmentation</h2>"
        
        # Add segmentation statistics if available
        echo "      <h3>Volumetric Analysis</h3>"
        echo "      <table>"
        echo "        <tr><th>Region</th><th>Volume (mm³)</th></tr>"
        
        for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
            local mask="${subject_dir}/segmentation/${region}/${subject_id}_${region}.nii.gz"
            if [ -f "$mask" ]; then
                local volume=$(fslstats "$mask" -V | awk '{print $1}')
                echo "        <tr><td>${region}</td><td>${volume}</td></tr>"
            fi
        done
        
        echo "      </table>"
        
        # Add segmentation visualizations
        echo "      <h3>Segmentation Visualization</h3>"
        echo "      <div class='image-container'>"
        
        for region in "brainstem" "pons" "dorsal_pons" "ventral_pons"; do
            if [ -f "${subject_dir}/qc_visualizations/${region}_overlay.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='../qc_visualizations/${region}_overlay.png' alt='${region} segmentation'>"
                echo "          <p>${region} Segmentation</p>"
                echo "        </div>"
            fi
        done
        
        echo "      </div>"
        echo "    </div>"
        
        # Section 2: Registration Quality
        echo "    <div class='section'>"
        echo "      <h2>2. Registration Quality</h2>"
        
        # Add registration visualizations
        if [ -f "${subject_dir}/qc_visualizations/registration_check.png" ]; then
            echo "      <div class='image-container'>"
            echo "        <div class='image-box'>"
            echo "          <img src='../qc_visualizations/registration_check.png' alt='Registration Checkerboard'>"
            echo "          <p>T1-T2 Registration Checkerboard</p>"
            echo "        </div>"
            
            if [ -f "${subject_dir}/qc_visualizations/registration_diff.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='../qc_visualizations/registration_diff.png' alt='Registration Difference Map'>"
                echo "          <p>Registration Difference Map</p>"
                echo "        </div>"
            fi
            
            echo "      </div>"
        fi
        
        # Add registration metrics if available
        if [ -f "${subject_dir}/validation/registration/validation_report.txt" ]; then
            echo "      <h3>Registration Metrics</h3>"
            echo "      <pre>"
            cat "${subject_dir}/validation/registration/validation_report.txt" | grep -E "Cross-correlation|Mutual information|Normalized cross-correlation|Dice coefficient|Jaccard index"
            echo "      </pre>"
        fi
        
        # Add orientation distortion metrics if available
        if [ -f "${subject_dir}/validation/registration/orientation_quality.txt" ] || [ -f "${subject_dir}/validation/registration/orientation/orientation_deviation.nii.gz" ]; then
            echo "      <h3>Orientation Distortion Analysis</h3>"
            echo "      <table>"
            echo "        <tr><th>Metric</th><th>Value</th><th>Status</th></tr>"
            
            # Check for orientation quality
            if [ -f "${subject_dir}/validation/registration/orientation_quality.txt" ]; then
                local orientation_quality=$(cat "${subject_dir}/validation/registration/orientation_quality.txt")
                local status_class="metric-warning"
                
                if [ "$orientation_quality" = "EXCELLENT" ]; then
                    status_class="metric-good"
                elif [ "$orientation_quality" = "POOR" ]; then
                    status_class="metric-bad"
                fi
                
                echo "        <tr><td>Orientation preservation quality</td><td>${orientation_quality}</td><td class='${status_class}'>${orientation_quality}</td></tr>"
            fi
            
            # Check for brainstem-specific orientation metrics
            if [ -f "${subject_dir}/validation/registration/orientation/brainstem_orientation.csv" ]; then
                # Skip the header line
                tail -n +2 "${subject_dir}/validation/registration/orientation/brainstem_orientation.csv" | while IFS=, read -r region mean_angular max_angular std_angular; do
                    # Determine status class based on configuration thresholds
                    local status_class="metric-warning"
                    local status_text="Acceptable"
                    
                    if (( $(echo "$mean_angular < $ORIENTATION_EXCELLENT_THRESHOLD" | bc -l) )); then
                        status_class="metric-good"
                        status_text="Excellent"
                    elif (( $(echo "$mean_angular < $ORIENTATION_GOOD_THRESHOLD" | bc -l) )); then
                        status_class="metric-good"
                        status_text="Good"
                    elif (( $(echo "$mean_angular > $ORIENTATION_ACCEPTABLE_THRESHOLD" | bc -l) )); then
                        status_class="metric-bad"
                        status_text="Poor"
                    fi
                    
                    echo "        <tr><td>${region} mean angular deviation</td><td>${mean_angular}</td><td class='${status_class}'>${status_text}</td></tr>"
                done
            fi
            
            # Add shearing information if available
            if [ -f "${subject_dir}/validation/registration/orientation/shearing_analysis.txt" ]; then
                local shearing_detected=$(grep "Significant shearing detected" "${subject_dir}/validation/registration/orientation/shearing_analysis.txt" | awk '{print $4}')
                local status_class="metric-good"
                local status_text="No significant shearing"
                
                if [ "$shearing_detected" = "true" ]; then
                    status_class="metric-bad"
                    status_text="Shearing detected"
                fi
                
                echo "        <tr><td>Shearing distortion</td><td>${shearing_detected}</td><td class='${status_class}'>${status_text}</td></tr>"
            fi
            
            echo "      </table>"
            
            # Add orientation distortion visualization if available
            if [ -f "${subject_dir}/validation/registration/orientation_distortion.png" ]; then
                echo "      <div class='image-container'>"
                echo "        <div class='image-box'>"
                echo "          <img src='../validation/registration/orientation_distortion.png' alt='Orientation Distortion Map'>"
                echo "          <p>Orientation Distortion Map</p>"
                echo "        </div>"
                echo "      </div>"
            fi
        fi
        
        echo "    </div>"
        
        # Section 3: Hyperintensity Analysis
        echo "    <div class='section'>"
        echo "      <h2>3. Hyperintensity Analysis</h2>"
        
        # Add hyperintensity visualizations
        echo "      <h3>Threshold Comparison</h3>"
        echo "      <div class='image-container'>"
        
        for mult in 1.5 2.0 2.5 3.0; do
            if [ -f "${subject_dir}/qc_visualizations/hyperintensity_${mult}.png" ]; then
                echo "        <div class='image-box'>"
                echo "          <img src='../qc_visualizations/hyperintensity_${mult}.png' alt='Hyperintensity Threshold ${mult}'>"
                echo "          <p>Threshold: ${mult} × SD</p>"
                echo "        </div>"
            fi
        done
        
        if [ -f "${subject_dir}/qc_visualizations/multi_threshold.png" ]; then
            echo "        <div class='image-box'>"
            echo "          <img src='../qc_visualizations/multi_threshold.png' alt='Multi-threshold Comparison'>"
            echo "          <p>Multi-threshold Comparison</p>"
            echo "        </div>"
            echo "      </div>"
        fi
        
        # Add cluster visualization if available
        if [ -f "${subject_dir}/qc_visualizations/clusters.png" ]; then
            echo "      <h3>Cluster Analysis</h3>"
            echo "      <div class='image-container'>"
            echo "        <div class='image-box'>"
            echo "          <img src='../qc_visualizations/clusters.png' alt='Cluster Analysis'>"
            echo "          <p>Cluster Analysis (2.0 × SD threshold)</p>"
            echo "        </div>"
            echo "      </div>"
        fi
        
        echo "    </div>"
        
        # Section 4: Intensity Profiles
        if [ -d "${subject_dir}/qc_visualizations/intensity_profiles" ]; then
            echo "    <div class='section'>"
            echo "      <h2>4. Intensity Profiles</h2>"
            echo "      <div class='image-container'>"
            
            for axis in "x" "y" "z"; do
                if [ -f "${subject_dir}/qc_visualizations/intensity_profiles/${axis}_profile.png" ]; then
                    echo "        <div class='image-box'>"
                    echo "          <img src='../qc_visualizations/intensity_profiles/${axis}_profile.png' alt='${axis}-axis Intensity Profile'>"
                    echo "          <p>${axis}-axis Intensity Profile</p>"
                    echo "        </div>"
                fi
            done
            
            echo "      </div>"
            echo "    </div>"
        fi
        
        # Section 5: 3D Visualization
        if [ -f "${subject_dir}/qc_visualizations/view_3d.sh" ]; then
            echo "    <div class='section'>"
            echo "      <h2>5. 3D Visualization</h2>"
            echo "      <p>3D visualization is available. Run the following command to view:</p>"
            echo "      <pre>cd ${subject_dir}/qc_visualizations && ./view_3d.sh</pre>"
            echo "    </div>"
        fi
        
        # Footer
        echo "    <div class='section'>"
        echo "      <p>For more detailed analysis, please use the provided visualization scripts in the QC directory.</p>"
        echo "    </div>"
        
        echo "  </div>"
        echo "</body>"
        echo "</html>"
    } > "$output_file"
    
    echo "HTML report generated: $output_file"
    return 0
}

# Export functions
export -f generate_qc_visualizations
export -f create_multi_threshold_overlays
export -f generate_html_report

log_message "Visualization module loaded"
