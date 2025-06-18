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

    # 1) Check if FLAIR is already brain extracted, otherwise extract
    local flair_brain
    local flair_mask
    
    # Check if the input file is already brain extracted (contains "_brain" or is from brain_extraction directory)
    if [[ "$flair_file" == *"_brain"* ]] || [[ "$flair_file" == *"brain_extraction"* ]]; then
        log_message "Input FLAIR appears to already be brain extracted: $flair_file"
        flair_brain="$flair_file"
        
        # Create a simple brain mask from the brain-extracted image
        local temp_mask_dir="$(dirname "$out_prefix")/temp_mask"
        mkdir -p "$temp_mask_dir"
        flair_mask="${temp_mask_dir}/flair_brain_mask.nii.gz"
        fslmaths "$flair_brain" -bin "$flair_mask"
        log_message "Created brain mask from extracted image: $flair_mask"
    else
        log_message "Performing brain extraction on FLAIR image..."
        local flair_basename
        flair_basename=$(basename "$flair_file" .nii.gz)
        
        # Use standardized module directory pattern like in preprocess.sh
        local brainextr_dir=$(create_module_dir "brain_extraction")
        local brain_prefix="${brainextr_dir}/${flair_basename}_"

        # Determine ANTs bin path
        local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
        
        # Execute brain extraction using enhanced ANTs command execution
        execute_ants_command "brain_extraction_flair" "Brain extraction for FLAIR hyperintensity analysis" \
          ${ants_bin}/antsBrainExtraction.sh \
          -d 3 \
          -a "$flair_file" \
          -o "$brain_prefix" \
          -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
          -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
          -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
          -k 1

        flair_brain="${brain_prefix}BrainExtractionBrain.nii.gz"
        flair_mask="${brain_prefix}BrainExtractionMask.nii.gz"
    fi

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
        local t1_dims=$(fslinfo "$t1_file" | grep ^dim | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        local flair_dims=$(fslinfo "$flair_brain" | grep ^dim | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        
        if [ "$t1_dims" = "$flair_dims" ]; then
            log_message "T1 and FLAIR have matching dimensions. Skipping registration."
            cp "$t1_file" "$t1_registered"
        else
            log_message "Registering T1 to FLAIR for consistent dimensionality"
            flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -dof 6
        fi

        # Run FSL FAST for high-quality tissue segmentation with posterior probability maps
        log_message "Running FSL FAST for tissue segmentation with posterior probability maps"
        
        # Check if T1 is already brain extracted, otherwise extract
        local t1_brain_file
        if [[ "$t1_registered" == *"_brain"* ]] || [[ "$t1_registered" == *"brain_extraction"* ]]; then
            log_message "T1 appears to already be brain extracted"
            t1_brain_file="$t1_registered"
        else
            log_message "Extracting T1 brain for tissue segmentation"
            local t1_basename=$(basename "$t1_registered" .nii.gz)
            local t1_brain_dir=$(create_module_dir "brain_extraction")
            local t1_brain_prefix="${t1_brain_dir}/${t1_basename}_"
            t1_brain_file="${t1_brain_prefix}BrainExtractionBrain.nii.gz"
            
            if [ ! -f "$t1_brain_file" ]; then
                # Use ANTs brain extraction for consistency
                local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
                execute_ants_command "brain_extraction_t1" "Brain extraction for T1 tissue segmentation" \
                  ${ants_bin}/antsBrainExtraction.sh \
                  -d 3 \
                  -a "$t1_registered" \
                  -o "$t1_brain_prefix" \
                  -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
                  -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
                  -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
                  -k 1
            fi
        fi
        
        # Run FAST on T1 brain
        fast -t 1 -n 3 -o "${temp_dir}/fast" "$t1_brain_file"
        
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
    
    # Create anatomically accurate supratentorial mask using atlas-based approach
    local brain_mask="${out_prefix}_brain_mask.nii.gz"
    fslmaths "$flair_brain" -bin "$brain_mask"
    
    # Use atlas-based supratentorial mask creation with fallback to z-cut
    create_supratentorial_mask "$brain_mask" "$flair_brain" "$supratentorial_mask"
    
    # Create a cortical ribbon mask (GM/WM boundary) using modal dilation
    fslmaths "$wm_mask" -dilM -sub "$wm_mask" -mul "$gm_mask" -bin "$cortical_ribbon_mask"
    
    # 3) Implement regional WM statistics to address inhomogeneity
    log_message "Computing regional WM statistics to address tissue inhomogeneity..."
    
    # Get global WM stats for reference
    local global_mean_wm=$(fslstats "$flair_brain" -k "$wm_mask" -M)
    local global_sd_wm=$(fslstats "$flair_brain" -k "$wm_mask" -S)
    log_message "Global WM mean: $global_mean_wm   Global WM std: $global_sd_wm"
    
    # Find ALL existing atlas-based segmentation masks for region-specific analysis
    local atlas_regions=()
    find_all_atlas_regions atlas_regions
    
    if [ ${#atlas_regions[@]} -gt 0 ]; then
        log_message "Found ${#atlas_regions[@]} atlas-based region masks for sophisticated per-region analysis"
        
        # Apply GMM-based analysis to each atlas region separately
        apply_per_region_gmm_analysis "$flair_brain" atlas_regions "$temp_dir" "$out_prefix"
        
        log_message "Using advanced per-region GMM-based thresholding with atlas-specific z-scoring"
        
        # Use per-region GMM results as primary detection method
        local thresholds=("ATLAS_GMM")
    else
        log_formatted "ERROR" "No atlas-based segmentation masks found - cannot proceed with atlas-based analysis"
        return 1
    fi
    
    # Process atlas-based GMM analysis across all regions
    for mult in "${thresholds[@]}"; do
        log_message "Processing atlas-based method: $mult"
        
        if [ "$mult" = "ATLAS_GMM" ]; then
            # Use per-region atlas-based GMM detection
            log_message "Using per-region atlas-based GMM detection with connectivity weighting"
            
            local final_mask="${out_prefix}_threshATLAS_GMM.nii.gz"
            local cleaned="${out_prefix}_cleanedATLAS_GMM.nii.gz"
            
            # Use the combined atlas GMM result
            if [ -n "$ATLAS_GMM_RESULT" ] && [ -f "$ATLAS_GMM_RESULT" ]; then
                cp "$ATLAS_GMM_RESULT" "$cleaned"
                
                # Apply minimum cluster size filtering
                local min_size="${MIN_HYPERINTENSITY_SIZE:-4}"
                log_message "Applying cluster filtering with minimum size: $min_size voxels"
                
                if cluster --in="$cleaned" --thresh=0.5 --connectivity=26 \
                          --minextent="$min_size" --oindex="$final_mask" > /dev/null 2>&1; then
                    log_message "✓ Atlas GMM cluster filtering successful"
                else
                    log_formatted "WARNING" "Atlas GMM cluster filtering failed, using raw atlas-based mask"
                    cp "$cleaned" "$final_mask"
                fi
            else
                log_formatted "ERROR" "Atlas GMM result not available"
                return 1
            fi
        else
            log_formatted "ERROR" "Unsupported threshold method: $mult"
            return 1
        fi
        
        log_message "Final atlas-based hyperintensity mask (method $mult) saved to: $final_mask"
        
        # Create binary version for analysis
        fslmaths "$final_mask" -bin "${out_prefix}_thresh${mult}_bin.nii.gz"
        
        # Create intensity-preserved version for heat colormap visualization
        local intensity_version="${out_prefix}_thresh${mult}_intensity.nii.gz"
        fslmaths "$flair_brain" -mas "${out_prefix}_thresh${mult}_bin.nii.gz" "$intensity_version"
        log_message "Intensity-preserved hyperintensity mask created: $intensity_version"
        
        # Analyze clusters
        log_message "Analyzing clusters for method $mult..."
        analyze_clusters "${out_prefix}_thresh${mult}_bin.nii.gz" "${out_prefix}_clusters_${mult}"
    done
    
    # Clean up temporary files
    rm -rf "$temp_dir"

    # 5) Optional: Convert to .mgz or create a freeview script
    local flair_norm_mgz="${out_prefix}_flair.mgz"
    local hyper_clean_mgz="${out_prefix}_hyper.mgz"
    mri_convert "$flair_brain" "$flair_norm_mgz"
    
    # CRITICAL FIX: Use actual created files instead of hardcoded thresh1.5
    local created_mask=""
    local created_method=""
    
    # Find the actual hyperintensity mask that was created
    for method in "${thresholds[@]}"; do
        local candidate_mask="${out_prefix}_thresh${method}_bin.nii.gz"
        if [ -f "$candidate_mask" ]; then
            created_mask="$candidate_mask"
            created_method="$method"
            break
        fi
    done
    
    if [ -n "$created_mask" ] && [ -f "$created_mask" ]; then
        # Convert the actual created mask to mgz
        local intensity_version="${out_prefix}_thresh${created_method}.nii.gz"
        if [ -f "$intensity_version" ]; then
            mri_convert "$intensity_version" "$hyper_clean_mgz"
        else
            # Create intensity version from binary mask
            fslmaths "$flair_brain" -mas "$created_mask" "$intensity_version"
            mri_convert "$intensity_version" "$hyper_clean_mgz"
        fi
        
        cat > "${out_prefix}_view_in_freeview.sh" << EOC
#!/usr/bin/env bash
freeview -v "$flair_norm_mgz" \\
         -v "$hyper_clean_mgz":colormap=heat:opacity=0.5
EOC
        chmod +x "${out_prefix}_view_in_freeview.sh"

        log_message "Hyperintensity detection complete. To view in freeview, run: ${out_prefix}_view_in_freeview.sh"
        
        # Perform cluster analysis using the actual created threshold
        analyze_clusters "$created_mask" "${out_prefix}_clusters_${created_method}"
        
        # Quantify volumes
        quantify_volumes "$out_prefix"
        
        # Create 3D rendering if we have suitable files
        local hyper_mask="$created_mask"
    else
        log_formatted "WARNING" "No hyperintensity masks were created - skipping visualization"
        return 1
    fi
    if [ -f "$hyper_mask" ]; then
        # Look for pons segmentation file in various possible locations
        local pons_candidates=(
            "${RESULTS_DIR}/comprehensive_analysis/original_space/"*"pons"*".nii.gz"
            "${RESULTS_DIR}/segmentation/detailed_brainstem/"*"pons"*".nii.gz"
            "${RESULTS_DIR}/segmentation/"*"pons"*".nii.gz"
            "$(dirname "$out_prefix")/../"*"pons"*".nii.gz"
        )
        
        local pons_file=""
        for candidate in "${pons_candidates[@]}"; do
            if [ -f "$candidate" ]; then
                pons_file="$candidate"
                log_message "Found pons file for 3D rendering: $pons_file"
                break
            fi
        done
        
        if [ -n "$pons_file" ] && [ -f "$pons_file" ]; then
            log_message "Creating 3D rendering with FreeSurfer..."
            create_3d_rendering "$hyper_mask" "$pons_file" "$(dirname "$out_prefix")"
        else
            log_message "No pons segmentation found - skipping FreeSurfer 3D rendering"
            log_message "Creating simple 3D visualization script..."
            
            # Create a basic view_3d.sh script even without pons segmentation
            local view_script="$(dirname "$out_prefix")/view_3d.sh"
            cat > "$view_script" << EOF
#!/usr/bin/env bash
#
# 3D Visualization Script (Basic)
# Generated: $(date)
#
echo "Starting 3D visualization..."

if command -v freeview &> /dev/null; then
    echo "Using FreeSurfer freeview..."
    freeview -v "$flair_brain" \\
             -v "$hyper_mask":colormap=heat:opacity=0.7
elif command -v fsleyes &> /dev/null; then
    echo "Using FSLeyes..."
    fsleyes "$flair_brain" "$hyper_mask" -cm hot -a 70
else
    echo "ERROR: No visualization tools found (freeview or fsleyes)"
    exit 1
fi
EOF
            chmod +x "$view_script"
            log_message "Basic 3D visualization script created: $view_script"
        fi
    else
        log_formatted "WARNING" "No hyperintensity mask found for 3D rendering"
    fi
    
    # Create multi-threshold comparison visualization
    log_message "Creating multi-threshold comparison visualization..."
    create_multi_threshold_comparison "$flair_brain" "$out_prefix" "$(dirname "$out_prefix")"
    
    # Create intensity profiles for analysis
    log_message "Creating intensity profiles for hyperintensity analysis..."
    create_intensity_profiles "$flair_brain" "$(dirname "$out_prefix")/intensity_profiles"
    
    return 0
}

# Function to create anatomically accurate supratentorial mask using atlas-based approach
create_supratentorial_mask() {
    local brain_mask="$1"
    local reference_image="$2"
    local output_mask="$3"
    
    log_message "Creating anatomically accurate supratentorial mask using atlas-based approach..."
    
    if [ ! -f "$brain_mask" ] || [ ! -f "$reference_image" ]; then
        log_formatted "ERROR" "Missing input files for supratentorial mask creation"
        return 1
    fi
    
    local temp_dir=$(mktemp -d)
    local atlas_success=false
    
    # Method 1: Try Harvard-Oxford atlas (if available)
    if [ -n "$FSLDIR" ] && [ -d "$FSLDIR/data/atlases" ]; then
        log_message "Attempting Harvard-Oxford atlas-based supratentorial mask..."
        
        local ho_cortical="$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-cort-maxprob-thr0-2mm.nii.gz"
        local ho_subcortical="$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr0-2mm.nii.gz"
        
        if [ -f "$ho_cortical" ] && [ -f "$ho_subcortical" ]; then
            # Register Harvard-Oxford atlas to subject space
            local atlas_registered="${temp_dir}/ho_atlas_registered.nii.gz"
            local atlas_combined="${temp_dir}/ho_combined.nii.gz"
            
            # Combine cortical and subcortical atlases
            fslmaths "$ho_cortical" -add "$ho_subcortical" -bin "$atlas_combined"
            
            # Register to subject space using FLIRT
            if flirt -in "$atlas_combined" -ref "$reference_image" -out "$atlas_registered" \
                    -interp nearestneighbour -dof 12 > /dev/null 2>&1; then
                
                # Create supratentorial mask by excluding brainstem regions
                # Harvard-Oxford subcortical labels: 7=Brainstem
                local ho_sub_reg="${temp_dir}/ho_sub_registered.nii.gz"
                if flirt -in "$ho_subcortical" -ref "$reference_image" -out "$ho_sub_reg" \
                        -interp nearestneighbour -dof 12 > /dev/null 2>&1; then
                    
                    # Create mask excluding brainstem (label 7) and cerebellum regions
                    fslmaths "$ho_sub_reg" -thr 7 -uthr 7 -bin "${temp_dir}/brainstem_mask.nii.gz"
                    
                    # Create supratentorial mask (brain - brainstem - cerebellum)
                    fslmaths "$atlas_registered" -sub "${temp_dir}/brainstem_mask.nii.gz" \
                             -thr 0 -bin -mas "$brain_mask" "$output_mask"
                    
                    atlas_success=true
                    log_message "✓ Successfully created Harvard-Oxford atlas-based supratentorial mask"
                fi
            fi
        fi
    fi
    
    # Method 2: Try MNI template-based approach (if available)
    if [ "$atlas_success" = false ] && [ -n "$FSLDIR" ] && [ -d "$FSLDIR/data/standard" ]; then
        log_message "Attempting MNI template-based supratentorial mask..."
        
        local mni_brain="$FSLDIR/data/standard/MNI152_T1_2mm_brain.nii.gz"
        if [ -f "$mni_brain" ]; then
            # Create MNI-based supratentorial mask using anatomical landmarks
            local mni_registered="${temp_dir}/mni_registered.nii.gz"
            
            if flirt -in "$mni_brain" -ref "$reference_image" -out "$mni_registered" \
                    -dof 12 > /dev/null 2>&1; then
                
                # Use MNI coordinates to exclude infratentorial regions
                # Approximate supratentorial region: exclude inferior regions (z < -40mm in MNI space)
                local mni_dims=($(fslinfo "$mni_brain" | grep ^dim | awk '{print $2}'))
                local mni_z_dim=${mni_dims[2]}
                local mni_exclude_slices=$(echo "$mni_z_dim * 0.25" | bc | cut -d. -f1)  # Bottom 25%
                
                # Create supratentorial mask in MNI space
                local mni_supra="${temp_dir}/mni_supratentorial.nii.gz"
                fslmaths "$mni_brain" -bin -roi 0 -1 0 -1 $mni_exclude_slices -1 0 1 \
                         -binv -mul "$mni_brain" -bin "$mni_supra"
                
                # Register back to subject space
                if flirt -in "$mni_supra" -ref "$reference_image" -out "$output_mask" \
                        -interp nearestneighbour -dof 12 > /dev/null 2>&1; then
                    
                    fslmaths "$output_mask" -mas "$brain_mask" "$output_mask"
                    atlas_success=true
                    log_message "✓ Successfully created MNI template-based supratentorial mask"
                fi
            fi
        fi
    fi
    
    # Method 3: Fallback to enhanced z-cut method with morphological refinement
    if [ "$atlas_success" = false ]; then
        log_message "Atlas-based methods failed, using enhanced anatomical z-cut method..."
        
        # Get dimensions
        local dims=($(fslinfo "$brain_mask" | grep ^dim | awk '{print $2}'))
        local z_dim=${dims[2]}
        
        # Use more conservative exclusion (15% instead of 20%) and add morphological operations
        local z_exclude=$(echo "$z_dim * 0.15" | bc | cut -d. -f1)
        
        # Create initial supratentorial mask
        fslmaths "$brain_mask" -roi 0 -1 0 -1 $z_exclude -1 0 1 -binv -mul "$brain_mask" \
                 "${temp_dir}/initial_supra.nii.gz"
        
        # Morphological operations to refine the mask
        # Erode slightly to remove connections to brainstem
        fslmaths "${temp_dir}/initial_supra.nii.gz" -ero -dilF "$output_mask"
        
        # Fill holes and smooth
        fslmaths "$output_mask" -fillh -s 1 -thr 0.5 -bin "$output_mask"
        
        log_message "✓ Created enhanced z-cut based supratentorial mask"
    fi
    
    # Quality check: ensure mask is reasonable
    local mask_volume=$(fslstats "$output_mask" -V | awk '{print $2}')
    local brain_volume=$(fslstats "$brain_mask" -V | awk '{print $2}')
    local ratio=$(echo "scale=2; $mask_volume / $brain_volume" | bc)
    
    log_message "Supratentorial mask volume: ${mask_volume} mm³ (${ratio} of brain volume)"
    
    if (( $(echo "$ratio < 0.4" | bc -l) )) || (( $(echo "$ratio > 0.9" | bc -l) )); then
        log_formatted "WARNING" "Supratentorial mask ratio seems unusual: $ratio"
        log_message "Expected range: 0.4-0.9 of total brain volume"
    fi
    
    rm -rf "$temp_dir"
    return 0
}

# Function to find ALL existing atlas-based segmentation regions
find_all_atlas_regions() {
    local -n regions_array=$1
    regions_array=()
    
    log_message "Searching for ALL atlas-based segmentation regions..."
    
    # Primary locations for Talairach atlas regions
    local search_dirs=(
        "${RESULTS_DIR}/segmentation/detailed_brainstem"
        "${RESULTS_DIR}/segmentation/pons"
        "${RESULTS_DIR}/comprehensive_analysis/original_space"
    )
    
    # Talairach region patterns to find
    local region_patterns=(
        "*left_medulla*.nii.gz"
        "*right_medulla*.nii.gz"
        "*left_pons*.nii.gz"
        "*right_pons*.nii.gz"
        "*left_midbrain*.nii.gz"
        "*right_midbrain*.nii.gz"
        "*_pons.nii.gz"
    )
    
    # Search for all region masks
    for search_dir in "${search_dirs[@]}"; do
        if [ -d "$search_dir" ]; then
            log_message "Searching directory: $search_dir"
            
            for pattern in "${region_patterns[@]}"; do
                for region_file in "$search_dir"/$pattern; do
                    if [ -f "$region_file" ]; then
                        # Skip intensity/derivative files
                        local basename_file=$(basename "$region_file" .nii.gz)
                        if [[ "$basename_file" == *"_intensity"* ]] || [[ "$basename_file" == *"_flair_"* ]] || [[ "$basename_file" == *"_t1_"* ]] || [[ "$basename_file" == *"_clustered"* ]]; then
                            continue
                        fi
                        
                        # Validate mask has sufficient voxels
                        local mask_vol=$(fslstats "$region_file" -V | awk '{print $1}')
                        if [ "$mask_vol" -gt 10 ]; then
                            regions_array+=("$region_file")
                            local region_name=$(basename "$region_file" .nii.gz)
                            log_message "✓ Found region: $region_name (${mask_vol} voxels)"
                        fi
                    fi
                done
            done
        fi
    done
    
    # Remove duplicates and sort
    if [ ${#regions_array[@]} -gt 0 ]; then
        readarray -t regions_array < <(printf '%s\n' "${regions_array[@]}" | sort -u)
        log_message "Found ${#regions_array[@]} unique atlas-based regions for analysis"
    else
        log_formatted "ERROR" "No atlas-based segmentation regions found"
        return 1
    fi
    
    return 0
}

# Function to apply per-region GMM analysis to all atlas regions
apply_per_region_gmm_analysis() {
    local flair_image="$1"
    local -n regions_ref=$2
    local temp_dir="$3"
    local out_prefix="$4"
    
    log_message "Applying per-region GMM analysis to ${#regions_ref[@]} atlas regions..."
    
    # Create PERMANENT per-region analysis directory for debugging
    local per_region_dir="${RESULTS_DIR}/per_region_analysis"
    mkdir -p "$per_region_dir"
    
    # Store results for each region
    local region_results=()
    local combined_result="${per_region_dir}/atlas_gmm_combined.nii.gz"
    
    # Initialize combined result as zeros
    fslmaths "$flair_image" -mul 0 "$combined_result"
    
    # Create or find brain mask for filtering segmentation masks
    local brain_mask=""
    local brain_mask_candidates=(
        "${RESULTS_DIR}/brain_extraction/"*"_brain_mask.nii.gz"
        "${RESULTS_DIR}/segmentation/"*"_brain_mask.nii.gz"
        "${temp_dir}/../"*"_brain_mask.nii.gz"
        "$(dirname "$out_prefix")"*"_brain_mask.nii.gz"
    )
    
    # Find existing brain mask
    for candidate in "${brain_mask_candidates[@]}"; do
        for mask_file in $candidate; do
            if [ -f "$mask_file" ]; then
                brain_mask="$mask_file"
                log_message "Found brain mask: $(basename "$brain_mask")"
                break 2
            fi
        done
    done
    
    # If no brain mask found, create one from FLAIR
    if [ -z "$brain_mask" ] || [ ! -f "$brain_mask" ]; then
        log_message "Creating brain mask from FLAIR image..."
        brain_mask="${per_region_dir}/brain_mask_from_flair.nii.gz"
        
        # Create brain mask using simple thresholding + morphological operations
        local flair_mean=$(fslstats "$flair_image" -M)
        local brain_threshold=$(echo "$flair_mean * 0.1" | bc -l)
        
        fslmaths "$flair_image" -thr "$brain_threshold" -bin \
                 -fillh -dilM -ero -ero -dilM -dilM "$brain_mask"
        
        log_message "✓ Created brain mask from FLAIR image"
    fi
    
    # Validate brain mask
    local brain_voxels=$(fslstats "$brain_mask" -V | awk '{print $1}')
    if [ "$brain_voxels" -lt 1000 ]; then
        log_formatted "ERROR" "Brain mask too small ($brain_voxels voxels) - analysis will fail"
        return 1
    fi
    log_message "Using brain mask with $brain_voxels voxels for pre-filtering"
    
    # Process each region separately with brain masking
    for region_mask in "${regions_ref[@]}"; do
        local region_name=$(basename "$region_mask" .nii.gz)
        
        # FIXED: Proper region name extraction
        local region_base=""
        if [[ "$region_name" =~ (left_|right_)?(medulla|pons|midbrain) ]]; then
            region_base=$(echo "$region_name" | sed -E 's/.*(left_|right_)?(medulla|pons|midbrain).*/\2/')
            if [[ "$region_name" =~ left_ ]]; then
                region_base="left_${region_base}"
            elif [[ "$region_name" =~ right_ ]]; then
                region_base="right_${region_base}"
            fi
        else
            region_base=$(echo "$region_name" | sed -E 's/.*_([^_]+)$/\1/')
        fi
        
        # Validate and fallback
        if [ -z "$region_base" ] || [[ "$region_base" == *"/"* ]]; then
            region_base="unknown_region_$(date +%s)"
        fi
        
        log_message "Processing region: $region_base (FLAIR hyperintensity analysis)"
        
        # Create organized region-specific working directory with modality info
        local region_work_dir="${per_region_dir}/${region_base}_FLAIR_analysis"
        mkdir -p "$region_work_dir"
        
        # Create GMM analysis subdirectory for temp files
        local gmm_temp_dir="${region_work_dir}/gmm_analysis"
        mkdir -p "$gmm_temp_dir"
        
        # Check if mask needs resampling to match FLAIR space
        local region_resampled="${region_work_dir}/${region_base}_resampled.nii.gz"
        local mask_dims=$(fslinfo "$region_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        local flair_dims=$(fslinfo "$flair_image" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        
        if [ "$mask_dims" = "$flair_dims" ]; then
            cp "$region_mask" "$region_resampled"
        else
            log_message "Resampling $region_base mask to FLAIR space..."
            flirt -in "$region_mask" -ref "$flair_image" -out "$region_resampled" -interp nearestneighbour -dof 6
        fi
        
        # CRITICAL: Pre-filter segmentation mask with brain mask BEFORE any analysis
        local region_brain_masked="${region_work_dir}/${region_base}_brain_masked.nii.gz"
        log_message "Pre-filtering $region_base with brain mask to exclude non-brain voxels..."
        
        # Resample brain mask to match region if needed
        local brain_mask_resampled="$brain_mask"
        local brain_dims=$(fslinfo "$brain_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        if [ "$brain_dims" != "$flair_dims" ]; then
            brain_mask_resampled="${region_work_dir}/brain_mask_resampled.nii.gz"
            flirt -in "$brain_mask" -ref "$flair_image" -out "$brain_mask_resampled" -interp nearestneighbour -dof 6
        fi
        
        # Apply brain mask to region mask
        fslmaths "$region_resampled" -mas "$brain_mask_resampled" "$region_brain_masked"
        
        # Validate brain-masked region has sufficient voxels
        local brain_masked_voxels=$(fslstats "$region_brain_masked" -V | awk '{print $1}')
        local original_voxels=$(fslstats "$region_resampled" -V | awk '{print $1}')
        
        log_message "$region_base: $original_voxels voxels → $brain_masked_voxels brain voxels"
        
        if [ "$brain_masked_voxels" -lt 50 ]; then
            log_formatted "WARNING" "$region_base has insufficient brain voxels ($brain_masked_voxels) - skipping"
            continue
        fi
        
        # Use brain-masked region for all subsequent analysis
        region_resampled="$region_brain_masked"
        
        # Perform region-specific z-score normalization
        local region_zscore="${region_work_dir}/${region_base}_zscore.nii.gz"
        log_message "Normalizing FLAIR intensities for $region_base using region-specific statistics..."
        
        if normalize_flair_brainstem_zscore "$flair_image" "$region_resampled" "$region_zscore" "$region_base"; then
            
            # Apply GMM thresholding to this region - use organized temp directory
            local region_gmm_params="${gmm_temp_dir}/${region_base}_gmm_params.txt"
            local region_upper_tail="${region_work_dir}/${region_base}_upper_tail.nii.gz"
            
            log_message "Applying GMM analysis to $region_base (temp files in: $(basename "$gmm_temp_dir"))"
            if apply_gaussian_mixture_thresholding "$region_zscore" "$region_resampled" "$region_gmm_params" "$region_upper_tail" "$gmm_temp_dir"; then
                
                # Apply connectivity weighting for this region
                local region_connectivity="${region_work_dir}/${region_base}_connectivity.nii.gz"
                log_message "Applying connectivity weighting for $region_base..."
                if apply_connectivity_weighting "$region_upper_tail" "$region_zscore" "$region_connectivity"; then
                    
                    # Add this region's result to combined result
                    fslmaths "$combined_result" -add "$region_connectivity" "$combined_result"
                    region_results+=("$region_connectivity")
                    
                    log_message "✓ Successfully processed $region_base with GMM analysis"
                    
                    # Create region-specific output files
                    local region_output="${out_prefix}_${region_base}_GMM.nii.gz"
                    cp "$region_connectivity" "$region_output"
                    
                else
                    log_formatted "WARNING" "Connectivity weighting failed for $region_base"
                fi
            else
                log_formatted "WARNING" "GMM thresholding failed for $region_base"
            fi
        else
            log_formatted "WARNING" "Z-score normalization failed for $region_base"
        fi
    done
    
    # Finalize combined result
    if [ ${#region_results[@]} -gt 0 ]; then
        fslmaths "$combined_result" -bin "$combined_result"
        log_message "✓ Combined results from ${#region_results[@]} regions into atlas-based GMM detection"
        
        # Store combined result globally
        export ATLAS_GMM_RESULT="$combined_result"
        
        return 0
    else
        log_formatted "ERROR" "No regions successfully processed with GMM analysis"
        return 1
    fi
}

# Function to perform region-specific z-score normalization (not whole brainstem)
normalize_flair_brainstem_zscore() {
    local flair_image="$1"
    local region_mask="$2"  # This should be the specific region, not whole brainstem
    local output_zscore="$3"
    local region_name="${4:-unknown_region}"  # Accept region name as parameter
    
    log_message "Performing REGION-SPECIFIC z-score normalization for $region_name (FLAIR hyperintensity detection)..."
    
    # CRITICAL FIX: Get REGION-specific statistics, not whole brainstem
    local stats=$(fslstats "$flair_image" -k "$region_mask" -M -S)
    local region_mean=$(echo "$stats" | awk '{print $1}')
    local region_std=$(echo "$stats" | awk '{print $2}')
    
    if [ "$region_std" = "0.000000" ] || [ -z "$region_std" ]; then
        log_formatted "ERROR" "Invalid $region_name statistics for z-score normalization"
        return 1
    fi
    
    log_message "$region_name statistics: mean=$region_mean, std=$region_std"
    
    # Compute z-score: (intensity - region_mean) / region_std
    fslmaths "$flair_image" -sub "$region_mean" -div "$region_std" "$output_zscore"
    
    # Validate z-score result
    local zscore_range=$(fslstats "$output_zscore" -k "$region_mask" -R)
    log_message "Z-score range in $region_name: $zscore_range"
    
    return 0
}

# Function to apply Gaussian Mixture Model (n=3) thresholding
apply_gaussian_mixture_thresholding() {
    local zscore_image="$1"
    local region_mask="$2"
    local gmm_params_file="$3"
    local output_mask="$4"
    local gmm_temp_dir="${5:-/tmp}"  # Accept temp directory parameter
    
    # Ensure output mask has proper .nii.gz extension
    if [[ "$output_mask" != *.nii.gz ]]; then
        output_mask="${output_mask}.nii.gz"
    fi
    
    # Extract region name from mask file for better logging
    local region_name=$(basename "$region_mask" .nii.gz | sed -E 's/.*_(left_|right_)?(medulla|pons|midbrain).*$/\2/' | sed -E 's/.*_([^_]+)_flair_space$/\1/')
    
    log_message "Applying GMM analysis to ${region_name} for FLAIR hyperintensity detection..."
    if [[ "$region_name" == *"/"* ]] || [ ${#region_name} -gt 20 ]; then
        region_name="region"
    fi
    
    log_message "Applying Gaussian Mixture Model (n=3) thresholding for $region_name..."
    
    # Extract z-score values from region for GMM analysis
    local temp_dir=$(mktemp -d)
    local region_values="${temp_dir}/region_values.txt"
    
    # Ensure region mask is properly binarized for reliable voxel extraction
    local binary_mask="${temp_dir}/binary_mask.nii.gz"
    fslmaths "$region_mask" -thr 0.5 -bin "$binary_mask"
    
    # Validate mask has reasonable size
    local mask_volume=$(fslstats "$binary_mask" -V | awk '{print $1}')
    log_message "Region $region_name mask contains $mask_volume voxels"
    
    if [ "$mask_volume" -lt 10 ]; then
        log_formatted "ERROR" "Region mask too small ($mask_volume voxels) for meaningful GMM analysis"
        fslmaths "$zscore_image" -mas "$binary_mask" -thr 2.0 -bin "$output_mask"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Extract z-score values within binary region mask using robust method
    log_message "Extracting individual voxel values from brain-masked $region_name region..."
    
    # CRITICAL FIX: Use direct Python-based voxel extraction for reliable results
    log_message "Extracting individual voxel values from brain-masked $region_name region..."
    
    # Create masked z-score image first
    local temp_masked="${temp_dir}/temp_masked_values.nii.gz"
    fslmaths "$zscore_image" -mas "$binary_mask" "$temp_masked"
    
    # ENHANCED DEBUGGING: Check intermediate files before Python extraction
    local temp_stats=$(fslstats "$temp_masked" -V)
    local masked_voxels=$(echo "$temp_stats" | awk '{print $1}')
    local masked_volume=$(echo "$temp_stats" | awk '{print $2}')
    local masked_range=$(fslstats "$temp_masked" -R)
    
    log_message "DEBUG: Temp masked file stats - Voxels: $masked_voxels, Volume: $masked_volume mm³, Range: $masked_range"
    
    # Use external Python script for reliable voxel-by-voxel extraction
    if command -v python3 &> /dev/null; then
        # Determine script directory (relative to this module)
        local script_dir="$(dirname "${BASH_SOURCE[0]}")/../scripts"
        local extract_script="$script_dir/extract_voxel_values.py"
        
        # Check if external script exists
        if [ -f "$extract_script" ]; then
            log_message "Using external Python script for voxel extraction: $(basename "$extract_script")"
            
            # Call external script with debug output redirected
            if python3 "$extract_script" "$temp_masked" "$region_values" 2>"${temp_dir}/python_debug.log"; then
                log_message "✓ External Python script completed successfully"
            else
                log_formatted "WARNING" "External Python script failed, trying fallback"
                echo "0" > "$region_values"
            fi
            
            # Log Python debug output
            if [ -f "${temp_dir}/python_debug.log" ]; then
                while IFS= read -r line; do
                    log_message "PYTHON: $line"
                done < "${temp_dir}/python_debug.log"
            fi
        else
            log_formatted "WARNING" "External Python script not found: $extract_script"
            log_message "Falling back to inline Python extraction..."
            
            # Fallback inline Python (simplified version)
            python3 -c "
import nibabel as nib
import numpy as np
try:
    img = nib.load('$temp_masked')
    data = img.get_fdata()
    finite_values = data[(data != 0) & np.isfinite(data)]
    if len(finite_values) > 0:
        for val in finite_values:
            print(f'{val:.6f}')
    else:
        print('0')
except Exception as e:
    print('0')
" > "$region_values" 2>"${temp_dir}/python_debug.log"
        fi
        
        # Validate Python extraction worked
        local python_count=$(grep -v '^#' "$region_values" | grep -v '^$' | wc -l)
        log_message "Python extracted $python_count values from masked region"
        
        if [ "$python_count" -lt 10 ]; then
            log_formatted "WARNING" "Python extraction yielded only $python_count values, investigating..."
            
            # Additional debugging for low extraction count
            log_message "DEBUG: Checking if temp_masked file has actual data..."
            local temp_nonzero=$(fslstats "$temp_masked" -l 0.0001 -V | awk '{print $1}')
            log_message "DEBUG: Non-zero voxels above 0.0001: $temp_nonzero"
            
            # Try FSL histogram approach as fallback
            log_message "Trying FSL histogram fallback..."
            local hist_range=$(fslstats "$temp_masked" -R)
            local hist_min=$(echo "$hist_range" | awk '{print $1}')
            local hist_max=$(echo "$hist_range" | awk '{print $2}')
            
            if [ "$hist_max" != "0.000000" ] && [ "$hist_min" != "$hist_max" ]; then
                fslstats "$temp_masked" -H 1000 "$hist_min" "$hist_max" | \
                awk -v min="$hist_min" -v max="$hist_max" 'BEGIN{bin=0; range=max-min} {if($1>0) for(i=0;i<$1;i++) print min+(bin*range/1000); bin++}' > "$region_values"
                
                local hist_count=$(wc -l < "$region_values")
                log_message "FSL histogram extracted $hist_count values"
            else
                log_formatted "ERROR" "No valid range for histogram extraction: $hist_min to $hist_max"
            fi
        fi
    else
        log_formatted "WARNING" "Python not available - using FSL histogram fallback"
        # Enhanced FSL histogram fallback
        local hist_range=$(fslstats "$temp_masked" -R)
        local hist_min=$(echo "$hist_range" | awk '{print $1}')
        local hist_max=$(echo "$hist_range" | awk '{print $2}')
        
        if [ "$hist_max" != "0.000000" ] && [ "$hist_min" != "$hist_max" ]; then
            fslstats "$temp_masked" -H 1000 "$hist_min" "$hist_max" | \
            awk -v min="$hist_min" -v max="$hist_max" 'BEGIN{bin=0; range=max-min} {if($1>0) for(i=0;i<$1;i++) print min+(bin*range/1000); bin++}' > "$region_values"
        else
            echo "0" > "$region_values"
        fi
    fi
    
    rm -f "$temp_masked"
    
    # Remove any remaining invalid values
    grep -E '^-?[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?$' "$region_values" > "${region_values}.clean" 2>/dev/null && \
    mv "${region_values}.clean" "$region_values"
    
    # Check if we have sufficient data points for robust GMM
    local num_voxels=$(wc -l < "$region_values")
    log_message "Extracted $num_voxels z-score values from $region_name for GMM analysis"
    
    if [ "$num_voxels" -lt 50 ]; then
        log_formatted "WARNING" "Insufficient $region_name voxels ($num_voxels) for robust GMM clustering"
        log_message "GMM requires minimum 50 voxels, using enhanced statistical threshold instead"
        
        # Use enhanced statistical threshold based on region statistics
        local region_stats=$(fslstats "$zscore_image" -k "$binary_mask" -M -S)
        local region_mean=$(echo "$region_stats" | awk '{print $1}')
        local region_std=$(echo "$region_stats" | awk '{print $2}')
        local enhanced_threshold=$(echo "$region_mean + 2.5 * $region_std" | bc -l)
        
        log_message "Using enhanced statistical threshold: $enhanced_threshold"
        fslmaths "$zscore_image" -mas "$binary_mask" -thr "$enhanced_threshold" -bin "$output_mask"
        rm -rf "$temp_dir"
        return 0
    fi
    
    log_message "Analyzing $num_voxels $region_name voxels with GMM..."
    
    # Adjust GMM components based on available data
    local n_components=3
    if [ "$num_voxels" -lt 200 ]; then
        n_components=2
        log_message "Using 2-component GMM due to limited data ($num_voxels voxels)"
    fi
    
    # Enhanced Python script for GMM analysis with better error handling
    python3 -c "
import numpy as np
from sklearn.mixture import GaussianMixture
import sys
import warnings
warnings.filterwarnings('ignore')

# Read z-score values with robust parsing
try:
    # Try different parsing methods
    values = []
    with open('$region_values', 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                try:
                    val = float(line)
                    if not np.isnan(val) and not np.isinf(val):
                        values.append(val)
                except ValueError:
                    continue
    
    values = np.array(values)
    
    if len(values) < 20:
        print(f'Insufficient valid data points: {len(values)}')
        with open('$gmm_params_file', 'w') as f:
            f.write('THRESHOLD=2.0\\n')
        sys.exit(0)
    
    print(f'Processing {len(values)} valid z-score values')
    print(f'Value range: {np.min(values):.3f} to {np.max(values):.3f}')
    
    values = values.reshape(-1, 1)
    
    # Fit GMM with adaptive components
    n_comp = min($n_components, max(2, len(values) // 30))
    print(f'Using {n_comp}-component GMM')
    
    gmm = GaussianMixture(n_components=n_comp, random_state=42, max_iter=200)
    gmm.fit(values)
    
    # Get component parameters
    means = gmm.means_.flatten()
    stds = np.sqrt(gmm.covariances_.flatten())
    weights = gmm.weights_
    
    # Sort components by mean (low, medium, high intensity)
    sort_idx = np.argsort(means)
    
    # For hyperintensity detection, focus on upper tail component
    upper_component = sort_idx[-1]  # Highest mean component
    upper_mean = means[upper_component]
    upper_std = stds[upper_component]
    upper_weight = weights[upper_component]
    
    print(f'GMM Components: {n_comp}')
    print(f'Component means: {[f\"{m:.3f}\" for m in sorted(means)]}')
    print(f'Component weights: {[f\"{w:.3f}\" for w in weights[sort_idx]]}')
    print(f'Upper component: mean={upper_mean:.3f}, std={upper_std:.3f}, weight={upper_weight:.3f}')
    
    # Adaptive threshold based on component characteristics
    if n_comp == 2:
        # For 2-component model: normal vs hyperintense
        threshold = upper_mean + 1.0 * upper_std
    else:
        # For 3-component model: low, normal, hyperintense
        threshold = upper_mean + 1.5 * upper_std
    
    # Weight-adjusted threshold for robust detection
    if upper_weight < 0.05:
        # Very small hyperintense component - be more conservative
        threshold = upper_mean + 2.5 * upper_std
        print(f'Small hyperintense component detected, using conservative threshold')
    elif upper_weight < 0.15:
        # Small but significant component
        threshold = upper_mean + 2.0 * upper_std
        print(f'Small hyperintense component, using moderate threshold')
    
    # Ensure threshold is reasonable (not too low)
    min_threshold = np.percentile(values, 95)  # At least 95th percentile
    threshold = max(threshold, min_threshold)
    
    # Save comprehensive parameters
    with open('$gmm_params_file', 'w') as f:
        f.write(f'GMM_COMPONENTS={n_comp}\\n')
        f.write(f'N_VOXELS={len(values)}\\n')
        f.write(f'UPPER_MEAN={upper_mean:.6f}\\n')
        f.write(f'UPPER_STD={upper_std:.6f}\\n')
        f.write(f'UPPER_WEIGHT={upper_weight:.6f}\\n')
        f.write(f'THRESHOLD={threshold:.6f}\\n')
        f.write(f'MIN_THRESHOLD={min_threshold:.6f}\\n')
        f.write(f'DATA_RANGE={np.min(values):.3f}_{np.max(values):.3f}\\n')
    
    print(f'Final GMM threshold: {threshold:.3f} (weight: {upper_weight:.3f}, components: {n_comp})')
    
except Exception as e:
    print(f'GMM analysis failed: {e}')
    import traceback
    traceback.print_exc()
    # Create robust fallback threshold based on data percentiles
    if len(values) > 10:
        fallback_threshold = np.percentile(values, 97.5)  # 97.5th percentile
        print(f'Using data-driven fallback threshold: {fallback_threshold:.3f}')
    else:
        fallback_threshold = 2.0
        print('Using default fallback threshold: 2.0')
    
    with open('$gmm_params_file', 'w') as f:
        f.write(f'THRESHOLD={fallback_threshold:.6f}\\n')
        f.write(f'GMM_FAILED=true\\n')
        f.write(f'N_VOXELS={len(values)}\\n')
"
    
    # Read threshold from GMM analysis with enhanced validation
    local threshold="2.0"  # Default fallback
    local gmm_status="unknown"
    
    if [ -f "$gmm_params_file" ] && [ -s "$gmm_params_file" ]; then
        # Extract threshold with proper sanitization - use exact match to avoid MIN_THRESHOLD
        threshold=$(grep "^THRESHOLD=" "$gmm_params_file" | cut -d'=' -f2 | tr -d '\n\r' | awk '{print $1}')
        local n_voxels=$(grep "N_VOXELS=" "$gmm_params_file" | cut -d'=' -f2 | tr -d '\n\r' | awk '{print $1}')
        local gmm_failed=$(grep "GMM_FAILED=" "$gmm_params_file" | cut -d'=' -f2 | tr -d '\n\r')
        
        # Validate threshold is a valid number
        if ! echo "$threshold" | grep -E '^[0-9]+\.?[0-9]*$' >/dev/null; then
            log_formatted "WARNING" "Invalid threshold value '$threshold', using fallback"
            threshold="2.0"
        fi
        
        if [ "$gmm_failed" = "true" ]; then
            gmm_status="failed (using data-driven fallback)"
        else
            local n_components=$(grep "GMM_COMPONENTS=" "$gmm_params_file" | cut -d'=' -f2 | tr -d '\n\r')
            local upper_weight=$(grep "UPPER_WEIGHT=" "$gmm_params_file" | cut -d'=' -f2 | tr -d '\n\r')
            gmm_status="success (${n_components} components, weight: ${upper_weight})"
        fi
        
        log_message "✓ GMM analysis for $region_name: $gmm_status"
        log_message "  Using threshold: $threshold (from $n_voxels voxels)"
    else
        log_formatted "WARNING" "GMM analysis completely failed for $region_name, using fallback: $threshold"
        gmm_status="completely failed"
    fi
    
    # Validate threshold value before applying
    if [ -z "$threshold" ] || ! echo "$threshold" | grep -E '^[0-9]+\.?[0-9]*$' >/dev/null; then
        log_formatted "ERROR" "Invalid threshold value: '$threshold', using fallback"
        threshold="2.0"
    fi
    
    # Apply threshold to create binary mask with error checking
    log_message "Applying threshold $threshold to create binary mask..."
    if ! fslmaths "$zscore_image" -mas "$region_mask" -thr "$threshold" -bin "$output_mask"; then
        log_formatted "ERROR" "Failed to apply threshold - fslmaths operation failed"
        # Create empty mask as fallback
        fslmaths "$zscore_image" -mas "$region_mask" -mul 0 "$output_mask"
    fi
    
    # Verify output file was created
    if [ ! -f "$output_mask" ]; then
        log_formatted "ERROR" "Output mask not created: $output_mask"
        return 1
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Validate result
    local detected_volume=$(fslstats "$output_mask" -V | awk '{print $2}')
    log_message "✓ GMM thresholding detected ${detected_volume} mm³ of hyperintensities"
    
    return 0
}

# Function to apply connectivity weighting for refined detection
apply_connectivity_weighting() {
    local initial_mask="$1"
    local zscore_image="$2"
    local output_weighted="$3"
    
    log_message "Applying connectivity weighting for refined hyperintensity detection..."
    
    # Check if initial mask has any voxels
    local initial_vol=$(fslstats "$initial_mask" -V | awk '{print $1}')
    if [ "$initial_vol" = "0" ]; then
        log_message "No initial hyperintensities found, creating empty output"
        fslmaths "$initial_mask" "$output_weighted"
        return 0
    fi
    
    local temp_dir=$(mktemp -d)
    
    # Create connectivity map using 3D morphological operations
    # Dilate initial mask to create neighborhood
    fslmaths "$initial_mask" -dilF "${temp_dir}/dilated.nii.gz"
    
    # Create connectivity weight map based on distance to hyperintense regions
    fslmaths "$initial_mask" -s 1.5 "${temp_dir}/smoothed_mask.nii.gz"
    
    # Weight z-scores by connectivity (higher weight for connected regions)
    fslmaths "$zscore_image" -mul "${temp_dir}/smoothed_mask.nii.gz" "${temp_dir}/weighted_zscore.nii.gz"
    
    # Apply refined threshold based on weighted z-scores
    # Use region-specific statistical threshold for connectivity weighting
    local region_stats=$(fslstats "$zscore_image" -k "$initial_mask" -M -S)
    local region_mean=$(echo "$region_stats" | awk '{print $1}')
    local region_std=$(echo "$region_stats" | awk '{print $2}')
    
    # Calculate adaptive thresholds
    local base_threshold=$(echo "$region_mean + 2.0 * $region_std" | bc -l)
    local connected_threshold=$(echo "$region_mean + 1.5 * $region_std" | bc -l)
    
    # Validate thresholds are valid numbers
    if ! echo "$base_threshold" | grep -E '^-?[0-9]+\.?[0-9]*$' >/dev/null; then
        base_threshold="2.0"
    fi
    if ! echo "$connected_threshold" | grep -E '^-?[0-9]+\.?[0-9]*$' >/dev/null; then
        connected_threshold="1.5"
    fi
    
    log_message "Using connectivity-weighted threshold: $connected_threshold (base: $base_threshold)"
    
    # Create final mask: high connectivity OR very high intensity
    if ! fslmaths "${temp_dir}/weighted_zscore.nii.gz" -thr "$connected_threshold" -bin "${temp_dir}/connected.nii.gz"; then
        log_formatted "WARNING" "Connected threshold failed, using original mask"
        cp "$initial_mask" "$output_weighted"
        rm -rf "$temp_dir"
        return 0
    fi
    
    if ! fslmaths "$zscore_image" -thr "$base_threshold" -bin "${temp_dir}/very_high.nii.gz"; then
        log_formatted "WARNING" "High intensity threshold failed, using connected only"
        cp "${temp_dir}/connected.nii.gz" "$output_weighted"
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Combine connected and very high intensity regions
    if ! fslmaths "${temp_dir}/connected.nii.gz" -add "${temp_dir}/very_high.nii.gz" -bin "$output_weighted"; then
        log_formatted "WARNING" "Failed to combine masks, using original"
        cp "$initial_mask" "$output_weighted"
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Apply final morphological cleanup
    fslmaths "$output_weighted" -kernel boxv 3 -ero -dilF "$output_weighted"
    
    rm -rf "$temp_dir"
    
    # Report results
    local weighted_vol=$(fslstats "$output_weighted" -V | awk '{print $2}')
    local original_vol=$(fslstats "$initial_mask" -V | awk '{print $2}')
    local refinement_ratio=$(echo "scale=2; $weighted_vol / $original_vol" | bc -l 2>/dev/null || echo "1.0")
    
    log_message "✓ Connectivity weighting: ${original_vol} → ${weighted_vol} mm³ (ratio: $refinement_ratio)"
    
    return 0
}

# Function to compute regional WM statistics to address inhomogeneity
compute_regional_wm_statistics() {
    local flair_brain="$1"
    local wm_mask="$2"
    local output_file="$3"
    
    log_message "Computing regional WM statistics for adaptive thresholding..."
    
    if [ ! -f "$flair_brain" ] || [ ! -f "$wm_mask" ]; then
        log_formatted "ERROR" "Missing input files for regional WM statistics"
        return 1
    fi
    
    # Get image dimensions
    local dims=($(fslinfo "$flair_brain" | grep ^dim | awk '{print $2}'))
    local z_dim=${dims[2]}
    
    # Create output file with header
    {
        echo "# Regional WM Statistics"
        echo "# Generated: $(date)"
        echo "# Slice\tMean\tStdDev\tVoxelCount\tMedian\tRobustRange"
    } > "$output_file"
    
    # Process each axial slice
    local temp_dir=$(mktemp -d)
    for ((slice=0; slice<z_dim; slice++)); do
        # Extract slice from FLAIR and WM mask
        local flair_slice="${temp_dir}/flair_slice_${slice}.nii.gz"
        local wm_slice="${temp_dir}/wm_slice_${slice}.nii.gz"
        
        fslroi "$flair_brain" "$flair_slice" 0 -1 0 -1 $slice 1
        fslroi "$wm_mask" "$wm_slice" 0 -1 0 -1 $slice 1
        
        # Get statistics for this slice
        local slice_stats=$(fslstats "$flair_slice" -k "$wm_slice" -M -S -V)
        if [ -n "$slice_stats" ]; then
            local slice_mean=$(echo "$slice_stats" | awk '{print $1}')
            local slice_std=$(echo "$slice_stats" | awk '{print $2}')
            local slice_nvoxels=$(echo "$slice_stats" | awk '{print $3}')
            
            # Get median and robust range (2nd-98th percentile)
            local slice_median=$(fslstats "$flair_slice" -k "$wm_slice" -P 50)
            local slice_p2=$(fslstats "$flair_slice" -k "$wm_slice" -P 2)
            local slice_p98=$(fslstats "$flair_slice" -k "$wm_slice" -P 98)
            local robust_range=$(echo "$slice_p98 - $slice_p2" | bc -l)
            
            # Only include slices with sufficient WM voxels
            if [ "${slice_nvoxels%.*}" -gt 10 ]; then
                echo -e "${slice}\t${slice_mean}\t${slice_std}\t${slice_nvoxels}\t${slice_median}\t${robust_range}" >> "$output_file"
            fi
        fi
    done
    
    rm -rf "$temp_dir"
    
    local num_slices=$(tail -n +5 "$output_file" | wc -l)
    log_message "✓ Computed regional statistics for $num_slices slices"
    
    return 0
}

# Function to create regional threshold map
create_regional_threshold_map() {
    local flair_brain="$1"
    local wm_mask="$2"
    local stats_file="$3"
    local multiplier="$4"
    local output_map="$5"
    
    log_message "Creating regional threshold map with multiplier: $multiplier"
    
    if [ ! -f "$stats_file" ]; then
        log_formatted "ERROR" "Regional statistics file not found: $stats_file"
        return 1
    fi
    
    # Get image dimensions
    local dims=($(fslinfo "$flair_brain" | grep ^dim | awk '{print $2}'))
    local z_dim=${dims[2]}
    
    # Create initial threshold map (copy of FLAIR brain structure)
    fslmaths "$flair_brain" -mul 0 "$output_map"
    
    local temp_dir=$(mktemp -d)
    
    # Process each slice with regional threshold
    while IFS=$'\t' read -r slice mean std nvoxels median robust_range; do
        # Skip header lines
        if [[ "$slice" =~ ^[0-9]+$ ]]; then
            # Calculate regional threshold for this slice
            local regional_threshold=$(echo "$mean + $multiplier * $std" | bc -l)
            
            # Create slice-specific threshold map
            local slice_map="${temp_dir}/thresh_slice_${slice}.nii.gz"
            fslmaths "$flair_brain" -roi 0 -1 0 -1 $slice 1 -mul 0 -add "$regional_threshold" "$slice_map"
            
            # Add this slice to the output map
            if [ $slice -eq 0 ]; then
                cp "$slice_map" "$output_map"
            else
                # Concatenate along z-axis
                local temp_map="${temp_dir}/temp_concat.nii.gz"
                fslmerge -z "$temp_map" "$output_map" "$slice_map"
                mv "$temp_map" "$output_map"
            fi
        fi
    done < <(tail -n +5 "$stats_file")
    
    rm -rf "$temp_dir"
    
    log_message "✓ Created regional adaptive threshold map"
    return 0
}

# Function to apply regional threshold
apply_regional_threshold() {
    local flair_brain="$1"
    local threshold_map="$2"
    local brain_mask="$3"
    local output_mask="$4"
    
    log_message "Applying regional adaptive threshold..."
    
    # Create binary mask where FLAIR > regional threshold
    fslmaths "$flair_brain" -sub "$threshold_map" -thr 0 -bin "$output_mask"
    
    # Apply brain mask
    if [ -f "$brain_mask" ]; then
        fslmaths "$output_mask" -mas "$brain_mask" "$output_mask"
    fi
    
    log_message "✓ Applied regional adaptive threshold"
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

# Function to quantify volumes with enhanced per-threshold cluster analysis
quantify_volumes() {
    local prefix="$1"
    local output_file="${prefix}_volumes.csv"
    
    log_message "Quantifying volumes for $prefix with per-threshold cluster analysis"
    
    # Create enhanced CSV header
    echo "Threshold,Volume (mm³),Volume (voxels),NumClusters,LargestCluster (mm³),MeanClusterSize (mm³),RegionalMethod" > "$output_file"
    
    # Get threshold values from available files
    local available_thresholds=()
    for thresh_file in "${prefix}_thresh"*"_bin.nii.gz"; do
        if [ -f "$thresh_file" ]; then
            # Extract threshold value from filename
            local thresh=$(basename "$thresh_file" | sed -n 's/.*_thresh\([0-9.]*\)_bin\.nii\.gz/\1/p')
            if [ -n "$thresh" ]; then
                available_thresholds+=("$thresh")
            fi
        fi
    done
    
    # Sort thresholds numerically
    IFS=$'\n' available_thresholds=($(sort -n <<<"${available_thresholds[*]}"))
    unset IFS
    
    log_message "Found ${#available_thresholds[@]} threshold variants: ${available_thresholds[*]}"
    
    # Process each available threshold
    for mult in "${available_thresholds[@]}"; do
        local mask_file="${prefix}_thresh${mult}_bin.nii.gz"
        local cluster_file="${prefix}_clusters_${mult}.txt"
        local cluster_sorted="${prefix}_clusters_${mult}_sorted.txt"
        
        if [ ! -f "$mask_file" ]; then
            log_formatted "WARNING" "Mask file not found: $mask_file"
            continue
        fi
        
        # Get total volume in both mm³ and voxels
        local volume_stats=$(fslstats "$mask_file" -V)
        local total_volume_voxels=$(echo "$volume_stats" | awk '{print $1}')
        local total_volume_mm3=$(echo "$volume_stats" | awk '{print $2}')
        
        # Get cluster statistics for this specific threshold
        local num_clusters=0
        local largest_cluster=0
        local mean_cluster_size=0
        
        if [ -f "$cluster_file" ]; then
            # Count clusters (subtract header line)
            num_clusters=$(tail -n +2 "$cluster_file" | wc -l)
            
            # Create sorted version if it doesn't exist
            if [ ! -f "$cluster_sorted" ]; then
                tail -n +2 "$cluster_file" | sort -k2,2nr > "$cluster_sorted"
            fi
            
            if [ -f "$cluster_sorted" ] && [ -s "$cluster_sorted" ]; then
                # Get largest cluster size
                largest_cluster=$(head -1 "$cluster_sorted" | awk '{print $2}')
                
                # Calculate mean cluster size with division by zero protection
                mean_cluster_size=$(awk '{sum+=$2; count+=1} END {if(count>0) print sum/count; else print 0}' "$cluster_sorted")
            else
                # No clusters found - set safe defaults
                largest_cluster=0
                mean_cluster_size=0
            fi
        else
            # No cluster file - set safe defaults
            num_clusters=0
            largest_cluster=0
            mean_cluster_size=0
        else
            log_message "No cluster analysis file found for threshold $mult, computing basic stats"
        fi
        
        # Determine if regional method was used (check for regional stats file)
        local regional_method="No"
        if [ -f "${prefix}_regional_wm_stats.txt" ]; then
            regional_method="Yes"
        fi
        
        # Add to CSV with enhanced information
        echo "${mult},${total_volume_mm3},${total_volume_voxels},${num_clusters},${largest_cluster},${mean_cluster_size},${regional_method}" >> "$output_file"
        
        log_message "✓ Threshold ${mult}: ${total_volume_mm3} mm³, ${num_clusters} clusters"
    done
    
    # Create summary report
    local summary_file="${prefix}_volume_summary.txt"
    {
        echo "Volume Quantification Summary"
        echo "============================"
        echo "Generated: $(date)"
        echo "Prefix: $prefix"
        echo ""
        echo "Available thresholds: ${#available_thresholds[@]}"
        echo "Regional adaptive method: $([ -f "${prefix}_regional_wm_stats.txt" ] && echo "Yes" || echo "No")"
        echo ""
        echo "Detailed results in: $(basename "$output_file")"
        echo ""
        
        if [ -f "$output_file" ]; then
            echo "Summary by threshold:"
            echo "--------------------"
            while IFS=, read -r thresh vol_mm3 vol_vox nclusters largest mean_size regional; do
                if [[ "$thresh" != "Threshold" ]]; then  # Skip header
                    printf "  %.1f SD: %8.1f mm³ (%3d clusters, largest: %6.1f mm³)\n" \
                           "$thresh" "$vol_mm3" "$nclusters" "$largest"
                fi
            done < "$output_file"
        fi
    } > "$summary_file"
    
    log_message "Volume quantification complete. Results saved to: $output_file"
    log_message "Summary report created: $summary_file"
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
    
    # Use centralized apply_transformation function for consistent SyN transform handling
    log_message "Using centralized apply_transformation function..."
    
    # Extract transform prefix from transform file path
    local transform_prefix="${transform_file%0GenericAffine.mat}"
    if apply_transformation "$segmentation_file" "$reference_file" "$output_file" "$transform_prefix" "NearestNeighbor"; then
        log_message "✓ Successfully applied transform using centralized function"
    else
        log_formatted "ERROR" "Failed to apply transform using centralized function"
        return 1
    fi
    
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

# Helper function to analyze a specific region and modality
analyze_region_modality() {
    local region="$1"
    local region_mask="$2"
    local image_file="$3"
    local modality="$4"        # "FLAIR" or "T1"
    local intensity_type="$5"  # "hyper" or "hypo"
    local base_hyper_dir="$6"
    
    # Create modality-specific output directory
    local region_output_dir="${base_hyper_dir}/${region}_${modality}"
    mkdir -p "$region_output_dir"
    
    # Create masked image for this region
    local region_image="${region_output_dir}/${region}_${modality}.nii.gz"
    if ! fslmaths "$image_file" -mas "$region_mask" "$region_image"; then
        log_formatted "WARNING" "Failed to create masked ${modality} for $region"
        return 1
    fi
    
    # Get region statistics for adaptive thresholding
    local region_stats=$(fslstats "$region_image" -k "$region_mask" -M -S)
    local region_mean=$(echo "$region_stats" | awk '{print $1}')
    local region_std=$(echo "$region_stats" | awk '{print $2}')
    
    if [ "$region_mean" = "0.000000" ] || [ -z "$region_std" ]; then
        log_message "Skipping ${modality} ${intensity_type}intensities in $region - no signal detected"
        return 1
    fi
    
    log_message "$region ${modality} statistics - Mean: $region_mean, StdDev: $region_std"
    
    # Apply modality-specific thresholding with different multipliers for T1 vs FLAIR
    local base_threshold_multiplier="${THRESHOLD_WM_SD_MULTIPLIER:-1.25}"
    local threshold_multiplier
    local threshold_val
    local abnormality_mask="${region_output_dir}/${region}_${modality}_${intensity_type}intensities.nii.gz"
    
    # CRITICAL FIX: Use higher thresholds for T1 hypointensities than FLAIR hyperintensities
    if [ "$modality" = "T1" ]; then
        # T1 hypointensities need higher threshold (double the base threshold)
        threshold_multiplier=$(echo "$base_threshold_multiplier * 2.0" | bc -l)
        log_message "Using enhanced T1 threshold multiplier: $threshold_multiplier (2x base for hypointensities)"
    else
        # FLAIR hyperintensities use standard threshold
        threshold_multiplier="$base_threshold_multiplier"
        log_message "Using standard FLAIR threshold multiplier: $threshold_multiplier"
    fi
    
    if [ "$intensity_type" = "hyper" ]; then
        # FLAIR hyperintensities: mean + multiplier * std (above threshold)
        threshold_val=$(echo "$region_mean + $threshold_multiplier * $region_std" | bc -l)
        log_message "Using ${modality} hyperintensity threshold: $threshold_val for $region (multiplier: $threshold_multiplier)"
        
        # Create hyperintensity mask (above threshold)
        if ! fslmaths "$region_image" -thr "$threshold_val" -bin "$abnormality_mask"; then
            log_formatted "WARNING" "Failed to create ${modality} hyperintensity mask for $region"
            return 1
        fi
    else
        # T1 hypointensities: mean - multiplier * std (below threshold)
        threshold_val=$(echo "$region_mean - $threshold_multiplier * $region_std" | bc -l)
        log_message "Using ${modality} hypointensity threshold: $threshold_val for $region (multiplier: $threshold_multiplier)"
        
        # Create hypointensity mask (below threshold)
        if ! fslmaths "$region_image" -uthr "$threshold_val" -bin "$abnormality_mask"; then
            log_formatted "WARNING" "Failed to create ${modality} hypointensity mask for $region"
            return 1
        fi
    fi
    
    # Apply minimum cluster size filtering
    local min_size="${MIN_HYPERINTENSITY_SIZE:-4}"
    local filtered_mask="${region_output_dir}/${region}_${modality}_${intensity_type}intensities_filtered.nii.gz"
    
    if cluster --in="$abnormality_mask" --thresh=0.5 \
               --connectivity=26 --minextent="$min_size" \
               --oindex="$filtered_mask" > /dev/null 2>&1; then
        log_message "✓ Applied clustering filter (min size: $min_size voxels) to ${modality} $region"
    else
        log_message "Clustering failed for ${modality} $region, using unfiltered mask"
        cp "$abnormality_mask" "$filtered_mask"
    fi
    
    # Create intensity version
    local abnormality_intensity="${region_output_dir}/${region}_${modality}_${intensity_type}intensities_intensity.nii.gz"
    fslmaths "$region_image" -mas "$filtered_mask" "$abnormality_intensity"
    
    # Create RGB overlay for visualization
    local overlay="${region_output_dir}/overlay.nii.gz"
    log_message "Creating ${modality} RGB overlay for $region..."
    
    # Check dimensions match
    local image_dims=$(fslinfo "$region_image" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    local mask_dims=$(fslinfo "$filtered_mask" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
    
    if [ "$image_dims" = "$mask_dims" ]; then
        # Create RGB channels
        local temp_dir=$(mktemp -d)
        
        # Red channel - background image
        local max_val=$(fslstats "$region_image" -k "$region_mask" -R | awk '{print $2}')
        if [ "$max_val" != "0.000000" ] && [ -n "$max_val" ]; then
            fslmaths "$region_image" -div "$max_val" "${temp_dir}/r.nii.gz"
        else
            fslmaths "$region_image" -mul 0 "${temp_dir}/r.nii.gz"
        fi
        
        # Green channel - abnormalities (hyperintensities green, hypointensities blue)
        if [ "$intensity_type" = "hyper" ]; then
            fslmaths "$filtered_mask" -mul 0.8 "${temp_dir}/g.nii.gz"
            fslmaths "$filtered_mask" -mul 0 "${temp_dir}/b.nii.gz"
        else
            fslmaths "$filtered_mask" -mul 0 "${temp_dir}/g.nii.gz"
            fslmaths "$filtered_mask" -mul 0.8 "${temp_dir}/b.nii.gz"
        fi
        
        # Blue channel - mask outline (or hypointensities)
        if [ "$intensity_type" = "hyper" ]; then
            fslmaths "$region_mask" -edge -bin -mul 0.3 "${temp_dir}/b.nii.gz"
        fi
        
        # Merge RGB channels
        if fslmerge -t "$overlay" "${temp_dir}/r.nii.gz" "${temp_dir}/g.nii.gz" "${temp_dir}/b.nii.gz"; then
            log_message "✓ Created ${modality} RGB overlay for $region"
        else
            log_formatted "WARNING" "Failed to create ${modality} RGB overlay for $region"
            # Create fallback overlay
            fslmaths "$region_image" -add "$filtered_mask" "$overlay"
        fi
        
        rm -rf "$temp_dir"
    else
        log_formatted "WARNING" "Dimension mismatch for ${modality} $region overlay - creating fallback"
        fslmaths "$region_image" -add "$filtered_mask" "$overlay"
    fi
    
    # Quantify results
    local abnormal_voxels=$(fslstats "$filtered_mask" -V | awk '{print $1}')
    local abnormal_volume=$(fslstats "$filtered_mask" -V | awk '{print $2}')
    local region_voxels=$(fslstats "$region_mask" -V | awk '{print $1}')
    local region_volume=$(fslstats "$region_mask" -V | awk '{print $2}')
    
    local percentage="0"
    if [ "$region_voxels" -gt 0 ]; then
        percentage=$(echo "scale=2; $abnormal_voxels * 100 / $region_voxels" | bc)
    fi
    
    log_message "✓ $region ${modality} ${intensity_type}intensities results:"
    log_message "   Abnormal voxels: $abnormal_voxels ($abnormal_volume mm³)"
    log_message "   Region coverage: ${percentage}%"
    
    # Create region summary
    {
        echo "Talairach Region ${modality} ${intensity_type^}intensity Analysis"
        echo "=============================================="
        echo "Region: $region"
        echo "Modality: $modality"
        echo "Analysis type: ${intensity_type}intensities"
        echo "Date: $(date)"
        echo ""
        echo "Input files:"
        echo "  Image: $(basename "$image_file")"
        echo "  Mask: $(basename "$region_mask")"
        echo ""
        echo "Analysis parameters:"
        echo "  Threshold multiplier: $threshold_multiplier"
        echo "  Threshold value: $threshold_val"
        echo "  Threshold direction: $([ "$intensity_type" = "hyper" ] && echo "above (>)" || echo "below (<)")"
        echo "  Minimum cluster size: $min_size voxels"
        echo ""
        echo "Results:"
        echo "  Region volume: $region_volume mm³ ($region_voxels voxels)"
        echo "  Abnormal volume: $abnormal_volume mm³ ($abnormal_voxels voxels)"
        echo "  Percentage affected: ${percentage}%"
        echo ""
        echo "Output files:"
        echo "  Abnormality mask: $(basename "$filtered_mask")"
        echo "  Abnormality intensity: $(basename "$abnormality_intensity")"
        echo "  RGB overlay: $(basename "$overlay")"
    } > "${region_output_dir}/${region}_${modality}_${intensity_type}intensity_report.txt"
    
    log_message "✓ Created ${modality} analysis report: ${region_output_dir}/${region}_${modality}_${intensity_type}intensity_report.txt"
    
    return 0
}

# Function to analyze intensity abnormalities in Talairach brainstem regions (both FLAIR and T1)
analyze_talairach_hyperintensities() {
    local flair_file="$1"
    local analysis_dir="$2"
    local output_basename="$3"
    local t1_file="${4:-}"  # Optional T1 file
    
    log_formatted "INFO" "===== TALAIRACH INTENSITY ABNORMALITY ANALYSIS ====="
    log_message "FLAIR input: $flair_file"
    log_message "T1 input: ${t1_file:-none provided}"
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
    
    # Try to find T1 file if not provided
    if [ -z "$t1_file" ] || [ ! -f "$t1_file" ]; then
        log_message "Searching for T1 file..."
        local t1_candidates=(
            "${RESULTS_DIR}/standardized/"*"T1"*"_std.nii.gz"
            "${RESULTS_DIR}/bias_corrected/"*"T1"*".nii.gz"
            "${RESULTS_DIR}/preprocessing/"*"T1"*".nii.gz"
        )
        
        for candidate in "${t1_candidates[@]}"; do
            if [ -f "$candidate" ]; then
                t1_file="$candidate"
                log_message "Found T1 file: $t1_file"
                break
            fi
        done
        
        if [ ! -f "$t1_file" ]; then
            log_formatted "WARNING" "No T1 file found - will only analyze FLAIR hyperintensities"
            t1_file=""
        fi
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
    
    log_message "Analyzing intensity abnormalities in Talairach brainstem regions..."
    log_message "Will analyze: FLAIR (hyperintensities) and T1 (hypointensities)"
    
    # Process each Talairach region for both modalities
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
        
        log_message "Processing intensity abnormalities in $region..."
        log_message "Using mask: $(basename "$region_mask")"
        
        # Process FLAIR hyperintensities
        analyze_region_modality "$region" "$region_mask" "$flair_file" "FLAIR" "hyper" "$hyper_dir"
        
        # Process T1 hypointensities if T1 available
        if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
            analyze_region_modality "$region" "$region_mask" "$t1_file" "T1" "hypo" "$hyper_dir"
        fi
    done
    
    # Create combined summary across all Talairach regions
    log_message "Creating combined Talairach intensity abnormality summary..."
    
    local combined_report="${hyper_dir}/talairach_intensity_abnormality_summary.txt"
    {
        echo "Talairach Brainstem Intensity Abnormality Analysis Summary"
        echo "========================================================="
        echo "Date: $(date)"
        echo "FLAIR input: $(basename "$flair_file")"
        if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
            echo "T1 input: $(basename "$t1_file")"
        else
            echo "T1 input: Not available"
        fi
        echo ""
        echo "FLAIR HYPERINTENSITIES (lesions appear bright)"
        echo "=============================================="
        echo "Region | Volume (mm³) | Hyperintensities (mm³) | % Affected"
        echo "-------|--------------|-------------------------|----------"
        
        for region in "${talairach_regions[@]}"; do
            local flair_report="${hyper_dir}/${region}_FLAIR/${region}_FLAIR_hyperintensity_report.txt"
            if [ -f "$flair_report" ]; then
                local region_vol=$(grep "Region volume:" "$flair_report" | awk '{print $3}')
                local abnormal_vol=$(grep "Abnormal volume:" "$flair_report" | awk '{print $3}')
                local percentage=$(grep "Percentage affected:" "$flair_report" | awk '{print $3}')
                printf "%-6s | %12s | %23s | %8s\n" "$region" "$region_vol" "$abnormal_vol" "$percentage"
            else
                printf "%-6s | %12s | %23s | %8s\n" "$region" "N/A" "N/A" "N/A"
            fi
        done
        
        if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
            echo ""
            echo "T1 HYPOINTENSITIES (lesions appear dark)"
            echo "========================================"
            echo "Region | Volume (mm³) | Hypointensities (mm³) | % Affected"
            echo "-------|--------------|------------------------|----------"
            
            for region in "${talairach_regions[@]}"; do
                local t1_report="${hyper_dir}/${region}_T1/${region}_T1_hypointensity_report.txt"
                if [ -f "$t1_report" ]; then
                    local region_vol=$(grep "Region volume:" "$t1_report" | awk '{print $3}')
                    local abnormal_vol=$(grep "Abnormal volume:" "$t1_report" | awk '{print $3}')
                    local percentage=$(grep "Percentage affected:" "$t1_report" | awk '{print $3}')
                    printf "%-6s | %12s | %22s | %8s\n" "$region" "$region_vol" "$abnormal_vol" "$percentage"
                else
                    printf "%-6s | %12s | %22s | %8s\n" "$region" "N/A" "N/A" "N/A"
                fi
            done
        fi
        
        echo ""
        echo "Analysis Parameters:"
        echo "  Threshold multiplier: ${THRESHOLD_WM_SD_MULTIPLIER:-1.25}"
        echo "  Minimum cluster size: ${MIN_HYPERINTENSITY_SIZE:-4} voxels"
        echo "  FLAIR thresholding: mean + multiplier × std (above threshold)"
        echo "  T1 thresholding: mean - multiplier × std (below threshold)"
        
    } > "$combined_report"
    
    log_formatted "SUCCESS" "Talairach hyperintensity analysis complete"
    log_message "Combined summary: $combined_report"
    log_message "Individual reports in: $hyper_dir"
    
    return 0
}

# Function to run comprehensive analysis (wrapper for analyze_talairach_hyperintensities)
run_comprehensive_analysis() {
    local orig_t1="$1"
    local orig_flair="$2"
    local t1_std="$3"
    local flair_std="$4"
    local segmentation_dir="$5"
    local comprehensive_dir="$6"
    
    log_formatted "INFO" "===== RUNNING COMPREHENSIVE ANALYSIS ====="
    log_message "Original T1: $orig_t1"
    log_message "Original FLAIR: $orig_flair"
    log_message "Standardized T1: $t1_std"
    log_message "Standardized FLAIR: $flair_std"
    log_message "Segmentation directory: $segmentation_dir"
    log_message "Output directory: $comprehensive_dir"
    
    # Validate inputs
    if [ ! -f "$orig_flair" ]; then
        log_formatted "ERROR" "Original FLAIR file not found: $orig_flair"
        return 1
    fi
    
    if [ ! -d "$segmentation_dir" ]; then
        log_formatted "ERROR" "Segmentation directory not found: $segmentation_dir"
        return 1
    fi
    
    # Create comprehensive analysis output directory
    mkdir -p "$comprehensive_dir"
    
    # Find Talairach analysis directory with masks
    local analysis_dir=""
    local output_basename=""
    
    # Look for Talairach masks in multiple possible locations
    local possible_dirs=(
        "${comprehensive_dir}/original_space"
        "${segmentation_dir}/detailed_brainstem"
        "${segmentation_dir}/../comprehensive_analysis/original_space"
    )
    
    # Create the original_space directory if it doesn't exist
    mkdir -p "${comprehensive_dir}/original_space"
    
    for dir in "${possible_dirs[@]}"; do
        if [ -d "$dir" ]; then
            # Look for Talairach region files to determine the correct basename
            local sample_files=($(find "$dir" -name "*_left_medulla*.nii.gz" -o -name "*_left_pons*.nii.gz" 2>/dev/null | head -2))
            
            if [ ${#sample_files[@]} -gt 0 ]; then
                analysis_dir="$dir"
                # Extract basename from first file (remove region suffix)
                local sample_file=$(basename "${sample_files[0]}" .nii.gz)
                output_basename=$(echo "$sample_file" | sed -E 's/_(left|right)_(medulla|pons|midbrain).*$//')
                log_message "Found Talairach masks in: $analysis_dir"
                log_message "Using output basename: $output_basename"
                break
            fi
        fi
    done
    
    # If no existing Talairach masks found, use original_space and derive basename from input
    if [ -z "$analysis_dir" ]; then
        analysis_dir="${comprehensive_dir}/original_space"
        # Derive basename from FLAIR file (common approach)
        local flair_basename=$(basename "$orig_flair" .nii.gz)
        # Remove common suffixes to get clean basename
        output_basename=$(echo "$flair_basename" | sed -E 's/_(brain|std|n4|FLAIR|flair).*$//' | sed -E 's/_[0-9]+$//')
        
        log_message "No existing Talairach masks found"
        log_message "Will use analysis directory: $analysis_dir"
        log_message "Will use output basename: $output_basename"
        
        # Check if we have any segmentation data to work with
        local seg_files=($(find "$segmentation_dir" -name "*.nii.gz" 2>/dev/null))
        if [ ${#seg_files[@]} -eq 0 ]; then
            log_formatted "ERROR" "No segmentation files found in $segmentation_dir"
            return 1
        fi
        
        log_message "Found ${#seg_files[@]} segmentation files to analyze"
    fi
    
    # Determine which FLAIR and T1 files to use for analysis
    # For hyperintensity detection, original space is often preferred for native resolution
    local analysis_flair="$orig_flair"
    local analysis_t1="$orig_t1"
    
    # Check if we should use standardized versions based on mask location
    if [[ "$analysis_dir" == *"standardized"* ]] || [[ "$analysis_dir" == *"std"* ]]; then
        log_message "Analysis directory suggests standardized space, using standardized images"
        analysis_flair="$flair_std"
        analysis_t1="$t1_std"
    fi
    
    log_message "Using FLAIR for analysis: $analysis_flair"
    log_message "Using T1 for analysis: $analysis_t1"
    
    # Call the main Talairach hyperintensity analysis function
    log_message "Running Talairach hyperintensity analysis..."
    if analyze_talairach_hyperintensities "$analysis_flair" "$analysis_dir" "$output_basename" "$analysis_t1"; then
        log_formatted "SUCCESS" "Comprehensive analysis completed successfully"
        
        # Create summary of results
        local summary_file="${comprehensive_dir}/comprehensive_analysis_summary.txt"
        {
            echo "Comprehensive Analysis Summary"
            echo "============================="
            echo "Date: $(date)"
            echo "Analysis directory: $analysis_dir"
            echo "Output basename: $output_basename"
            echo "FLAIR input: $(basename "$analysis_flair")"
            echo "T1 input: $(basename "$analysis_t1")"
            echo ""
            echo "Analysis completed successfully."
            echo "Results available in: ${comprehensive_dir}/hyperintensities/"
            echo "Detailed reports in individual region subdirectories."
        } > "$summary_file"
        
        # Create comprehensive FLAIR visualizations for all segmentations
        log_message "Creating comprehensive FLAIR segmentation visualizations..."
        create_comprehensive_flair_visualizations "$analysis_flair" "$analysis_dir" "${comprehensive_dir}/visualizations" "comprehensive_flair"
        
        log_message "Summary report created: $summary_file"
        return 0
    else
        log_formatted "ERROR" "Talairach hyperintensity analysis failed"
        return 1
    fi
}

# Function to create comprehensive 3D visualization script using both fsleyes and freeview
create_3d_visualization_script() {
    local reference_image="$1"    # Background image (T1 or FLAIR)
    local output_dir="$2"         # Directory to save the script
    local script_name="${3:-view_3d_comprehensive.sh}"  # Name of the script to create
    local title="${4:-3D Visualization}"  # Title for the visualization
    
    log_message "Creating 3D visualization script: $script_name"
    
    # Validate inputs
    if [ ! -f "$reference_image" ]; then
        log_formatted "ERROR" "Reference image not found: $reference_image"
        return 1
    fi
    
    if [ ! -d "$output_dir" ]; then
        log_formatted "ERROR" "Output directory not found: $output_dir"
        return 1
    fi
    
    local script_path="${output_dir}/${script_name}"
    
    # First, try to create the FreeSurfer-based view_3d.sh script if FreeSurfer is available
    log_message "Checking for FreeSurfer availability..."
    if command -v mris_convert &> /dev/null && command -v freeview &> /dev/null; then
        log_message "FreeSurfer detected - creating FreeSurfer-based view_3d.sh"
        
        # Look for hyperintensity and region masks to create surface meshes
        local freesurfer_script="${output_dir}/view_3d.sh"
        local created_surfaces=false
        
        # Look for hyperintensity masks
        local hyper_files=($(find "$output_dir" -name "*hyperintensities*.nii.gz" -o -name "*hypointensities*.nii.gz" | head -2))
        local region_files=($(find "$output_dir" -name "*pons*.nii.gz" -o -name "*medulla*.nii.gz" -o -name "*midbrain*.nii.gz" | head -3))
        
        if [ ${#hyper_files[@]} -gt 0 ] || [ ${#region_files[@]} -gt 0 ]; then
            cat > "$freesurfer_script" << 'EOF'
#!/usr/bin/env bash
#
# FreeSurfer 3D Visualization Script
# Generated automatically for surface mesh rendering
#

echo "Starting FreeSurfer 3D visualization..."
echo "Creating surface meshes and launching freeview..."

# Check if FreeSurfer is available
if ! command -v freeview &> /dev/null; then
    echo "ERROR: freeview (FreeSurfer) not found."
    echo "Falling back to FSLeyes if available..."
    if [ -f "./view_3d_comprehensive.sh" ]; then
        ./view_3d_comprehensive.sh
    else
        echo "No alternative visualization available."
    fi
    exit 1
fi

FREEVIEW_CMD="freeview"
EOF

            # Add the reference image
            echo "FREEVIEW_CMD=\"\$FREEVIEW_CMD -v '$reference_image'\"" >> "$freesurfer_script"
            
            # Process hyperintensity/hypointensity files
            for hyper_file in "${hyper_files[@]}"; do
                if [ -f "$hyper_file" ]; then
                    local mesh_file="${hyper_file%.nii.gz}.stl"
                    local bin_file="${hyper_file%.nii.gz}_bin.nii.gz"
                    
                    # Create binary mask and surface mesh
                    cat >> "$freesurfer_script" << EOF

# Create surface mesh for $(basename "$hyper_file")
echo "Creating surface mesh for $(basename "$hyper_file")..."
fslmaths "$hyper_file" -bin "$bin_file"
if mri_tessellate "$bin_file" 1 "$mesh_file" 2>/dev/null; then
    FREEVIEW_CMD="\$FREEVIEW_CMD -f $mesh_file:edgecolor=red:color=red:opacity=0.8"
    echo "Added hyperintensity surface mesh"
fi
EOF
                    created_surfaces=true
                fi
            done
            
            # Process region files
            for region_file in "${region_files[@]}"; do
                if [ -f "$region_file" ]; then
                    local mesh_file="${region_file%.nii.gz}.stl"
                    local bin_file="${region_file%.nii.gz}_bin.nii.gz"
                    local color="blue"
                    
                    # Choose color based on region
                    if [[ "$region_file" == *"medulla"* ]]; then
                        color="red"
                    elif [[ "$region_file" == *"pons"* ]]; then
                        color="blue"
                    elif [[ "$region_file" == *"midbrain"* ]]; then
                        color="green"
                    fi
                    
                    cat >> "$freesurfer_script" << EOF

# Create surface mesh for $(basename "$region_file")
echo "Creating surface mesh for $(basename "$region_file")..."
fslmaths "$region_file" -bin "$bin_file"
if mri_tessellate "$bin_file" 1 "$mesh_file" 2>/dev/null; then
    FREEVIEW_CMD="\$FREEVIEW_CMD -f $mesh_file:edgecolor=$color:color=$color:opacity=0.4"
    echo "Added region surface mesh: $(basename "$region_file")"
fi
EOF
                    created_surfaces=true
                fi
            done
            
            # Complete the FreeSurfer script
            cat >> "$freesurfer_script" << 'EOF'

# Launch freeview
echo ""
echo "Launching freeview with surface meshes..."
echo "Command: $FREEVIEW_CMD"
echo ""
echo "FreeSurfer Controls:"
echo "  - Mouse: Rotate, pan, zoom"
echo "  - Right-click: Context menu"
echo "  - View menu: Change rendering options"
echo "  - Surface menu: Adjust surface properties"
echo ""

eval "$FREEVIEW_CMD"
EOF
            
            chmod +x "$freesurfer_script"
            log_message "✓ Created FreeSurfer view_3d.sh script"
        else
            log_message "No suitable files found for FreeSurfer surface rendering"
        fi
    else
        log_message "FreeSurfer not available - skipping FreeSurfer-based view_3d.sh"
    fi
    
    # Now create the comprehensive FSLeyes-based script
    log_message "Creating FSLeyes-based comprehensive visualization script..."
    
    # Start building the fsleyes command
    local fsleyes_cmd="#!/usr/bin/env bash
#
# Comprehensive 3D Visualization Script (FSLeyes)
# Generated: $(date)
# Title: $title
#
# This script opens fsleyes with comprehensive overlay visualization
# of all available segmentation results and analysis outputs
#

echo \"Starting comprehensive 3D visualization: $title\"
echo \"Reference image: $(basename "$reference_image")\"
echo \"\"

# Check if fsleyes is available
if ! command -v fsleyes &> /dev/null; then
    echo \"ERROR: fsleyes not found. Please install FSL.\"
    # Try FreeSurfer fallback
    if [ -f \"./view_3d.sh\" ]; then
        echo \"Trying FreeSurfer-based visualization...\"
        ./view_3d.sh
    else
        echo \"No visualization tools available.\"
        exit 1
    fi
    exit 1
fi

# Build fsleyes command
FSLEYES_CMD=\"fsleyes\"

# Add background image
FSLEYES_CMD=\"\$FSLEYES_CMD '$reference_image'\"
echo \"Background: $(basename "$reference_image")\"
"

    # Look for various types of overlays in the output directory and subdirectories
    local overlay_count=0
    
    # Function to add overlay to command
    add_overlay() {
        local file="$1"
        local colormap="$2"
        local alpha="$3"
        local name="$4"
        
        if [ -f "$file" ]; then
            fsleyes_cmd="$fsleyes_cmd
# Add $name overlay
if [ -f \"$file\" ]; then
    FSLEYES_CMD=\"\$FSLEYES_CMD '$file' -cm $colormap -a $alpha\"
    echo \"Adding overlay: $name\"
fi
"
            ((overlay_count++))
            return 0
        fi
        return 1
    }
    
    # Look for brainstem segmentation masks
    log_message "Searching for segmentation overlays in $output_dir"
    
    # Brainstem region masks (Talairach atlas)
    local regions=("left_medulla" "right_medulla" "left_pons" "right_pons" "left_midbrain" "right_midbrain" "pons")
    for region in "${regions[@]}"; do
        # Look for region masks in various formats
        local region_files=(
            "${output_dir}/"*"${region}"*".nii.gz"
            "${output_dir}/"*"${region}"*"_flair_space.nii.gz"
            "${output_dir}/../"*"${region}"*".nii.gz"
        )
        
        for pattern in "${region_files[@]}"; do
            for file in $pattern; do
                if [ -f "$file" ]; then
                    local colormap="random"
                    case "$region" in
                        *medulla*) colormap="red" ;;
                        *pons*) colormap="blue" ;;
                        *midbrain*) colormap="green" ;;
                    esac
                    add_overlay "$file" "$colormap" "50" "$(basename "$file" .nii.gz)"
                    break 2  # Found one, move to next region
                fi
            done
        done
    done
    
    # Look for hyperintensity/hypointensity analysis results
    local hyper_dirs=(
        "${output_dir}/hyperintensities"
        "${output_dir}/../hyperintensities"
        "${output_dir}/../../comprehensive_analysis/hyperintensities"
    )
    
    for hyper_dir in "${hyper_dirs[@]}"; do
        if [ -d "$hyper_dir" ]; then
            log_message "Found hyperintensities directory: $hyper_dir"
            
            # Look for hyperintensity masks in ANY modality-specific subdirectories (dynamic detection)
            for hyper_file in "${hyper_dir}/"*"/"*"_hyperintensities_filtered.nii.gz" "${hyper_dir}/"*"/"*"_hypointensities_filtered.nii.gz"; do
                if [ -f "$hyper_file" ]; then
                    local region_dir=$(dirname "$hyper_file")
                    local modality_dir=$(dirname "$region_dir")
                    local modality=$(basename "$modality_dir")
                    local region=$(basename "$region_dir")
                    local filename=$(basename "$hyper_file")
                    
                    # Determine colormap based on filename pattern
                    if [[ "$filename" =~ hyperintensities ]]; then
                        add_overlay "$hyper_file" "hot" "70" "${modality} hyperintensities (${region})"
                    else
                        add_overlay "$hyper_file" "cool" "70" "${modality} hypointensities (${region})"
                    fi
                fi
            done
            
            # Look for RGB overlays in ANY modality-specific subdirectories (dynamic detection)
            for rgb_file in "${hyper_dir}/"*"/overlay.nii.gz"; do
                if [ -f "$rgb_file" ]; then
                    local region_dir=$(dirname "$rgb_file")
                    local modality_dir=$(dirname "$region_dir")
                    local modality=$(basename "$modality_dir")
                    local region=$(basename "$region_dir")
                    add_overlay "$rgb_file" "rgb" "60" "RGB overlay (${region} ${modality})"
                fi
            done
            break
        fi
    done
    
    # Look for tissue segmentation masks
    local seg_patterns=(
        "${output_dir}/"*"_seg.nii.gz"
        "${output_dir}/"*"_fast_seg.nii.gz"
        "${output_dir}/../"*"_seg.nii.gz"
    )
    
    for pattern in "${seg_patterns[@]}"; do
        for seg_file in $pattern; do
            if [ -f "$seg_file" ]; then
                add_overlay "$seg_file" "subcortical" "40" "Tissue segmentation"
                break 2
            fi
        done
    done
    
    # Look for cluster analysis results
    local cluster_patterns=(
        "${output_dir}/"*"_clusters.nii.gz"
        "${output_dir}/../"*"_clusters.nii.gz"
    )
    
    for pattern in "${cluster_patterns[@]}"; do
        for cluster_file in $pattern; do
            if [ -f "$cluster_file" ]; then
                add_overlay "$cluster_file" "random" "60" "Cluster analysis"
                break 2
            fi
        done
    done
    
    # Complete the script
    fsleyes_cmd="$fsleyes_cmd
# Launch fsleyes
echo \"\"
echo \"Launching fsleyes with \$overlay_count overlays...\"
echo \"Command: \$FSLEYES_CMD\"
echo \"\"
echo \"Controls:\"
echo \"  - Use mouse to navigate\"
echo \"  - Right-click overlays to adjust properties\"
echo \"  - Toggle overlays with checkboxes\"
echo \"  - Use 3D view for volume rendering\"
echo \"\"

# Execute the command
eval \"\$FSLEYES_CMD\"
"

    # Write the script
    echo "$fsleyes_cmd" > "$script_path"
    chmod +x "$script_path"
    
    # Create a simple launcher script as well
    local launcher="${output_dir}/launch_visualization.sh"
    cat > "$launcher" << EOF
#!/usr/bin/env bash
#
# Simple launcher for 3D visualization
#
cd "\$(dirname "\$0")"
if [ -f "$script_name" ]; then
    ./$script_name
else
    echo "ERROR: $script_name not found"
    exit 1
fi
EOF
    chmod +x "$launcher"
    
    # Create an HTML viewer script for web-based viewing
    local html_viewer="${output_dir}/view_in_browser.html"
    cat > "$html_viewer" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>$title - 3D Visualization</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background: #f0f0f0; padding: 10px; border-radius: 5px; }
        .overlay-list { margin: 20px 0; }
        .overlay-item { margin: 5px 0; padding: 5px; background: #f9f9f9; border-radius: 3px; }
        .instructions { background: #e8f4fd; padding: 10px; border-radius: 5px; margin: 10px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>$title</h1>
        <p>Generated: $(date)</p>
        <p>Reference: $(basename "$reference_image")</p>
    </div>
    
    <div class="instructions">
        <h3>Viewing Instructions:</h3>
        <p>To view the 3D visualization, run the following script:</p>
        <code>./$script_name</code>
        <p>Or use the launcher: <code>./launch_visualization.sh</code></p>
    </div>
    
    <div class="overlay-list">
        <h3>Available Overlays ($overlay_count found):</h3>
EOF

    # Add overlay information to HTML
    if [ $overlay_count -gt 0 ]; then
        echo "        <p>The visualization includes overlays for segmentation masks, hyperintensity analysis, and other analysis results.</p>" >> "$html_viewer"
    else
        echo "        <p>No overlay files found. The visualization will show only the background image.</p>" >> "$html_viewer"
    fi

    cat >> "$html_viewer" << EOF
    </div>
    
    <div class="instructions">
        <h3>FSLeyes Controls:</h3>
        <ul>
            <li>Mouse: Navigate through slices</li>
            <li>Right-click overlays: Adjust properties (colormap, opacity, etc.)</li>
            <li>Checkbox: Toggle overlay visibility</li>
            <li>3D button: Switch to volume rendering mode</li>
            <li>Settings: Access advanced visualization options</li>
        </ul>
    </div>
</body>
</html>
EOF
    
    log_formatted "SUCCESS" "3D visualization script created successfully"
    log_message "Main script: $script_path"
    log_message "Launcher: $launcher"
    log_message "HTML info: $html_viewer"
    log_message "Found $overlay_count overlay files"
    
    if [ $overlay_count -eq 0 ]; then
        log_formatted "WARNING" "No overlay files found - visualization will show only background image"
    fi
    
    return 0
}

# Function to create comprehensive FLAIR segmentation visualizations
create_comprehensive_flair_visualizations() {
    local flair_file="$1"
    local segmentation_dir="$2"
    local output_dir="${3:-${segmentation_dir}/visualizations}"
    local analysis_name="${4:-flair_comprehensive}"
    
    log_formatted "INFO" "===== COMPREHENSIVE FLAIR SEGMENTATION VISUALIZATION ====="
    log_message "FLAIR input: $flair_file"
    log_message "Segmentation directory: $segmentation_dir"
    log_message "Output directory: $output_dir"
    
    # Validate inputs
    if [ ! -f "$flair_file" ]; then
        log_formatted "ERROR" "FLAIR file not found: $flair_file"
        return 1
    fi
    
    if [ ! -d "$segmentation_dir" ]; then
        log_formatted "ERROR" "Segmentation directory not found: $segmentation_dir"
        return 1
    fi
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Find all FLAIR-related segmentation files
    log_message "Searching for FLAIR segmentation files..."
    local flair_masks=()
    local flair_intensities=()
    
    # Look for various types of FLAIR segmentation files
    local search_patterns=(
        "*flair*space*.nii.gz"
        "*FLAIR*.nii.gz"
        "*hyperintensit*.nii.gz"
        "*_flair_*.nii.gz"
        "*talairach*flair*.nii.gz"
        "*medulla*.nii.gz"
        "*pons*.nii.gz"
        "*midbrain*.nii.gz"
        "*left_medulla*.nii.gz"
        "*right_medulla*.nii.gz"
        "*left_pons*.nii.gz"
        "*right_pons*.nii.gz"
        "*left_midbrain*.nii.gz"
        "*right_midbrain*.nii.gz"
        "*brainstem*.nii.gz"
        "*talairach*.nii.gz"
    )
    
    for pattern in "${search_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            if [[ "$file" == *"_intensity"* ]] || [[ "$file" == *"_clustered"* ]]; then
                flair_intensities+=("$file")
            else
                flair_masks+=("$file")
            fi
        done < <(find "$segmentation_dir" -name "$pattern" -type f -print0 2>/dev/null)
    done
    
    # Also search in comprehensive analysis and Talairach-specific directories
    local additional_dirs=(
        "${segmentation_dir}/../comprehensive_analysis"
        "${segmentation_dir}/../segmentation/detailed_brainstem"
        "${segmentation_dir}/detailed_brainstem"
        "${segmentation_dir}/../talairach"
        "${segmentation_dir}/talairach"
        "${RESULTS_DIR}/comprehensive_analysis/original_space"
        "${RESULTS_DIR}/segmentation/detailed_brainstem"
        "${RESULTS_DIR}/talairach"
    )
    
    for comp_dir in "${additional_dirs[@]}"; do
        if [ -d "$comp_dir" ]; then
            log_message "Searching Talairach directory: $comp_dir"
            for pattern in "${search_patterns[@]}"; do
                while IFS= read -r -d '' file; do
                    if [[ "$file" == *"_intensity"* ]] || [[ "$file" == *"_clustered"* ]]; then
                        flair_intensities+=("$file")
                    else
                        flair_masks+=("$file")
                    fi
                done < <(find "$comp_dir" -name "$pattern" -type f -print0 2>/dev/null)
            done
        fi
    done
    
    # Remove duplicates and sort
    if [ ${#flair_masks[@]} -gt 0 ]; then
        readarray -t flair_masks < <(printf '%s\n' "${flair_masks[@]}" | sort -u)
    fi
    if [ ${#flair_intensities[@]} -gt 0 ]; then
        readarray -t flair_intensities < <(printf '%s\n' "${flair_intensities[@]}" | sort -u)
    fi
    
    log_message "Found ${#flair_masks[@]} FLAIR mask files"
    log_message "Found ${#flair_intensities[@]} FLAIR intensity files"
    
    if [ ${#flair_masks[@]} -eq 0 ] && [ ${#flair_intensities[@]} -eq 0 ]; then
        log_formatted "WARNING" "No FLAIR segmentation files found"
        return 1
    fi
    
    # Create comprehensive visualization script
    local viz_script="${output_dir}/${analysis_name}_all_segmentations.sh"
    cat > "$viz_script" << 'EOF'
#!/usr/bin/env bash
#
# Comprehensive FLAIR Segmentation Visualization
# Generated automatically for all FLAIR-related segmentations
#

echo "Starting comprehensive FLAIR segmentation visualization..."
echo "This will show all FLAIR segmentations and analysis results"
echo ""

# Check available visualization tools
FSLEYES_AVAILABLE=false
FREEVIEW_AVAILABLE=false

if command -v fsleyes &> /dev/null; then
    FSLEYES_AVAILABLE=true
fi

if command -v freeview &> /dev/null; then
    FREEVIEW_AVAILABLE=true
fi

if [ "$FSLEYES_AVAILABLE" = false ] && [ "$FREEVIEW_AVAILABLE" = false ]; then
    echo "ERROR: No visualization tools found (fsleyes or freeview)"
    exit 1
fi

echo "Available tools:"
[ "$FSLEYES_AVAILABLE" = true ] && echo "  - FSLeyes (FSL)"
[ "$FREEVIEW_AVAILABLE" = true ] && echo "  - FreeView (FreeSurfer)"
echo ""

# Choose visualization tool
if [ "$FSLEYES_AVAILABLE" = true ]; then
    echo "Using FSLeyes for comprehensive overlay visualization..."
    VISUALIZATION_CMD="fsleyes"
elif [ "$FREEVIEW_AVAILABLE" = true ]; then
    echo "Using FreeView for visualization..."
    VISUALIZATION_CMD="freeview -v"
fi

EOF

    # Add FLAIR background
    echo "# Add FLAIR background image" >> "$viz_script"
    echo "VISUALIZATION_CMD=\"\$VISUALIZATION_CMD '$flair_file'\"" >> "$viz_script"
    echo "echo \"Background: $(basename "$flair_file")\"" >> "$viz_script"
    echo "" >> "$viz_script"
    
    # Add each mask file with appropriate colormap
    local overlay_count=0
    for mask in "${flair_masks[@]}"; do
        if [ -f "$mask" ]; then
            local basename_mask=$(basename "$mask" .nii.gz)
            local colormap="random"
            local alpha="50"
            
            # Choose appropriate colormap based on file type (enhanced for Talairach)
            if [[ "$basename_mask" == *"hyperintens"* ]]; then
                colormap="hot"
                alpha="70"
            elif [[ "$basename_mask" == *"hypointens"* ]]; then
                colormap="cool"
                alpha="70"
            elif [[ "$basename_mask" == *"left_medulla"* ]]; then
                colormap="red"
                alpha="65"
            elif [[ "$basename_mask" == *"right_medulla"* ]]; then
                colormap="red-yellow"
                alpha="65"
            elif [[ "$basename_mask" == *"medulla"* ]]; then
                colormap="red"
                alpha="60"
            elif [[ "$basename_mask" == *"left_pons"* ]]; then
                colormap="blue"
                alpha="65"
            elif [[ "$basename_mask" == *"right_pons"* ]]; then
                colormap="blue-lightblue"
                alpha="65"
            elif [[ "$basename_mask" == *"pons"* ]]; then
                colormap="blue"
                alpha="60"
            elif [[ "$basename_mask" == *"left_midbrain"* ]]; then
                colormap="green"
                alpha="65"
            elif [[ "$basename_mask" == *"right_midbrain"* ]]; then
                colormap="green-blue"
                alpha="65"
            elif [[ "$basename_mask" == *"midbrain"* ]]; then
                colormap="green"
                alpha="60"
            elif [[ "$basename_mask" == *"brainstem"* ]]; then
                colormap="subcortical"
                alpha="55"
            elif [[ "$basename_mask" == *"talairach"* ]]; then
                colormap="random"
                alpha="50"
            fi
            
            cat >> "$viz_script" << EOF
# Add $(basename "$mask")
if [ -f "$mask" ]; then
    if [ "\$FSLEYES_AVAILABLE" = true ]; then
        VISUALIZATION_CMD="\$VISUALIZATION_CMD '$mask' -cm $colormap -a $alpha"
    else
        VISUALIZATION_CMD="\$VISUALIZATION_CMD '$mask':colormap=$colormap:opacity=0.$alpha"
    fi
    echo "Added overlay: $(basename "$mask") (${colormap})"
fi

EOF
            ((overlay_count++))
        fi
    done
    
    # Add intensity files
    for intensity in "${flair_intensities[@]}"; do
        if [ -f "$intensity" ]; then
            cat >> "$viz_script" << EOF
# Add $(basename "$intensity")
if [ -f "$intensity" ]; then
    if [ "\$FSLEYES_AVAILABLE" = true ]; then
        VISUALIZATION_CMD="\$VISUALIZATION_CMD '$intensity' -cm hot -a 80"
    else
        VISUALIZATION_CMD="\$VISUALIZATION_CMD '$intensity':colormap=heat:opacity=0.8"
    fi
    echo "Added intensity overlay: $(basename "$intensity")"
fi

EOF
            ((overlay_count++))
        fi
    done
    
    # Complete the script
    cat >> "$viz_script" << 'EOF'
# Launch visualization
echo ""
echo "Launching visualization with $overlay_count overlays..."
echo "Command: $VISUALIZATION_CMD"
echo ""
echo "Visualization Controls:"
if [ "$FSLEYES_AVAILABLE" = true ]; then
    echo "  FSLeyes:"
    echo "    - Mouse: Navigate through slices"
    echo "    - Right-click overlays: Adjust properties"
    echo "    - Checkboxes: Toggle overlay visibility"
    echo "    - 3D button: Switch to volume rendering"
else
    echo "  FreeView:"
    echo "    - Mouse: Rotate, pan, zoom"
    echo "    - View menu: Change display options"
    echo "    - Right-click: Context menu"
fi
echo ""

# Execute visualization
eval "$VISUALIZATION_CMD"
EOF

    chmod +x "$viz_script"
    
    # Create summary report
    local summary="${output_dir}/${analysis_name}_visualization_summary.txt"
    {
        echo "Comprehensive FLAIR Segmentation Visualization Summary"
        echo "====================================================="
        echo "Generated: $(date)"
        echo "FLAIR input: $(basename "$flair_file")"
        echo "Segmentation directory: $segmentation_dir"
        echo ""
        echo "Files included in visualization:"
        echo "--------------------------------"
        echo "Total overlays: $overlay_count"
        echo ""
        echo "Mask files (${#flair_masks[@]}):"
        for mask in "${flair_masks[@]}"; do
            echo "  - $(basename "$mask")"
        done
        echo ""
        echo "Intensity files (${#flair_intensities[@]}):"
        for intensity in "${flair_intensities[@]}"; do
            echo "  - $(basename "$intensity")"
        done
        echo ""
        echo "To view: ./${analysis_name}_all_segmentations.sh"
    } > "$summary"
    
    log_formatted "SUCCESS" "Comprehensive FLAIR visualization created"
    log_message "Visualization script: $viz_script"
    log_message "Summary report: $summary"
    log_message "Total overlays: $overlay_count"
    
    return 0
}

# Export functions
export -f detect_hyperintensities
export -f create_supratentorial_mask
export -f find_all_atlas_regions
export -f apply_per_region_gmm_analysis
export -f normalize_flair_brainstem_zscore
export -f apply_gaussian_mixture_thresholding
export -f apply_connectivity_weighting
export -f compute_regional_wm_statistics
export -f create_regional_threshold_map
export -f apply_regional_threshold
export -f analyze_clusters
export -f quantify_volumes
export -f create_multi_threshold_comparison
export -f create_3d_rendering
export -f create_intensity_profiles
export -f transform_segmentation_to_original
export -f analyze_talairach_hyperintensities
export -f run_comprehensive_analysis
export -f create_3d_visualization_script
export -f create_comprehensive_flair_visualizations

log_message "Analysis module loaded with enhanced regional adaptive thresholding"
