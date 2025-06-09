#!/usr/bin/env bash
#
# scan_selection.sh - Intelligent scan selection functions
#
# This module contains functions to analyze MRI scan quality and select the best
# scan from multiple candidates using objective quality metrics.
#

# Function to evaluate scan quality and pick the best one based on metrics
evaluate_scan_quality() {
    local scan_path="$1"
    local scan_type="$2"  # T1, FLAIR, etc.
    
    # Initialize score with 0
    local score=0
    
    log_message "Evaluating quality of scan: $scan_path"
    
    # Check file size - larger files often (but not always) indicate better quality
    local file_size=$(stat -f "%z" "$scan_path" 2>/dev/null || stat --format="%s" "$scan_path")
    log_message "  File size: $file_size bytes"
    
    # Check dimensions and voxel size
    local info=$(fslinfo "$scan_path" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_formatted "WARNING" "Could not read file information for $scan_path"
        return 0
    fi
    
    # Extract dimensions
    local dims=($(echo "$info" | grep -E "^dim[1-3]" | awk '{print $2}'))
    log_message "  Dimensions: ${dims[0]}x${dims[1]}x${dims[2]}"
    
    # Extract voxel size
    local pixdims=($(echo "$info" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
    log_message "  Voxel size: ${pixdims[0]}x${pixdims[1]}x${pixdims[2]} mm"
    
    # Calculate volume in voxels
    local volume=$(echo "${dims[0]} * ${dims[1]} * ${dims[2]}" | bc)
    log_message "  Volume (voxels): $volume"
    
    # Score based on file size (normalized by expected size for scan type)
    local file_size_score=0
    case "$scan_type" in
        "T1")
            # T1 scans are typically 5-15 MB
            file_size_score=$(echo "scale=2; $file_size / 1000000" | bc)
            if (( $(echo "$file_size_score > 15" | bc -l) )); then file_size_score=15; fi
            ;;
        "FLAIR")
            # FLAIR scans are typically 3-10 MB
            file_size_score=$(echo "scale=2; $file_size / 1000000" | bc)
            if (( $(echo "$file_size_score > 10" | bc -l) )); then file_size_score=10; fi
            ;;
        *)
            # Default normalization
            file_size_score=$(echo "scale=2; $file_size / 1000000" | bc)
            if (( $(echo "$file_size_score > 10" | bc -l) )); then file_size_score=10; fi
            ;;
    esac
    log_message "  File size score: $file_size_score"
    
    # Score based on dimensions
    local dim_score=0
    local dim_product=$(echo "${dims[0]} * ${dims[1]} * ${dims[2]}" | bc)
    dim_score=$(echo "scale=2; $dim_product / 10000" | bc)
    if (( $(echo "$dim_score > 50" | bc -l) )); then dim_score=50; fi
    log_message "  Dimension score: $dim_score"
    
    # Score based on voxel size (smaller is better)
    local voxel_size=$(echo "${pixdims[0]} * ${pixdims[1]} * ${pixdims[2]}" | bc)
    local voxel_score=$(echo "scale=2; 10 / ($voxel_size + 0.001)" | bc)
    if (( $(echo "$voxel_score > 30" | bc -l) )); then voxel_score=30; fi
    log_message "  Voxel size score: $voxel_score"
    
    # Check acquisition metadata (ORIGINAL vs DERIVED) from JSON sidecar
    local acq_type_score=0
    local json_file="${scan_path%.nii.gz}.json"
    
    if [ -f "$json_file" ]; then
        log_message "  Checking acquisition metadata in $json_file"
        
        # Check if jq is available
        if command -v jq &>/dev/null; then
            # Look for ORIGINAL or DERIVED in ImageType field
            local acq_type=$(jq -r '.ImageType // empty' "$json_file" 2>/dev/null | grep -E "ORIGINAL|DERIVED" | head -1)
            
            if [ -n "$acq_type" ]; then
                log_message "  Acquisition type: $acq_type"
                
                # Give significant bonus to ORIGINAL acquisitions
                if [[ "$acq_type" == *"ORIGINAL"* ]]; then
                    acq_type_score=0
                    log_message "  ORIGINAL acquisition bonus: +30"
                else
                    log_message "  DERIVED acquisition (no bonus)"
                fi
            else
                log_message "  Could not determine acquisition type from JSON"
            fi
        else
            # Fallback to grep if jq is not available
            if grep -q "ORIGINAL" "$json_file"; then
                acq_type_score=0
                log_message "  ORIGINAL acquisition detected (fallback method): +0"
            elif grep -q "DERIVED" "$json_file"; then
                log_message "  DERIVED acquisition detected (fallback method)"
            else
                log_message "  Could not determine acquisition type"
            fi
        fi
    else
        log_message "  No JSON metadata file found: ${json_file}"
    fi
    
    # Add additional metrics if available
    local snr_score=0
    if [ "$scan_type" = "T1" ]; then
        # For T1, check contrast between GM and WM - proxy for tissue contrast
        # Create a temporary mask
        local temp_dir=$(mktemp -d)
        local temp_brain="${temp_dir}/brain.nii.gz"
        
        # Quick brain extraction (this is just for evaluation)
        bet "$scan_path" "$temp_brain" -f 0.3 -v > /dev/null 2>&1
        
        if [ -f "$temp_brain" ]; then
            snr_score = 0 #bypass
        else
            # Run fast for tissue segmentation
            fast -t 1 -n 3 -o "${temp_dir}/fast" "$temp_brain" > /dev/null 2>&1
            
            if [ -f "${temp_dir}/fast_pve_1.nii.gz" ] && [ -f "${temp_dir}/fast_pve_2.nii.gz" ]; then
                # GM is typically label 1, WM is label 2
                local gm_mean=$(fslstats "$scan_path" -k "${temp_dir}/fast_pve_1.nii.gz" -M)
                local wm_mean=$(fslstats "$scan_path" -k "${temp_dir}/fast_pve_2.nii.gz" -M)
                
                # Calculate contrast
                local contrast=$(echo "scale=2; ($wm_mean - $gm_mean) / (($wm_mean + $gm_mean) / 2)" | bc)
                
                # Absolute value
                if (( $(echo "$contrast < 0" | bc -l) )); then
                    contrast=$(echo "scale=2; -1 * $contrast" | bc)
                fi
                
                # Score based on contrast (higher is better for T1)
                snr_score=$(echo "scale=2; $contrast * 20" | bc)
                if (( $(echo "$snr_score > 20" | bc -l) )); then snr_score=20; fi
                log_message "  Tissue contrast score: $snr_score"
            fi
        fi
        
        # Clean up
        rm -rf "$temp_dir"
    fi
    
    # Calculate final score
    score=$(echo "scale=2; $file_size_score + $dim_score + $voxel_score + $snr_score + $acq_type_score" | bc)
    log_formatted "INFO" "Final quality score for $scan_path: $score"
    
    echo "$score"
}

