#!/usr/bin/env bash
#
# analysis.sh - Analysis functions for the brain MRI processing pipeline
#
# This module contains:
# - Region-based hyperintensity detection over the FreeSurfer brainstem
#   substructures (falls back to the HO gross mask when absent)
# - CSF / partial-volume exclusion (subtracts an FSL FAST CSF-PVE-derived mask;
#   posterior-fossa CSF is the dominant false-positive source) before thresholding
# - Per-region GMM thresholding (delegated to gmm_threshold.py; adaptive 2-3
#   components) with a single authoritative fallback SD multiplier
#   (THRESHOLD_WM_SD_MULTIPLIER) when GMM is skipped
# - Cluster analysis (3D connectivity + minimum-size filtering)
# - Volume quantification
# - Analysis QA integration
#

# Return 0 if two images occupy the SAME voxel space, 1 otherwise.
# A matrix-dimension match alone is NOT sufficient: two volumes can share dims
# yet differ in voxel size (pixdim) or world transform (sform/qform), which would
# silently misalign a copied mask.  This compares dim1-3, pixdim1-3 AND the world
# transform so the caller only skips resampling when the grids truly coincide.
#
# Conservative by design: when the world transform cannot be CONFIRMED equal
# (sform missing/degenerate on either image, falling through to a degenerate
# qform), this returns 1 (NOT same space) so the caller resamples via the header
# transform — which is a safe no-op if the grids actually do match, but avoids a
# silent misalignment if they don't.
_analysis_same_space() {
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] || return 1

    local a_dims b_dims a_pix b_pix
    a_dims=$(fslinfo "$a" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x')
    b_dims=$(fslinfo "$b" | grep -E "^dim[123]" | awk '{print $2}' | tr '\n' 'x')
    [ "$a_dims" = "$b_dims" ] || return 1

    a_pix=$(fslinfo "$a" | grep -E "^pixdim[123]" | awk '{printf "%.4f ", $2}')
    b_pix=$(fslinfo "$b" | grep -E "^pixdim[123]" | awk '{printf "%.4f ", $2}')
    [ "$a_pix" = "$b_pix" ] || return 1

    # Compare the world transform (rounded). Prefer sform; fall back to qform.
    # A matrix that is empty or all-zeros (sform_code/qform_code = 0) is treated
    # as UNUSABLE — two unusable matrices must NOT be compared as "equal", since
    # that would let genuinely different spaces slip through (the exact failure
    # this helper exists to prevent).
    local a_world b_world
    a_world=$(_analysis_world_matrix "$a")
    b_world=$(_analysis_world_matrix "$b")
    if [ -z "$a_world" ] || [ -z "$b_world" ]; then
        # Cannot confirm the world transform -> be conservative, force resample.
        return 1
    fi
    [ "$a_world" = "$b_world" ] || return 1
    return 0
}