# Function to calculate pixel dimension similarity between two scans
calculate_pixdim_similarity() {
    local scan1="$1"
    local scan2="$2"
    
    # Extract pixel dimensions
    local scan1_info=$(fslinfo "$scan1" 2>/dev/null)
    local scan2_info=$(fslinfo "$scan2" 2>/dev/null)
    
    if [[ -z "$scan1_info" || -z "$scan2_info" ]]; then
        echo "0"  # No similarity if we can't get info
        return
    fi
    
    # Extract pixel dimensions
    local scan1_pixdims=($(echo "$scan1_info" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
    local scan2_pixdims=($(echo "$scan2_info" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
    
    # Calculate per-axis similarity (lower pixdim diff -> higher similarity)
    # Compute absolute differences per axis
    local diff1=$(echo "scale=6; ${scan1_pixdims[0]} - ${scan2_pixdims[0]}" | bc)
    local abs1=$(echo "$diff1" | awk '{print ($1<0)? -$1:$1}')
    local diff2=$(echo "scale=6; ${scan1_pixdims[1]} - ${scan2_pixdims[1]}" | bc)
    local abs2=$(echo "$diff2" | awk '{print ($1<0)? -$1:$1}')
    local diff3=$(echo "scale=6; ${scan1_pixdims[2]} - ${scan2_pixdims[2]}" | bc)
    local abs3=$(echo "$diff3" | awk '{print ($1<0)? -$1:$1}')
    # Compute per-axis similarity scores (max 100)
    local sim1=$(echo "scale=2; 100 / (1 + 10 * $abs1)" | bc)
    local sim2=$(echo "scale=2; 100 / (1 + 10 * $abs2)" | bc)
    local sim3=$(echo "scale=2; 100 / (1 + 10 * $abs3)" | bc)
    # Return the min axis similarity
    local min_sim="$sim1"
    if (( $(echo "$sim2 < $min_sim" | bc -l) )); then min_sim="$sim2"; fi
    if (( $(echo "$sim3 < $min_sim" | bc -l) )); then min_sim="$sim3"; fi
    echo "$min_sim"
}

# Function to calculate voxel aspect ratio (used for registration compatibility)
calculate_voxel_aspect_ratio() {
    local scan="$1"
    
    # Extract pixel dimensions
    local scan_info=$(fslinfo "$scan" 2>/dev/null)
    
    if [[ -z "$scan_info" ]]; then
        echo "1:1:1"  # Default if we can't get info
        return
    fi
    
    # Extract pixel dimensions
    local pixdims=($(echo "$scan_info" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
    
    # Normalize to smallest dimension to get ratio
    local min_dim=$(echo "${pixdims[0]} ${pixdims[1]} ${pixdims[2]}" | tr ' ' '\n' | sort -n | head -1)
    
    # Calculate ratios (avoid division by zero)
    if (( $(echo "$min_dim == 0" | bc -l) )); then
        min_dim=0.001
    fi
    
    local ratio1=$(echo "scale=3; ${pixdims[0]} / $min_dim" | bc)
    local ratio2=$(echo "scale=3; ${pixdims[1]} / $min_dim" | bc)
    local ratio3=$(echo "scale=3; ${pixdims[2]} / $min_dim" | bc)
    
    #echo "$ratio1:$ratio2:$ratio3"
    echo "$ratio1:$ratio2:1"
}

# Function to calculate aspect ratio similarity between two scans
calculate_aspect_ratio_similarity() {
    local scan1="$1"
    local scan2="$2"
    
    # Get aspect ratios
    local ratio1=$(calculate_voxel_aspect_ratio "$scan1")
    local ratio2=$(calculate_voxel_aspect_ratio "$scan2")
    
    # Extract individual ratios
    IFS=':' read -r s1_r1 s1_r2 s1_r3 <<< "$ratio1"
    IFS=':' read -r s2_r1 s2_r2 s2_r3 <<< "$ratio2"
    
    # Calculate differences between aspect ratios
    local diff1=$(echo "scale=6; ($s1_r1 - $s2_r1)^2" | bc)
    local diff2=$(echo "scale=6; ($s1_r2 - $s2_r2)^2" | bc)
    local diff3=$(echo "scale=6; ($s1_r3 - $s2_r3)^2" | bc)
    
    # Calculate Euclidean distance between ratios
    local distance=$(echo "scale=6; sqrt($diff1 + $diff2 + $diff3)" | bc)
    
    # Convert to similarity score (0-100), closer aspect ratios = higher score
    # A perfect match (distance=0) gives maximum score (100)
    local similarity=$(echo "scale=2; 100 / (1 + 10 * $distance)" | bc)
    
    echo "$similarity"
}

# Function to check for exact dimension match
check_exact_dimension_match() {
    local scan1="$1"
    local scan2="$2"
    
    # Extract dimensions
    local scan1_info=$(fslinfo "$scan1" 2>/dev/null)
    local scan2_info=$(fslinfo "$scan2" 2>/dev/null)
    
    if [[ -z "$scan1_info" || -z "$scan2_info" ]]; then
        echo "0"  # No match if we can't get info
        return
    fi
    
    # Extract dimensions
    local scan1_dims=($(echo "$scan1_info" | grep -E "^dim[1-3]" | awk '{print $2}'))
    local scan2_dims=($(echo "$scan2_info" | grep -E "^dim[1-3]" | awk '{print $2}'))
    
    # Check if dimensions match exactly
    if [[ "${scan1_dims[0]}" -eq "${scan2_dims[0]}" &&
          "${scan1_dims[1]}" -eq "${scan2_dims[1]}" &&
          "${scan1_dims[2]}" -eq "${scan2_dims[2]}" ]]; then
        echo "100"  # Perfect match
    else
        echo "0"    # No match
    fi
}

# Function to calculate average resolution (smaller value = higher resolution)
calculate_average_resolution() {
    local scan="$1"
    
    # Extract pixel dimensions
    local scan_info=$(fslinfo "$scan" 2>/dev/null)
    
    if [[ -z "$scan_info" ]]; then
        echo "999"  # High value (poor resolution) if we can't get info
        return
    fi
    
    # Extract pixel dimensions
    local pixdims=($(echo "$scan_info" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
    
    # Calculate average resolution (mm)
    local avg_res=$(echo "scale=6; (${pixdims[0]} + ${pixdims[1]} + ${pixdims[2]}) / 3" | bc)
    
    echo "$avg_res"
}

# Function to select best scan based on quality metrics with multiple selection modes
select_best_scan() {
    local scan_type="$1"  # T1, FLAIR, etc.
    local scan_pattern="$2"  # File pattern (e.g., "T1_*.nii.gz")
    local directory="$3"  # Directory to search in
    local reference_scan="${4:-}"  # Optional reference scan to match resolution with
    local selection_mode="${5:-registration_optimized}"  # Selection mode (highest_resolution, registration_optimized, matched_dimensions, interactive)
    
    log_message "Selecting best $scan_type scan matching pattern '$scan_pattern' in $directory (mode: $selection_mode)"
    
    # Find all matching scans
    local scans=($(find "$directory" -name "$scan_pattern" | sort))
    local scan_count=${#scans[@]}
    
    if [ $scan_count -eq 0 ]; then
        log_formatted "WARNING" "No $scan_type scans found matching pattern $scan_pattern"
        echo ""
        return 1
    elif [ $scan_count -eq 1 ]; then
        log_message "Only one $scan_type scan found, using it: ${scans[0]}"
        echo "${scans[0]}"
        return 0
    fi
    
    log_message "Found $scan_count $scan_type scans, evaluating quality..."
    
    # Create a temporary file to store scores
    local temp_file=$(mktemp)
    
    # Create array to store scan info for interactive mode
    local scan_info_array=()

    # Process each scan based on selection mode
    for scan in "${scans[@]}"; do
        # Calculate common metrics
        local quality_score=$(evaluate_scan_quality "$scan" "$scan_type")
        local avg_res=$(calculate_average_resolution "$scan")
        local res_score=$(echo "scale=2; 50 / ($avg_res + 0.001)" | bc)
        
        # Get acquisition type
        local acq_type="Unknown"
        local json_file="${scan%.nii.gz}.json"
        if [ -f "$json_file" ] && command -v jq &>/dev/null; then
            acq_type=$(jq -r '.ImageType // empty' "$json_file" 2>/dev/null | grep -E "ORIGINAL|DERIVED" | head -1 || echo "Unknown")
        elif [ -f "$json_file" ]; then
            acq_type=$(grep -E "ORIGINAL|DERIVED" "$json_file" | head -1 | sed 's/.*"\(ORIGINAL\|DERIVED\)".*/\1/' || echo "Unknown")
        fi

        # Initialize scores for different modes
        local aspect_ratio_score=0
        local dimension_match_score=0
        local final_score=0
        local aspect_ratio=""
        local ref_aspect_ratio=""
        
        # Calculate special scores if reference scan is provided
        if [ -n "$reference_scan" ]; then
            aspect_ratio_score=$(calculate_aspect_ratio_similarity "$scan" "$reference_scan")
            dimension_match_score=$(check_exact_dimension_match "$scan" "$reference_scan")
            
            # Get aspect ratio information for display
            aspect_ratio=$(calculate_voxel_aspect_ratio "$scan")
            ref_aspect_ratio=$(calculate_voxel_aspect_ratio "$reference_scan")
        fi

        # Calculate final score based on selection mode
        case "$selection_mode" in
            "original")
                # Strongly prioritize ORIGINAL acquisitions above all else
                # Apply a massive bonus to ORIGINAL scans to ensure they're selected
                if [[ "$acq_type" == *"ORIGINAL"* ]]; then
                    # Start with a very high base score for ORIGINAL scans
                    final_score=0
                    # Add quality metrics as tie-breakers between ORIGINAL scans
                    final_score=$(echo "scale=2; $final_score + $quality_score + $res_score" | bc)
                    log_message "  ORIGINAL acquisition priority mode: massive bonus applied"
                else
                    # Very low score for DERIVED scans in this mode
                    final_score=$(echo "scale=2; $quality_score / 10" | bc)
                    log_message "  ORIGINAL acquisition priority mode: DERIVED scan downgraded"
                fi
                ;;
                
            "highest_resolution")
                # Prioritize high resolution (original behavior)
                final_score=$(echo "scale=2; $quality_score + $res_score * 2" | bc)
                ;;
                
            "registration_optimized")
                # Prioritize aspect ratio similarity for registration
                if [ -n "$reference_scan" ]; then
                    final_score=$(echo "scale=2; $quality_score + $res_score + $aspect_ratio_score * 2" | bc)
                else
                    final_score=$(echo "scale=2; $quality_score + $res_score * 2" | bc)
                fi
                ;;
                
            "matched_dimensions")
                # Prioritize exact dimension matches
                if [ -n "$reference_scan" ]; then
                    final_score=$(echo "scale=2; $quality_score + $dimension_match_score * 3" | bc)
                else
                    final_score=$(echo "scale=2; $quality_score + $res_score" | bc)
                fi
                ;;
                
            "interactive"|*)
                # For interactive mode, calculate balanced score for initial sorting
                if [ -n "$reference_scan" ]; then
                    final_score=$(echo "scale=2; $quality_score + $res_score + $aspect_ratio_score" | bc)
                else
                    final_score=$(echo "scale=2; $quality_score + $res_score" | bc)
                fi
                ;;
        esac

        # Store detailed scan info for display in interactive mode
        if [ "$selection_mode" = "interactive" ]; then
            # Get dimensions for display
            local dims=($(fslinfo "$scan" | grep -E "^dim[1-3]" | awk '{print $2}'))
            local pixdims=($(fslinfo "$scan" | grep -E "^pixdim[1-3]" | awk '{print $2}'))
            
            # Create info string with all details
            local info_str="$final_score|$scan|$acq_type|${dims[0]}x${dims[1]}x${dims[2]}|${pixdims[0]}x${pixdims[1]}x${pixdims[2]}|$quality_score|$res_score"
            
            # Add reference-based metrics if available
            if [ -n "$reference_scan" ]; then
                info_str="$info_str|$aspect_ratio_score|$dimension_match_score|$aspect_ratio"
            fi
            
            scan_info_array+=("$info_str")
        fi

        # For non-interactive modes, write scores to temp file
        if [ "$selection_mode" != "interactive" ]; then
            # Log detailed scan information
            if [ -n "$reference_scan" ]; then
                log_message "Scan: $scan, Acquisition: $acq_type, Quality: $quality_score, Res: $avg_res mm (Score: $res_score), Aspect Ratio: $aspect_ratio, Similarity: $aspect_ratio_score, Dim Match: $dimension_match_score, Final: $final_score"
            else
                log_message "Scan: $scan, Acquisition: $acq_type, Quality: $quality_score, Res: $avg_res mm (Score: $res_score), Final: $final_score"
            fi
            
            # Write score to temp file
            echo "$final_score $scan" >> "$temp_file"
        fi
    done
    
    # Handle interactive mode
    if [ "$selection_mode" = "interactive" ]; then
        # Sort scan info by score in descending order
        IFS=$'\n' sorted_scans=($(sort -t '|' -k1,1nr <<<"${scan_info_array[*]}"))
        unset IFS
        
        # Display scan options with information
        log_formatted "INFO" "===== INTERACTIVE SCAN SELECTION ====="
        log_message "Please select the best $scan_type scan from the following options:"
        log_message ""
        log_message "------------------------------------------------------------------------------------------------------------------------"
        log_message "                                            SCAN OPTIONS                                                                 "
        log_message "------------------------------------------------------------------------------------------------------------------------"
        
        # Display header line
        if [ -n "$reference_scan" ]; then
            printf "%-3s | %-40s | %-8s | %-15s | %-20s | %-7s | %-20s\n" \
                "#" "Filename" "Type" "Dimensions" "Voxel Size (mm)" "Score" "Aspect Ratio" >&2
        else
            printf "%-3s | %-40s | %-8s | %-15s | %-20s | %-7s\n" \
                "#" "Filename" "Type" "Dimensions" "Voxel Size (mm)" "Score" >&2
        fi
        
        log_message "------------------------------------------------------------------------------------------------------------------------"
        
        # Display each scan option
        local i=1
        for info in "${sorted_scans[@]}"; do
            IFS='|' read -r score scan acq_type dims voxel_size quality_score res_score aspect_ratio_score dimension_match_score aspect_ratio <<< "$info"
            
            # Format basename to shorten display
            local basename=$(basename "$scan")
            
            if [ -n "$reference_scan" ]; then
                printf "%-3s | %-40s | %-8s | %-15s | %-20s | %-7s | %-20s\n" \
                    "$i" "$basename" "$acq_type" "$dims" "$voxel_size" "$score" "$aspect_ratio">&2
            else
                printf "%-3s | %-40s | %-8s | %-15s | %-20s | %-7s\n" \
                    "$i" "$basename" "$acq_type" "$dims" "$voxel_size" "$score">&2
            fi
            
            i=$((i+1))
        done
        log_message "------------------------------------------------------------------------------------------------------------------------"
        
        # Add recommendation based on mode
        local recommended_idx=1  # Default to highest score
        
        log_message ""
        log_message "Reference scan: $(basename "$reference_scan")"
        log_message "Recommendations:"
        log_message "- For highest resolution: Option 1"
        
        # Find best aspect ratio match
        if [ -n "$reference_scan" ]; then
            local best_reg_idx=1
            local max_aspect_score=0
            i=1
            for info in "${sorted_scans[@]}"; do
                IFS='|' read -r score scan acq_type dims voxel_size quality_score res_score aspect_ratio_score dimension_match_score aspect_ratio <<< "$info"
                if (( $(echo "$aspect_ratio_score > $max_aspect_score" | bc -l) )); then
                    max_aspect_score=$aspect_ratio_score
                    best_reg_idx=$i
                fi
                i=$((i+1))
            done
            log_message "- For best registration compatibility: Option $best_reg_idx"
            
            # Find exact dimension match if any
            local exact_match_idx=0
            i=1
            for info in "${sorted_scans[@]}"; do
                IFS='|' read -r score scan acq_type dims voxel_size quality_score res_score aspect_ratio_score dimension_match_score aspect_ratio <<< "$info"
                if (( $(echo "$dimension_match_score > 50" | bc -l) )); then
                    exact_match_idx=$i
                    break
                fi
                i=$((i+1))
            done
            
            if [ $exact_match_idx -ne 0 ]; then
                log_message "- For exact dimension matching: Option $exact_match_idx"
            fi
        fi
        
        # Prompt user for selection
        log_message "Enter selection (1-${#sorted_scans[@]}): "
        read -r selection
        
        # Validate selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#sorted_scans[@]}" ]; then
            log_formatted "ERROR" "Invalid selection. Exiting"
            return 1
        fi
        
        # Get selected scan
        IFS='|' read -r score selected_scan rest <<< "${sorted_scans[$((selection-1))]}"
        log_formatted "SUCCESS" "Selected scan: $selected_scan"
        
        # Return selected scan
        echo "$selected_scan"
        return 0
    fi
    
    # For non-interactive modes, sort and select the best scan
    # Sort by score (descending) and select the best one
    local best_scan=$(sort -rn "$temp_file" | head -1 | cut -d' ' -f2-)
    local best_score=$(sort -rn "$temp_file" | head -1 | cut -d' ' -f1)
    
    # Clean up
    rm -f "$temp_file"
    
    # Get acquisition type for the best scan
    local best_acq_type="Unknown"
    local best_json="${best_scan%.nii.gz}.json"
    if [ -f "$best_json" ] && command -v jq &>/dev/null; then
        best_acq_type=$(jq -r '.ImageType // empty' "$best_json" 2>/dev/null | grep -E "ORIGINAL|DERIVED" | head -1 || echo "Unknown")
    elif [ -f "$best_json" ]; then
        best_acq_type=$(grep -E "ORIGINAL|DERIVED" "$best_json" | head -1 | sed 's/.*"\(ORIGINAL\|DERIVED\)".*/\1/' || echo "Unknown")
    fi
    
    # Get voxel aspect ratio and selection mode details for output
    local aspect_info=""
    local mode_info=" using mode '$selection_mode'"
    
    if [ -n "$reference_scan" ]; then
        local aspect_ratio=$(calculate_voxel_aspect_ratio "$best_scan")
        local aspect_score=$(calculate_aspect_ratio_similarity "$best_scan" "$reference_scan")
        aspect_info=", Aspect Ratio: $aspect_ratio, Similarity: $aspect_score"
    fi
    
    # Add selection mode-specific details
    if [[ "$selection_mode" == "original" ]]; then
        if [[ "$best_acq_type" == *"ORIGINAL"* ]]; then
            mode_info=" using ORIGINAL-only mode (ORIGINAL acquisition found)"
        else
            mode_info=" using ORIGINAL-only mode (WARNING: no ORIGINAL acquisition found)"
        fi
    fi

    log_formatted "SUCCESS" "Selected best $scan_type scan with score $best_score: $best_scan ($best_acq_type)$aspect_info$mode_info"
    
    # Return the path to the best scan
    echo "$best_scan"
}

# Function to analyze DICOM headers for scan selection
analyze_dicom_headers() {
    local dicom_dir="$1"
    local output_file="$2"
    
    log_message "Analyzing DICOM headers in $dicom_dir"
    
    # Check if dcmdump is available
    if ! command -v dcmdump &>/dev/null; then
        log_formatted "WARNING" "dcmdump not available, cannot analyze DICOM headers"
        return 1
    fi
    
    # Find a sample DICOM file
    local sample_file=$(find "$dicom_dir" -type f | head -1)
    if [ ! -f "$sample_file" ]; then
        log_formatted "ERROR" "No files found in $dicom_dir"
        return 1
    fi
    
    # Extract key header fields using dcmdump
    local header_info=$(dcmdump "$sample_file" 2>/dev/null | 
        grep -E "(0008,0070)|(0008,1090)|(0018,0050)|(0018,0080)|(0018,0081)|(0018,0087)|(0018,1050)|(0018,1030)" |
        sed 's/.*\[\(.*\)\].*/\1/')
    
    # Create header analysis file
    mkdir -p "$(dirname "$output_file")"
    {
        echo "DICOM Header Analysis"
        echo "====================="
        echo "Sample file: $sample_file"
        echo ""
        echo "Manufacturer: $(echo "$header_info" | grep -m1 "Manufacturer" || echo "Unknown")"
        echo "Model: $(echo "$header_info" | grep -m1 "Model" || echo "Unknown")"
        echo "Slice Thickness: $(echo "$header_info" | grep -m1 "SliceThickness" || echo "Unknown")"
        echo "TR: $(echo "$header_info" | grep -m1 "RepetitionTime" || echo "Unknown")"
        echo "TE: $(echo "$header_info" | grep -m1 "EchoTime" || echo "Unknown")"
        echo "Flip Angle: $(echo "$header_info" | grep -m1 "FlipAngle" || echo "Unknown")"
        echo "Sequence: $(echo "$header_info" | grep -m1 "ProtocolName" || echo "Unknown")"
    } > "$output_file"
    
    log_message "DICOM header analysis saved to $output_file"
    return 0
}

# Export functions
export -f evaluate_scan_quality
export -f calculate_pixdim_similarity
export -f calculate_average_resolution
export -f calculate_voxel_aspect_ratio
export -f calculate_aspect_ratio_similarity
export -f check_exact_dimension_match
export -f select_best_scan
export -f analyze_dicom_headers

log_message "Scan selection module loaded with enhanced registration-aware selection modes"