# Echo a rounded, single-line world matrix (sform preferred, qform fallback) for
# an image, or echo nothing when neither is usable (empty or all-zeros).
_analysis_world_matrix() {
    local img="$1" m
    local xform
    for xform in getsform getqform; do
        m=$(fslorient "-${xform}" "$img" 2>/dev/null | awk '{for(i=1;i<=NF;i++) printf "%.3f ", $i}')
        # Reject empty or all-zero (degenerate / code 0) matrices.
        if [ -n "$m" ] && echo "$m" | grep -qE '[1-9]'; then
            echo "$m"
            return 0
        fi
    done
    return 0
}

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
        
        # Reset any value left over from a previous subject (batch mode) so a
        # stale export can't be mistaken for this subject's result if the GMM
        # step exits without setting it.
        export ATLAS_GMM_RESULT=""

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
            
            # Use the combined atlas GMM result. apply_per_region_gmm_analysis
            # only exports ATLAS_GMM_RESULT when >=1 region succeeds; under
            # `set -u` an unset reference would hard-abort the run (now reachable
            # because detect_hyperintensities is the default primary engine), so
            # default it to empty and let the [ -n ]/[ -f ] guard handle absence.
            if [ -n "${ATLAS_GMM_RESULT:-}" ] && [ -f "${ATLAS_GMM_RESULT:-}" ]; then
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
                    fslmaths "$ho_sub_reg" -thr 6.9 -uthr 7.1 -bin "${temp_dir}/brainstem_mask.nii.gz" -odt int
                    
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
    
    log_message "Searching for ALL brainstem substructure regions..."

    # Primary locations for brainstem substructure masks. FreeSurfer parcels
    # (brainstem_freesurfer.sh) are written to segmentation/detailed_brainstem.
    local search_dirs=(
        "${RESULTS_DIR}/segmentation/detailed_brainstem"
        "${RESULTS_DIR}/segmentation/pons"
        "${RESULTS_DIR}/comprehensive_analysis/original_space"
    )

    # Region patterns to find. The per-region GMM analyses the UNION of every
    # mask the parallel segmentation paths produced:
    #   - FreeSurfer parcels (brainstem_freesurfer.sh): <basename>_pons.nii.gz,
    #     <basename>_left_pons.nii.gz, <basename>_midbrain.nii.gz, ... (gross
    #     subdivisions, optional left/right splits).
    #   - Multi-atlas gross subdivisions (multi_atlas.sh aggregation):
    #     bianciardi_pons.nii.gz, bianciardi_left_midbrain.nii.gz, ... (matched by
    #     the *_pons / *left_pons globs below).
    #   - Multi-atlas NUCLEUS-level masks: bianciardi_*_label*, cit168_*_label*,
    #     aal3_*_label* — added explicitly so the CIT168 / AAL3 / Bianciardi nuclei
    #     are part of the union, not just the aggregated subdivisions.
    # The voxel-size filter + sort -u dedup below keep the union clean.
    local region_patterns=(
        "*left_medulla*.nii.gz"
        "*right_medulla*.nii.gz"
        "*left_pons*.nii.gz"
        "*right_pons*.nii.gz"
        "*left_midbrain*.nii.gz"
        "*right_midbrain*.nii.gz"
        "*left_scp*.nii.gz"
        "*right_scp*.nii.gz"
        "*_pons.nii.gz"
        "*_midbrain.nii.gz"
        "*_medulla.nii.gz"
        "*_scp.nii.gz"
        "bianciardi_*_label*.nii.gz"
        "cit168_*_label*.nii.gz"
        "aal3_*_label*.nii.gz"
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
    
    # Fallback: when no substructure parcels exist (e.g. FreeSurfer
    # unavailable/low-confidence, or BRAINSTEM_SEGMENTATION_METHOD=atlas), fall
    # back to the gross Harvard-Oxford Brain-Stem mask so per-region GMM still
    # runs on the whole brainstem instead of aborting the analysis stage. This
    # is a single, coarser region (no pons/midbrain/medulla split).
    if [ ${#regions_array[@]} -eq 0 ]; then
        log_formatted "WARNING" "No brainstem substructure parcels found; falling back to the gross brainstem mask (whole-brainstem region, no subdivision)"
        local gross_candidates=(
            "${RESULTS_DIR}/segmentation/brainstem/"*"_brainstem.nii.gz"
            "${RESULTS_DIR}/segmentation/in_reference_space/"*"_brainstem.nii.gz"
        )
        local gross_file
        for gross_file in "${gross_candidates[@]}"; do
            [ -f "$gross_file" ] || continue
            local gross_base=$(basename "$gross_file" .nii.gz)
            # Skip intensity/derivative files
            if [[ "$gross_base" == *"_intensity"* ]] || [[ "$gross_base" == *"_flair_"* ]] || [[ "$gross_base" == *"_mask"* ]]; then
                continue
            fi
            local gross_vol=$(fslstats "$gross_file" -V | awk '{print $1}')
            if [ "$gross_vol" -gt 10 ]; then
                regions_array+=("$gross_file")
                log_message "✓ Found gross brainstem region: $gross_base (${gross_vol} voxels)"
                break
            fi
        done
    fi

    # Remove duplicates and sort
    if [ ${#regions_array[@]} -gt 0 ]; then
        readarray -t regions_array < <(printf '%s\n' "${regions_array[@]}" | sort -u)
        log_message "Found ${#regions_array[@]} unique brainstem regions for analysis"
    else
        log_formatted "ERROR" "No brainstem segmentation regions found"
        return 1
    fi

    return 0
}

# Determine the PROVENANCE (source segmentation path) of a region mask from its
# path/filename. The parallel 'all' mode emits masks from several sources into
# segmentation/detailed_brainstem; tagging each region by source keeps per-source
# outputs non-clobbering (e.g. freesurfer_pons vs bianciardi_pons) and records
# which path each detected region came from.
#   freesurfer    : FreeSurfer parcels         <base>_{pons,midbrain,medulla,scp}*
#   bianciardi    : Bianciardi nuclei/aggregate bianciardi_*
#   cit168        : CIT168 nuclei              cit168_*
#   aal3          : AAL3 regions               aal3_*
#   harvard_oxford: gross HO fallback mask     *_brainstem.nii.gz (segmentation/brainstem)
#   atlas         : anything else (unattributed)
_region_source_from_path() {
    local p="$1"
    local b
    b=$(basename "$p")
    case "$b" in
        bianciardi_*) echo "bianciardi" ;;
        cit168_*)     echo "cit168" ;;
        aal3_*)       echo "aal3" ;;
        *)
            case "$p" in
                */segmentation/brainstem/*) echo "harvard_oxford" ;;
                *)
                    # FreeSurfer parcels are written as <base>_{region}.nii.gz under
                    # detailed_brainstem (no atlas prefix); treat the remaining
                    # subdivision masks there as FreeSurfer-sourced.
                    case "$p" in
                        */detailed_brainstem/*) echo "freesurfer" ;;
                        *) echo "atlas" ;;
                    esac
                    ;;
            esac
            ;;
    esac
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
    if [[ "$region_name" == *"/"* ]] || [ ${#region_name} -gt 20 ]; then
        region_name="region"
    fi

    log_message "Applying GMM analysis to ${region_name} for FLAIR hyperintensity detection..."

    # Validate inputs exist
    if [ -z "$zscore_image" ] || [ ! -f "$zscore_image" ]; then
        log_formatted "ERROR" "Z-score image not found or invalid: $zscore_image"
        return 1
    fi
    if [ -z "$region_mask" ] || [ ! -f "$region_mask" ]; then
        log_formatted "ERROR" "Region mask not found or invalid: $region_mask"
        return 1
    fi

    # Validate mask has reasonable size
    local mask_volume=$(fslstats "$region_mask" -V | awk '{print $1}')
    log_message "Region $region_name mask contains $mask_volume voxels"

    if [ "$mask_volume" -lt "${GMM_MIN_VOXELS:-20}" ]; then
        log_formatted "ERROR" "Region mask too small ($mask_volume voxels) for meaningful GMM analysis"
        # Literal must equal config THRESHOLD_WM_SD_MULTIPLIER (single authoritative fallback)
        local bash_fallback="${GMM_FALLBACK_THRESHOLD:-${THRESHOLD_WM_SD_MULTIPLIER:-1.2}}"
        fslmaths "$zscore_image" -mas "$region_mask" -thr "$bash_fallback" -bin "$output_mask"
        return 1
    fi

    # Resolve gmm_threshold.py script path
    local gmm_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gmm_threshold.py"
    if [ ! -f "$gmm_script" ]; then
        gmm_script="../src/modules/gmm_threshold.py"
    fi
    if [ ! -f "$gmm_script" ]; then
        log_formatted "ERROR" "GMM threshold script not found"
        return 1
    fi

    # Run GMM analysis: Python reads NIfTIs directly, emits key=value to stdout,
    # diagnostics go to stderr (captured in pipeline logs).
    # All parameters are passed from config to avoid hardcoded magic numbers.
    local gmm_output
    # Config env var -> CLI arg mapping:  GMM_<NAME> -> --<name>
    # GMM_FALLBACK_THRESHOLD is intentionally not set in config; it falls
    # through to THRESHOLD_WM_SD_MULTIPLIER so there is one authoritative
    # fallback for all hyperintensity detection paths.
    gmm_output=$(python3 "$gmm_script" "$zscore_image" "$region_mask" \
        --max-components "${GMM_MAX_COMPONENTS:-3}" \
        --min-voxels "${GMM_MIN_VOXELS:-20}" \
        --voxels-per-component "${GMM_VOXELS_PER_COMPONENT:-30}" \
        --sd-2comp "${GMM_SD_2COMP:-1.0}" \
        --sd-3comp "${GMM_SD_3COMP:-1.5}" \
        --small-weight-cutoff "${GMM_SMALL_WEIGHT_CUTOFF:-0.05}" \
        --small-weight-sd "${GMM_SMALL_WEIGHT_SD:-2.5}" \
        --moderate-weight-cutoff "${GMM_MODERATE_WEIGHT_CUTOFF:-0.15}" \
        --moderate-weight-sd "${GMM_MODERATE_WEIGHT_SD:-2.0}" \
        --floor-percentile "${GMM_FLOOR_PERCENTILE:-95}" \
        --fallback-percentile "${GMM_FALLBACK_PERCENTILE:-97.5}" \
        --fallback-threshold "${GMM_FALLBACK_THRESHOLD:-${THRESHOLD_WM_SD_MULTIPLIER:-1.2}}" \
        2>"${gmm_temp_dir}/gmm_stderr.log")
    local gmm_exit=$?

    # Log stderr from Python (diagnostics)
    if [ -f "${gmm_temp_dir}/gmm_stderr.log" ]; then
        while IFS= read -r line; do
            log_message "GMM: $line"
        done < "${gmm_temp_dir}/gmm_stderr.log"
        rm -f "${gmm_temp_dir}/gmm_stderr.log"
    fi

    # Parse stdout key=value pairs into local variables
    local threshold="$THRESHOLD_WM_SD_MULTIPLIER"  # Default fallback
    local n_voxels=""
    local gmm_failed=""
    local n_components=""
    local upper_weight=""
    local gmm_status="unknown"

    if [ -n "$gmm_output" ]; then
        threshold=$(echo "$gmm_output" | grep "^THRESHOLD=" | cut -d'=' -f2)
        n_voxels=$(echo "$gmm_output" | grep "^N_VOXELS=" | cut -d'=' -f2)
        gmm_failed=$(echo "$gmm_output" | grep "^GMM_FAILED=" | cut -d'=' -f2)
        n_components=$(echo "$gmm_output" | grep "^GMM_COMPONENTS=" | cut -d'=' -f2)
        upper_weight=$(echo "$gmm_output" | grep "^UPPER_WEIGHT=" | cut -d'=' -f2)
    fi

    # Also write to params file for downstream inspection/debugging
    if [ -n "$gmm_params_file" ] && [ -n "$gmm_output" ]; then
        echo "$gmm_output" > "$gmm_params_file"
    fi

    # Validate threshold
    if [ -z "$threshold" ] || ! echo "$threshold" | grep -E '^[0-9]+\.?[0-9]*$' >/dev/null; then
        log_formatted "WARNING" "Invalid threshold value '$threshold', using fallback"
        threshold="${GMM_FALLBACK_THRESHOLD:-${THRESHOLD_WM_SD_MULTIPLIER:-1.2}}"
    fi

    if [ "$gmm_failed" = "true" ]; then
        gmm_status="failed (using data-driven fallback)"
        log_message "GMM analysis failed, using data-driven fallback threshold: $threshold"
    elif [ -n "$n_components" ]; then
        gmm_status="success (${n_components} components, weight: ${upper_weight})"
    fi

    log_message "✓ GMM analysis for $region_name: $gmm_status"
    log_message "  Using threshold: $threshold (from ${n_voxels:-?} voxels)"

    # Apply threshold to create binary mask
    log_message "Applying threshold $threshold to create binary mask..."
    if ! fslmaths "$zscore_image" -mul "$region_mask" -thr "$threshold" -bin "$output_mask"; then
        log_formatted "ERROR" "Failed to apply threshold - fslmaths operation failed"
        fslmaths "$zscore_image" -mul "$region_mask" -mul 0 "$output_mask"
    fi

    # Verify output
    if [ ! -f "$output_mask" ]; then
        log_formatted "ERROR" "Output mask not created: $output_mask"
        return 1
    fi

    local output_stats
    if ! output_stats=$(fslstats "$output_mask" -V 2>/dev/null); then
        log_formatted "ERROR" "Output mask appears corrupted or unreadable: $output_mask"
        return 1
    fi

    local detected_voxels=$(echo "$output_stats" | awk '{print $1}')
    local detected_volume=$(echo "$output_stats" | awk '{print $2}')

    local input_volume=$(fslstats "$region_mask" -V | awk '{print $2}' 2>/dev/null || echo "0")
    local volume_ratio="0"
    if [ "$input_volume" != "0" ] && [ -n "$input_volume" ]; then
        volume_ratio=$(echo "scale=3; $detected_volume / $input_volume" | bc -l 2>/dev/null || echo "0")
    fi

    log_message "✓ GMM thresholding results for $region_name:"
    log_message "  • Detected volume: ${detected_volume} mm³ (${detected_voxels} voxels)"
    log_message "  • Region coverage: ${volume_ratio} ($(echo "$volume_ratio * 100" | bc -l 2>/dev/null | cut -d. -f1)%)"
    log_message "  • Output file: $(basename "$output_mask")"

    if [ "$detected_voxels" = "0" ]; then
        log_message "Note: No hyperintensities detected in this region (may be normal)"
    fi

    return 0
}



# Build a binary CSF exclusion mask (in the target/FLAIR space).  The CSF map is
# region-independent, so this is computed ONCE per subject and reused for every
# region (avoids re-resampling the whole-brain map per region).  Posterior-fossa
# CSF (4th ventricle, basal cisterns) is the dominant FALSE-POSITIVE source for
# brainstem FLAIR.
#
# CSF SOURCE PREFERENCE (#135 FreeSurfer harvest, task B):
#   When available AND CSF_USE_FREESURFER_MASK=true, prefer the FreeSurfer aseg
#   (or SynthSeg) 4th-ventricle / CSF mask harvested by freesurfer_harvest.sh
#   (fs_harvest_find_csf_mask) — it delineates the posterior-fossa CSF far better
#   than the FAST CSF PVE for the brainstem pseudolesion problem. Fall back to the
#   FAST CSF PVE (<csf_prob>) when no FreeSurfer/SynthSeg mask is present.
#
# Usage: build_csf_exclusion_mask <csf_prob_map> <reference_image> <output_mask>
# Returns 0 on success (output written), 1 if no usable exclusion mask could be
# built (output not guaranteed to exist; caller must handle).
build_csf_exclusion_mask() {
    local csf_prob="$1"
    local reference_image="$2"
    local output_mask="$3"

    local csf_pve_threshold="${CSF_PVE_THRESHOLD:-0.5}"

    # Prefer the FreeSurfer/SynthSeg aseg CSF mask (already binary) when present.
    # fs_harvest_find_csf_mask returns the best available aseg/synthseg csf_all
    # (CSF + ventricles) mask, empty if none. Gated so the legacy FAST-PVE
    # behaviour can be restored with CSF_USE_FREESURFER_MASK=false.
    if [ "${CSF_USE_FREESURFER_MASK:-true}" = "true" ] && declare -f fs_harvest_find_csf_mask >/dev/null 2>&1; then
        local fs_csf_mask
        fs_csf_mask="$(fs_harvest_find_csf_mask)"
        if [ -n "$fs_csf_mask" ] && [ -f "$fs_csf_mask" ]; then
            log_message "Building CSF exclusion mask from FreeSurfer/SynthSeg aseg CSF mask (preferred over FAST PVE for posterior-fossa): $fs_csf_mask"
            local work_dir_fs
            work_dir_fs=$(mktemp -d)
            local fs_resampled="$fs_csf_mask"
            if ! _analysis_same_space "$reference_image" "$fs_csf_mask"; then
                fs_resampled="${work_dir_fs}/fs_csf_resampled.nii.gz"
                log_message "Resampling FreeSurfer CSF mask to reference space..."
                if ! flirt -in "$fs_csf_mask" -ref "$reference_image" -out "$fs_resampled" -applyxfm -usesqform -interp nearestneighbour; then
                    log_formatted "WARNING" "FreeSurfer CSF mask resampling failed; falling back to FAST CSF PVE"
                    rm -rf "$work_dir_fs"
                    fs_resampled=""
                fi
            fi
            # The harvested mask is already binary; -bin guards against any
            # interpolation residue introduced by a (nearest-neighbour) resample.
            if [ -n "$fs_resampled" ] && safe_fslmaths "Build CSF exclusion mask (FreeSurfer aseg)" \
                    "$fs_resampled" -bin "$output_mask"; then
                rm -rf "$work_dir_fs"
                log_message "✓ CSF exclusion mask built from FreeSurfer/SynthSeg aseg CSF"
                return 0
            fi
            rm -rf "$work_dir_fs" 2>/dev/null || true
            log_formatted "WARNING" "Could not use FreeSurfer CSF mask; falling back to FAST CSF PVE"
        fi
    fi

    log_message "Building CSF exclusion mask from FAST CSF PVE map..."

    if [ -z "$csf_prob" ] || [ ! -f "$csf_prob" ]; then
        log_formatted "WARNING" "CSF PVE map not available ($csf_prob); CSF subtraction will be skipped"
        return 1
    fi

    local work_dir
    work_dir=$(mktemp -d)

    # CSF PVE map may be in a different space than the reference; resample if so.
    # Use a full same-space check (dims + pixdim + sform), not dims alone, so we
    # never skip resampling on a grid that merely shares matrix dimensions.
    local csf_resampled="$csf_prob"
    if ! _analysis_same_space "$reference_image" "$csf_prob"; then
        csf_resampled="${work_dir}/csf_resampled.nii.gz"
        log_message "Resampling CSF PVE map to reference space..."
        # -applyxfm -usesqform uses the stored sform/qform to map between the
        # two grids (header-based resample), which is correct here because the
        # CSF PVE map and the reference are already in the same physical space
        # and only differ in sampling grid (no rigid registration needed).
        if ! flirt -in "$csf_prob" -ref "$reference_image" -out "$csf_resampled" -applyxfm -usesqform -interp trilinear; then
            log_formatted "WARNING" "CSF PVE resampling failed; CSF subtraction will be skipped"
            rm -rf "$work_dir"
            return 1
        fi
    fi

    # CSF voxels: PVE > threshold.
    if ! safe_fslmaths "Build CSF exclusion mask" \
            "$csf_resampled" -thr "$csf_pve_threshold" -bin "$output_mask"; then
        log_formatted "WARNING" "Failed to threshold CSF PVE map; CSF subtraction will be skipped"
        rm -rf "$work_dir"
        return 1
    fi

    rm -rf "$work_dir"
    log_message "✓ CSF exclusion mask built (PVE > ${csf_pve_threshold})"
    return 0
}

# Function to remove CSF and CSF-parenchyma partial-volume voxels from a region
# mask before z-scoring/GMM.  Excluding posterior-fossa CSF materially reduces
# spurious brainstem-FLAIR detections.  Gated by CSF_EXCLUSION_ENABLED.
#
# Usage: apply_csf_pv_exclusion <region_mask_in> <csf_exclusion_mask> <region_mask_out> [<region_name>]
#   <csf_exclusion_mask> is the pre-built binary CSF mask (build_csf_exclusion_mask)
#   in the SAME space as <region_mask_in>; pass "" to skip CSF subtraction and
#   only apply partial-volume erosion.
# Returns 0 and writes the cleaned mask to <region_mask_out>.  On any failure (or
# when disabled) it copies the input through unchanged so the caller always has a
# usable mask.
apply_csf_pv_exclusion() {
    local region_mask_in="$1"
    local csf_exclusion_mask="$2"
    local region_mask_out="$3"
    local region_name="${4:-region}"

    log_message "Applying CSF / partial-volume exclusion for $region_name..."

    # Feature gate: when disabled, pass the mask through unchanged.
    if [ "${CSF_EXCLUSION_ENABLED:-true}" != "true" ]; then
        log_message "CSF/PV exclusion disabled (CSF_EXCLUSION_ENABLED=${CSF_EXCLUSION_ENABLED:-true}); using region mask unchanged"
        cp "$region_mask_in" "$region_mask_out"
        return 0
    fi

    local pv_erosion_mm="${PV_EROSION_MM:-1}"

    local voxels_before
    voxels_before=$(fslstats "$region_mask_in" -V | awk '{print $1}')
    # Coerce to a safe integer so downstream arithmetic/comparisons can't abort
    [[ "$voxels_before" =~ ^[0-9]+$ ]] || voxels_before=0

    local work_dir
    work_dir=$(mktemp -d)
    local working_mask="${work_dir}/region_pv_eroded.nii.gz"

    # 1) Erode the region mask by the partial-volume band (mm) to drop
    #    CSF-parenchyma boundary voxels.  -kernel sphere uses mm radius.
    if ! safe_fslmaths "Erode $region_name region mask by PV band" \
            "$region_mask_in" -kernel sphere "$pv_erosion_mm" -ero "$working_mask"; then
        log_formatted "WARNING" "PV-band erosion failed for $region_name; using un-eroded mask"
        cp "$region_mask_in" "$working_mask"
    fi

    # 2) Subtract the pre-built CSF exclusion mask (same space as region mask).
    if [ -n "$csf_exclusion_mask" ] && [ -f "$csf_exclusion_mask" ]; then
        if ! safe_fslmaths "Subtract CSF from $region_name region mask" \
                "$working_mask" -sub "$csf_exclusion_mask" -thr 0 -bin "$region_mask_out"; then
            log_formatted "WARNING" "CSF subtraction failed for $region_name; using PV-eroded mask only"
            cp "$working_mask" "$region_mask_out"
        fi
    else
        log_message "No CSF exclusion mask for $region_name; applying PV erosion only"
        cp "$working_mask" "$region_mask_out"
    fi

    rm -rf "$work_dir"

    local voxels_after
    voxels_after=$(fslstats "$region_mask_out" -V | awk '{print $1}')
    [[ "$voxels_after" =~ ^[0-9]+$ ]] || voxels_after=0
    local excluded=$(( voxels_before - voxels_after ))
    log_message "✓ CSF/PV exclusion for $region_name: ${voxels_before} → ${voxels_after} voxels (${excluded} excluded)"

    return 0
}

# Function to apply per-region GMM analysis to all atlas regions
apply_per_region_gmm_analysis() {
    local flair_image="$1"
    local -n regions_ref=$2
    local temp_dir="$3"
    local out_prefix="$4"

    # CSF PVE map produced by FSL FAST in detect_hyperintensities() (fast_pve_0).
    # Used to exclude CSF / partial-volume voxels from each region before GMM.
    local csf_prob="${out_prefix}_csf_prob.nii.gz"

    log_message "Applying per-region GMM analysis to ${#regions_ref[@]} atlas regions..."

    # Create PERMANENT per-region analysis directory for debugging
    local per_region_dir="${RESULTS_DIR}/per_region_analysis"
    mkdir -p "$per_region_dir"

    # Store results for each region
    local region_results=()
    local combined_result="${per_region_dir}/atlas_gmm_combined.nii.gz"

    # Initialize combined result as zeros
    fslmaths "$flair_image" -mul 0 "$combined_result"

    # Provenance manifest: records which SOURCE path (freesurfer / bianciardi /
    # cit168 / aal3 / harvard_oxford) each analysed region came from. The parallel
    # 'all' segmentation mode produces masks from several sources; downstream the
    # per-region GMM runs across the UNION, so tagging provenance keeps per-source
    # outputs distinct and traceable in the report.
    local provenance_manifest="${per_region_dir}/region_provenance.tsv"
    printf 'region_tag\tregion_base\tsource\tmask_path\n' > "$provenance_manifest"

    # Build the CSF exclusion mask ONCE (FLAIR space) since it is region-independent.
    # Region masks are resampled to FLAIR space below, so this mask aligns with all
    # of them.  Empty string => CSF subtraction is skipped (PV erosion still applies).
    local csf_exclusion_mask=""
    if [ "${CSF_EXCLUSION_ENABLED:-true}" = "true" ]; then
        local csf_exclusion_candidate="${per_region_dir}/csf_exclusion_mask.nii.gz"
        if build_csf_exclusion_mask "$csf_prob" "$flair_image" "$csf_exclusion_candidate"; then
            csf_exclusion_mask="$csf_exclusion_candidate"
        fi
    fi
    
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
        elif [[ "$region_name" =~ ^(bianciardi|cit168|aal3)_(.+)_label[0-9]+$ ]]; then
            # Multi-atlas nucleus mask <atlas>_<nucleus>_label<N>: use the nucleus
            # name (atlas prefix is recorded separately as provenance below).
            region_base="${BASH_REMATCH[2]}"
        else
            region_base=$(echo "$region_name" | sed -E 's/.*_([^_]+)$/\1/')
        fi
        
        # Validate and fallback
        if [ -z "$region_base" ] || [[ "$region_base" == *"/"* ]]; then
            region_base="unknown_region_$(date +%s)"
        fi

        # Tag the region with its PROVENANCE so masks of the same anatomical name
        # from DIFFERENT sources (e.g. FreeSurfer pons vs Bianciardi pons) do not
        # clobber each other's work dir / per-region output, and so the report can
        # attribute each detection to the path that produced it.
        local region_source
        region_source=$(_region_source_from_path "$region_mask")
        local region_tag="${region_source}_${region_base}"
        printf '%s\t%s\t%s\t%s\n' "$region_tag" "$region_base" "$region_source" "$region_mask" >> "$provenance_manifest"

        log_message "Processing region: $region_base [source=$region_source] (FLAIR hyperintensity analysis)"

        # Create organized region-specific working directory with modality info
        # (provenance-namespaced so parallel sources never share a work dir).
        local region_work_dir="${per_region_dir}/${region_tag}_FLAIR_analysis"
        mkdir -p "$region_work_dir"
        
        # Create GMM analysis subdirectory for temp files
        local gmm_temp_dir="${region_work_dir}/gmm_analysis"
        mkdir -p "$gmm_temp_dir"
        
        # Check if mask needs resampling to match FLAIR space.  Use the full
        # same-space check (dims + pixdim + sform), not dims alone, and resample
        # via the header transform (-applyxfm -usesqform) with nearestneighbour
        # to preserve the discrete label mask.
        local region_resampled="${region_work_dir}/${region_base}_resampled.nii.gz"
        if _analysis_same_space "$region_mask" "$flair_image"; then
            cp "$region_mask" "$region_resampled"
        else
            log_message "Resampling $region_base mask to FLAIR space..."
            flirt -in "$region_mask" -ref "$flair_image" -out "$region_resampled" -applyxfm -usesqform -interp nearestneighbour
        fi

        # CRITICAL: Pre-filter segmentation mask with brain mask BEFORE any analysis
        local region_brain_masked="${region_work_dir}/${region_base}_brain_masked.nii.gz"
        log_message "Pre-filtering $region_base with brain mask to exclude non-brain voxels..."

        # Resample brain mask to match region if needed (same-space check + header resample)
        local brain_mask_resampled="$brain_mask"
        if ! _analysis_same_space "$brain_mask" "$flair_image"; then
            brain_mask_resampled="${region_work_dir}/brain_mask_resampled.nii.gz"
            flirt -in "$brain_mask" -ref "$flair_image" -out "$brain_mask_resampled" -applyxfm -usesqform -interp nearestneighbour
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

        # Remove CSF and CSF-parenchyma partial-volume voxels (posterior-fossa
        # false-positive reduction) BEFORE z-scoring/GMM.  No-op when disabled.
        local region_csf_excluded="${region_work_dir}/${region_base}_csf_excluded.nii.gz"
        if apply_csf_pv_exclusion "$region_resampled" "$csf_exclusion_mask" "$region_csf_excluded" "$region_base"; then
            local csf_excluded_voxels
            csf_excluded_voxels=$(fslstats "$region_csf_excluded" -V | awk '{print $1}')
            # Coerce to a safe integer so the -lt comparison can't error out
            [[ "$csf_excluded_voxels" =~ ^[0-9]+$ ]] || csf_excluded_voxels=0
            if [ "$csf_excluded_voxels" -lt 50 ]; then
                log_formatted "WARNING" "$region_base has insufficient voxels ($csf_excluded_voxels) after CSF/PV exclusion - skipping"
                continue
            fi
            region_resampled="$region_csf_excluded"
        fi

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
                    
                    log_message "✓ Successfully processed $region_base [source=$region_source] with GMM analysis"

                    # Create region-specific output files. Namespace by PROVENANCE
                    # so same-named regions from different sources (e.g. FreeSurfer
                    # vs Bianciardi pons) produce DISTINCT, non-clobbering outputs.
                    local region_output="${out_prefix}_${region_tag}_GMM.nii.gz"
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

        # Summarise per-source provenance of the analysed regions.
        if [ -f "$provenance_manifest" ]; then
            log_message "Region provenance (source: count):"
            tail -n +2 "$provenance_manifest" | awk -F'\t' '{c[$3]++} END{for(s in c) printf "  %s: %d\n", s, c[s]}' | while IFS= read -r line; do
                log_message "$line"
            done
            log_message "Provenance manifest: $provenance_manifest"
        fi

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
    
    # Calculate adaptive thresholds (SD multipliers are configurable)
    local high_sd_mult="${CONNECTIVITY_HIGH_SD_MULT:-2.0}"
    local connected_sd_mult="${CONNECTIVITY_CONNECTED_SD_MULT:-1.5}"
    local base_threshold=$(echo "$region_mean + $high_sd_mult * $region_std" | bc -l)
    local connected_threshold=$(echo "$region_mean + $connected_sd_mult * $region_std" | bc -l)
    
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

# Function to discover threshold/method outputs for reporting and visualization
discover_threshold_methods() {
    local prefix="$1"
    local -n methods_ref=$2
    methods_ref=()

    local prefix_base
    prefix_base=$(basename "$prefix")
    local numeric_methods=()
    local named_methods=()

    for thresh_file in "${prefix}_thresh"*"_bin.nii.gz"; do
        if [ ! -f "$thresh_file" ]; then
            continue
        fi

        local method
        method=$(basename "$thresh_file")
        method="${method#${prefix_base}_thresh}"
        method="${method%_bin.nii.gz}"

        if [ -z "$method" ]; then
            continue
        fi

        if [[ "$method" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            numeric_methods+=("$method")
        else
            named_methods+=("$method")
        fi
    done

    if [ ${#numeric_methods[@]} -gt 0 ]; then
        readarray -t numeric_methods < <(printf '%s\n' "${numeric_methods[@]}" | sort -n)
    fi
    if [ ${#named_methods[@]} -gt 0 ]; then
        readarray -t named_methods < <(printf '%s\n' "${named_methods[@]}" | sort)
    fi

    methods_ref=("${numeric_methods[@]}" "${named_methods[@]}")
}

# Function to quantify volumes with enhanced per-threshold cluster analysis
quantify_volumes() {
    local prefix="$1"
    local output_file="${prefix}_volumes.csv"
    
    log_message "Quantifying volumes for $prefix with per-threshold cluster analysis"
    
    # Create enhanced CSV header
    echo "Threshold,Volume (mm³),Volume (voxels),NumClusters,LargestCluster (mm³),MeanClusterSize (mm³),RegionalMethod" > "$output_file"
    
    # Get threshold/method values from available files.  These can be numeric
    # legacy thresholds (1.5, 2.0) or named methods (ATLAS_GMM).
    local available_thresholds=()
    discover_threshold_methods "$prefix" available_thresholds
    
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
            log_message "No cluster analysis file found for threshold/method $mult, computing basic stats"
        fi
        
        # Determine if regional method was used (check for regional stats file)
        local regional_method="No"
        if [ -f "${prefix}_regional_wm_stats.txt" ] || [[ "$mult" == *"GMM"* ]]; then
            regional_method="Yes"
        fi
        
        # Add to CSV with enhanced information
        echo "${mult},${total_volume_mm3},${total_volume_voxels},${num_clusters},${largest_cluster},${mean_cluster_size},${regional_method}" >> "$output_file"
        
        log_message "✓ Threshold/method ${mult}: ${total_volume_mm3} mm³, ${num_clusters} clusters"
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
                    if [[ "$thresh" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                        printf "  %.1f SD: %8.1f mm³ (%3d clusters, largest: %6.1f mm³)\n" \
                               "$thresh" "$vol_mm3" "$nclusters" "$largest"
                    else
                        printf "  %-10s: %8.1f mm³ (%3d clusters, largest: %6.1f mm³)\n" \
                               "$thresh" "$vol_mm3" "$nclusters" "$largest"
                    fi
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
    
    local thresholds=()
    discover_threshold_methods "$prefix" thresholds
    local colors=("red" "orange" "yellow" "green" "blue" "cyan" "magenta")
    
    # Create command for viewing all thresholds together
    local fsleyes_cmd="fsleyes $t2flair"
    
    for i in "${!thresholds[@]}"; do
        local mult="${thresholds[$i]}"
        local color="${colors[$((i % ${#colors[@]}))]}"
        local hyper="${prefix}_thresh${mult}.nii.gz"
        local hyper_intensity="${prefix}_thresh${mult}_intensity.nii.gz"
        local hyper_bin="${prefix}_thresh${mult}_bin.nii.gz"
        
        if [ -f "$hyper_intensity" ]; then
            fsleyes_cmd="$fsleyes_cmd $hyper_intensity -cm $color -a 50"
        elif [ -f "$hyper" ]; then
            fsleyes_cmd="$fsleyes_cmd $hyper -cm $color -a 50"
        elif [ -f "$hyper_bin" ]; then
            fsleyes_cmd="$fsleyes_cmd $hyper_bin -cm $color -a 50"
        fi
    done
    
    echo "$fsleyes_cmd" > "${output_dir}/view_all_thresholds.sh"
    chmod +x "${output_dir}/view_all_thresholds.sh"
    
    # Create a composite image showing all discovered thresholds/methods
    local composite_created=false
    local composite_value=1
    for mult in "${thresholds[@]}"; do
        local hyper_bin="${prefix}_thresh${mult}_bin.nii.gz"
        local hyper="${prefix}_thresh${mult}.nii.gz"
        local source_mask=""

        if [ -f "$hyper_bin" ]; then
            source_mask="$hyper_bin"
        elif [ -f "$hyper" ]; then
            source_mask="$hyper"
        else
            continue
        fi

        if [ "$composite_created" = "false" ]; then
            fslmaths "$source_mask" -bin -mul "$composite_value" "${output_dir}/multi_thresh.nii.gz"
            composite_created=true
        else
            fslmaths "$source_mask" -bin -mul "$composite_value" \
                     -add "${output_dir}/multi_thresh.nii.gz" "${output_dir}/multi_thresh.nii.gz"
        fi

        composite_value=$((composite_value + 1))
    done

    if [ "$composite_created" = "true" ]; then
        
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
    # Discrete segmentation labels: use label-aware interpolation (7th arg = is_label)
    if apply_transformation "$segmentation_file" "$reference_file" "$output_file" "$transform_prefix" "NearestNeighbor" "inverse" "true"; then
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

# DEPRECATED / REMOVED: Talairach intensity-abnormality analysis layer.
#
# analyze_region_modality(), analyze_talairach_hyperintensities() and the
# analysis.sh wrapper run_comprehensive_analysis() (Talairach NAWM SD-threshold
# over *_left_medulla*/*_pons* mask globs) were retired here. The live analysis
# path now uses detect_hyperintensities() (FreeSurfer/multi-atlas
# detailed_brainstem regions via find_all_atlas_regions + CSF/PV exclusion +
# per-region GMM) as the PRIMARY engine, with run_comprehensive_analysis()
# (enhanced_registration_validation.sh) as the guarded legacy fallback. No live
# Talairach analysis capability remains.

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
    
    # Brainstem region masks (FreeSurfer / multi-atlas substructures)
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

# REMOVED: create_comprehensive_flair_visualizations() — an orphaned visualization
# helper whose only caller was the retired Talairach run_comprehensive_analysis()
# wrapper. It carried *talairach* mask globs; deleted with the Talairach layer.

# Export functions
export -f _analysis_same_space
export -f _analysis_world_matrix
export -f detect_hyperintensities
export -f create_supratentorial_mask
export -f find_all_atlas_regions
export -f _region_source_from_path
export -f build_csf_exclusion_mask
export -f apply_csf_pv_exclusion
export -f apply_per_region_gmm_analysis
export -f normalize_flair_brainstem_zscore
export -f apply_gaussian_mixture_thresholding
export -f apply_connectivity_weighting
export -f compute_regional_wm_statistics
export -f create_regional_threshold_map
export -f apply_regional_threshold
export -f analyze_clusters
export -f discover_threshold_methods
export -f quantify_volumes
export -f create_multi_threshold_comparison
export -f create_3d_rendering
export -f create_intensity_profiles
export -f transform_segmentation_to_original
export -f create_3d_visualization_script

log_message "Analysis module loaded with enhanced regional adaptive thresholding"
