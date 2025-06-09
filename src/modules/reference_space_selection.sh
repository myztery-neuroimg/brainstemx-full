#!/usr/bin/env bash
#
# reference_space_selection.sh - Adaptive reference space selection logic
#
# This module implements the foundational decision that determines whether to use
# T1-MPRAGE or T2-SPACE-FLAIR as the reference space for the entire pipeline.
#
# Decision criteria (priority order):
# 1. ORIGINAL acquisition (priority weight: +10)
# 2. 3D isotropic vs 2D multi-slice (+300)
# 3. Spatial resolution (+200)
# 4. Image quality metrics (+150)
# 5. Modality-specific suitability (+100)
#

# Source environment and existing scan selection functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/environment.sh"

# Import existing scan selection functions if available
if [ -f "${SCRIPT_DIR}/../scan_selection.sh" ]; then
    source "${SCRIPT_DIR}/../scan_selection.sh"
fi

# Configuration parameters for reference space selection
export REFERENCE_SPACE_SELECTION_MODE="${REFERENCE_SPACE_SELECTION_MODE:-adaptive}"
export ORIGINAL_ACQUISITION_WEIGHT="${ORIGINAL_ACQUISITION_WEIGHT:-0}"
export RESOLUTION_WEIGHT="${RESOLUTION_WEIGHT:-200}"
export QUALITY_WEIGHT="${QUALITY_WEIGHT:-150}"
export DIMENSIONALITY_WEIGHT="${DIMENSIONALITY_WEIGHT:-300}"
export MODALITY_SPECIFIC_WEIGHT="${MODALITY_SPECIFIC_WEIGHT:-100}"

# FLAIR-specific thresholds
export FLAIR_MIN_RESOLUTION="${FLAIR_MIN_RESOLUTION:-0.8}"
export FLAIR_REQUIRE_3D="${FLAIR_REQUIRE_3D:-true}"
export FLAIR_MIN_QUALITY_SCORE="${FLAIR_MIN_QUALITY_SCORE:-60}"

# T1 fallback criteria
export T1_FALLBACK_ENABLED="${T1_FALLBACK_ENABLED:-true}"
export T1_MIN_ACCEPTABLE_QUALITY="${T1_MIN_ACCEPTABLE_QUALITY:-40}"

# Main function to select optimal reference space
select_optimal_reference_space() {
    local dicom_dir="$1"
    local extraction_dir="$2"
    local mode="${3:-$REFERENCE_SPACE_SELECTION_MODE}"
    
    log_formatted "INFO" "===== ADAPTIVE REFERENCE SPACE SELECTION ====="
    log_message "DICOM Directory: $dicom_dir"
    log_message "Extraction Directory: $extraction_dir"
    log_message "Selection Mode: $mode"
    
    # Phase 1: Discover and analyze ORIGINAL sequences
    log_message "Phase 1: Discovering ORIGINAL sequences..."
    local t1_candidates=()
    local flair_candidates=()
    
    #	discover_original_sequences "$extraction_dir" t1_candidates flair_candidates
    discover_original_sequences "$extraction_dir" t1_candidates flair_candidates
    
    # Phase 2: Comprehensive quality assessment
    log_message "Phase 2: Comprehensive quality assessment..."
    local t1_analysis=""
    local flair_analysis=""
    
    if [ ${#t1_candidates[@]} -gt 0 ]; then
        t1_analysis=$(analyze_sequence_quality "${t1_candidates[@]}")
    fi
    
    if [ ${#flair_candidates[@]} -gt 0 ]; then
        flair_analysis=$(analyze_sequence_quality "${flair_candidates[@]}")
    fi
    
    # Phase 3: Decision matrix generation and selection
    log_message "Phase 3: Decision matrix generation..."
    local decision_result
    decision_result=$(make_reference_space_decision "$t1_analysis" "$flair_analysis" "$mode")
    
    # Phase 4: Present decision (interactive mode) or log decision (automated mode)
    if [ "$mode" = "interactive" ]; then
        decision_result=$(present_interactive_decision_matrix "$t1_analysis" "$flair_analysis" "$decision_result")
    else
        log_decision_rationale "$decision_result"
    fi
    
    # Return: modality|file|rationale
    echo "$decision_result"
}

# Discover ORIGINAL sequences from extracted NIfTI files
discover_original_sequences() {
    local extraction_dir="$1"
    local -n t1_ref=$2
    local -n flair_ref=$3
    
    # Find potential T1 sequences (broader patterns) - support both .nii and .nii.gz
    #local all_t1_files=($(find "$extraction_dir" \( -name "*T1*.nii.gz" -o -name "*T1*.nii" \) -o \( -name "*MPR*.nii.gz" -o -name "*MPR*.nii" \) -o \( -name "*MPR*.nii.gz" -o -name "*MPR*.nii" \) -o \( -name "*t1*.nii.gz" -o -name "*t1*.nii" \) 2>/dev/null))
    local all_t1_files=($(find "$extraction_dir" \( -name "*T1*14.nii.gz" -o -name "*T1*14.nii" \) 2>/dev/null))
    
    # Find potential FLAIR sequences (broader patterns) - support both .nii and .nii.gz
    #local all_flair_files=($(find "$extraction_dir" \( -name "*FLAIR*.nii.gz" -o -name "*FLAIR*.nii" \) -o \( -name "*flair*.nii.gz" -o -name "*flair*.nii" \) -o \( -name "*T2*SPACE*.nii.gz" -o -name "*T2*SPACE*.nii" \) 2>/dev/null))
    local all_flair_files=($(find "$extraction_dir" \( -name "*SPACE*FLAIR*1035.nii.gz" -o -name "*SPACE*FLAIR*1035.nii" \) 2>/dev/null))
    
    log_message "Found ${#all_t1_files[@]} potential T1 files"
    log_message "Found ${#all_flair_files[@]} potential FLAIR files"
    
    # Debug: Show what files are actually available
    if [ ${#all_t1_files[@]} -eq 0 ] || [ ${#all_flair_files[@]} -eq 0 ]; then
        log_message "No T1 or FLAIR files found. Available files in extraction directory:"
        find "$extraction_dir" -name "*.nii.gz" 2>/dev/null | head -10 | while read -r file; do
            log_message "  $(basename "$file")"
        done
        
        log_message "Trying broader search patterns..."
        local any_nifti_files=($(find "$extraction_dir" \( -name "*T2*.nii.gz" -o -name "*.nii" \) 2>/dev/null))
        log_message "Total NIfTI files found: ${#any_nifti_files[@]}"
        
    fi
    
    t1_ref="$all_t1_files"
    flair_ref="$all_flair_files"

    # Filter for ORIGINAL acquisitions (exclude DERIVED)
    #for file in "${all_t1_files[@]}"; do
    #    if is_original_acquisition "$file"; then
    #        t1_ref+=("$file")
    #    fi
    #done
    #
    #for file in "${all_flair_files[@]}"; do
    #    if is_original_acquisition "$file"; then
    #        flair_ref+=("$file")
    #    fi
    #done
    #
    #log_message "Filtered to ${#t1_ref[@]} ORIGINAL T1 files"
    #log_message "Filtered to ${#flair_ref[@]} ORIGINAL FLAIR files"
}

# Check if a file represents an ORIGINAL (not DERIVED) acquisition
is_original_acquisition() {
    local file="$1"
    local filename=$(basename "$file")
    
    # Primary method: Check JSON metadata for ImageType field
    local json_file=""
    if [[ "$file" == *.nii.gz ]]; then
        json_file="${file%.nii.gz}.json"
    elif [[ "$file" == *.nii ]]; then
        json_file="${file%.nii}.json"
    fi
    
    if [ -n "$json_file" ] && [ -f "$json_file" ]; then
        # Check if "ORIGINAL" is present in the ImageType array
        if command -v jq &> /dev/null; then
            # Use jq for proper JSON parsing
            local has_original=$(jq -r '.ImageType // [] | contains(["ORIGINAL"])' "$json_file" 2>/dev/null)
            if [ "$has_original" = "true" ]; then
                return 0  # ORIGINAL
            elif [ "$has_original" = "false" ]; then
                return 1  # DERIVED or other
            fi
            # If jq fails or returns null, fall through to alternative methods
        else
            # Fallback: grep for "ORIGINAL" in ImageType array
            if grep -q '"ImageType".*\[.*"ORIGINAL"' "$json_file" 2>/dev/null; then
                return 0  # ORIGINAL
            elif grep -q '"ImageType"' "$json_file" 2>/dev/null; then
                # ImageType field exists but doesn't contain ORIGINAL
                return 1  # DERIVED or other
            fi
            # If no ImageType field found, fall through to filename patterns
        fi
    fi
    
    # Secondary method: Check filename patterns that typically indicate DERIVED sequences
    if [[ "$filename" == *"DERIVED"* ]] || \
       [[ "$filename" == *"_reg"* ]] || \
       [[ "$filename" == *"_corr"* ]] || \
       [[ "$filename" == *"_processed"* ]] || \
       [[ "$filename" == *"_std"* ]] || \
       [[ "$filename" == *"_brain"* ]]; then
        return 1  # DERIVED
    fi
    
    # Default: assume ORIGINAL if no clear indicators of DERIVED processing
    # This is conservative - better to include a potential original than exclude it
    return 0  # ORIGINAL
}

# Analyze sequence quality and characteristics
analyze_sequence_quality() {
    local files=("$@")
    local best_file=""
    local best_score=0
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "NONE|||0|No sequences available"
        return 0
    fi
    
    for file in "${files[@]}"; do
        local score=0
        local details=""
        
        # Basic file validation
        if [ ! -f "$file" ] || [ ! -r "$file" ]; then
            continue
        fi
        
        # Get image characteristics using FSL if available
        if command -v fslinfo &> /dev/null; then
            local dims=($(fslinfo "$file" 2>/dev/null | grep -E "^dim[1-3]" | awk '{print $2}'))
            local pixdims=($(fslinfo "$file" 2>/dev/null | grep -E "^pixdim[1-3]" | awk '{print $2}'))
            
            if [ ${#dims[@]} -ge 3 ] && [ ${#pixdims[@]} -ge 3 ]; then
                # Calculate quality metrics
                local resolution_score=$(calculate_resolution_score "${pixdims[@]}")
                local dimension_score=$(calculate_dimension_score "${dims[@]}")
                local isotropy_score=$(calculate_isotropy_score "${pixdims[@]}")
                
                score=$(echo "scale=0; ($resolution_score + $dimension_score + $isotropy_score)" | bc -l 2>/dev/null || echo "0")
                details="res:${pixdims[0]}x${pixdims[1]}x${pixdims[2]},dims:${dims[0]}x${dims[1]}x${dims[2]}"
            fi
        fi
        
        # ORIGINAL acquisition bonus
        if is_original_acquisition "$file"; then
            score=$(echo "scale=0; ($score + $ORIGINAL_ACQUISITION_WEIGHT)" | bc -l 2>/dev/null || echo "$ORIGINAL_ACQUISITION_WEIGHT")
            details="${details},ORIGINAL"
        else
            details="${details},DERIVED"
        fi
        
        # Track best file
        if [ "$(echo "$score > $best_score" | bc -l 2>/dev/null)" = "1" ]; then
            best_score=$score
            best_file="$file"
        fi
        
        log_message "  $(basename "$file"): score=$score ($details)"
    done
    
    # Return: filename|resolution|dimensions|score|details
    if [ -n "$best_file" ]; then
        local dims=($(fslinfo "$best_file" 2>/dev/null | grep -E "^dim[1-3]" | awk '{print $2}' 2>/dev/null || echo "0 0 0"))
        local pixdims=($(fslinfo "$best_file" 2>/dev/null | grep -E "^pixdim[1-3]" | awk '{print $2}' 2>/dev/null || echo "1.0 1.0 1.0"))
        
        echo "$best_file|${pixdims[0]}x${pixdims[1]}x${pixdims[2]}|${dims[0]}x${dims[1]}x${dims[2]}|$best_score|ORIGINAL"
    else
        echo "NONE|||0|No valid sequences"
    fi
}

# Calculate resolution-based quality score
calculate_resolution_score() {
    local pixdims=("$@")
    
    if [ ${#pixdims[@]} -lt 3 ]; then
        echo "0"
        return
    fi
    
    # Calculate average resolution (lower is better)
    local avg_res=$(echo "scale=3; (${pixdims[0]} + ${pixdims[1]} + ${pixdims[2]}) / 3" | bc -l 2>/dev/null || echo "1.0")
    
    # Convert to score (higher is better)
    local score=$(echo "scale=0; $RESOLUTION_WEIGHT / ($avg_res + 0.1)" | bc -l 2>/dev/null || echo "100")
    
    echo "$score"
}

# Calculate dimension-based quality score  
calculate_dimension_score() {
    local dims=("$@")
    
    if [ ${#dims[@]} -lt 3 ]; then
        echo "0"
        return
    fi
    
    # Higher dimensions generally better (more detail)
    local total_voxels=$((dims[0] * dims[1] * dims[2]))
    local score=$(echo "scale=0; sqrt($total_voxels) / 10" | bc -l 2>/dev/null || echo "100")
    
    # Cap the score to prevent extremely large values
    if [ "$(echo "$score > 500" | bc -l 2>/dev/null)" = "1" ]; then
        score=500
    fi
    
    echo "$score"
}

# Calculate isotropy-based quality score
calculate_isotropy_score() {
    local pixdims=("$@")
    
    if [ ${#pixdims[@]} -lt 3 ]; then
        echo "0"
        return
    fi
    
    # Calculate isotropy (how close voxels are to cubic)
    local min_dim=$(echo "${pixdims[0]} ${pixdims[1]} ${pixdims[2]}" | tr ' ' '\n' | sort -n | head -1)
    local max_dim=$(echo "${pixdims[0]} ${pixdims[1]} ${pixdims[2]}" | tr ' ' '\n' | sort -n | tail -1)
    
    if [ "$(echo "$max_dim > 0" | bc -l 2>/dev/null)" = "1" ]; then
        local isotropy_ratio=$(echo "scale=3; $min_dim / $max_dim" | bc -l 2>/dev/null || echo "0.5")
        local score=$(echo "scale=0; $isotropy_ratio * $DIMENSIONALITY_WEIGHT" | bc -l 2>/dev/null || echo "150")
        echo "$score"
    else
        echo "0"
    fi
}

# Make the core reference space decision
make_reference_space_decision() {
    local t1_analysis="$1"
    local flair_analysis="$2"
    local mode="$3"
    
    # Parse analysis results with proper defaults
    local t1_file=$(echo "$t1_analysis" | cut -d'|' -f1)
    local t1_score=$(echo "$t1_analysis" | cut -d'|' -f4)
    local flair_file=$(echo "$flair_analysis" | cut -d'|' -f1)
    local flair_score=$(echo "$flair_analysis" | cut -d'|' -f4)
    
    # Set defaults for empty scores to avoid arithmetic errors
    t1_score="${t1_score:-0}"
    flair_score="${flair_score:-0}"
    
    # Ensure scores are numeric (allow decimals)
    if ! [[ "$t1_score" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        t1_score=0
    fi
    if ! [[ "$flair_score" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        flair_score=0
    fi
    
    log_message "Decision analysis:"
    log_message "  T1 best: $(basename "$t1_file" 2>/dev/null || echo "NONE") (score: $t1_score)"
    log_message "  FLAIR best: $(basename "$flair_file" 2>/dev/null || echo "NONE") (score: $flair_score)"
    
    # Handle special modes
    case "$mode" in
        "t1_priority")
            if [ "$t1_file" != "NONE" ]; then
                echo "T1|$t1_file|T1 priority mode selected"
                return 0
            fi
            ;;
        "flair_priority")
            if [ "$flair_file" != "NONE" ]; then
                echo "FLAIR|$flair_file|FLAIR priority mode selected"
                return 0
            fi
            ;;
    esac
    
    # Adaptive decision logic
    if [ "$t1_file" = "NONE" ] && [ "$flair_file" = "NONE" ]; then
        echo "ERROR||No suitable sequences found"
        return 1
    elif [ "$t1_file" = "NONE" ]; then
        echo "FLAIR|$flair_file|Only FLAIR available"
    elif [ "$flair_file" = "NONE" ]; then
        echo "T1|$t1_file|Only T1 available"
    else
        # Both available - compare scores
        if [ "$(echo "$flair_score > ($t1_score + 50)" | bc -l 2>/dev/null)" = "1" ]; then
            # FLAIR demonstrates superior characteristics
            local flair_res=$(echo "$flair_analysis" | cut -d'|' -f2)
            echo "FLAIR|$flair_file|Superior FLAIR characteristics (score: $flair_score vs $t1_score, resolution: $flair_res)"
        elif [ "$(echo "$t1_score > ($flair_score + 50)" | bc -l 2>/dev/null)" = "1" ]; then
            # T1 demonstrates superior characteristics
            echo "T1|$t1_file|Superior T1 characteristics (score: $t1_score vs $flair_score)"
        else
            # Similar scores - default to T1 structural gold standard (easier alignment, superior structural information)
            echo "T1|$t1_file|T1 structural gold standard (similar scores: T1=$t1_score, FLAIR=$flair_score)"
        fi
    fi
}

# Present interactive decision matrix to user
present_interactive_decision_matrix() {
    local t1_analysis="$1"
    local flair_analysis="$2"
    local auto_decision="$3"
    
    echo ""
    echo "========== ADAPTIVE REFERENCE SPACE SELECTION =========="
    echo ""
    
    # Display T1 analysis
    if [ "$(echo "$t1_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        echo "ORIGINAL T1-MPRAGE Sequences Available:"
        echo "┌─────────────────────┬─────────────┬─────────────┬─────────┬─────────┐"
        echo "│ Filename            │ Resolution  │ Dimensions  │ Score   │ Type    │"
        echo "├─────────────────────┼─────────────┼─────────────┼─────────┼─────────┤"
        local t1_file=$(echo "$t1_analysis" | cut -d'|' -f1)
        local t1_res=$(echo "$t1_analysis" | cut -d'|' -f2)
        local t1_dims=$(echo "$t1_analysis" | cut -d'|' -f3)
        local t1_score=$(echo "$t1_analysis" | cut -d'|' -f4)
        local t1_type=$(echo "$t1_analysis" | cut -d'|' -f5)
        printf "│ %-19s │ %-11s │ %-11s │ %-7s │ %-7s │\n" \
            "$(basename "$t1_file" | cut -c1-19)" "$t1_res" "$t1_dims" "$t1_score" "$t1_type"
        echo "└─────────────────────┴─────────────┴─────────────┴─────────┴─────────┘"
    else
        echo "❌ No ORIGINAL T1-MPRAGE sequences found"
    fi
    
    echo ""
    
    # Display FLAIR analysis
    if [ "$(echo "$flair_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        echo "ORIGINAL T2-SPACE-FLAIR Sequences Available:"
        echo "┌─────────────────────┬─────────────┬─────────────┬─────────┬─────────┐"
        echo "│ Filename            │ Resolution  │ Dimensions  │ Score   │ Type    │"
        echo "├─────────────────────┼─────────────┼─────────────┼─────────┼─────────┤"
        local flair_file=$(echo "$flair_analysis" | cut -d'|' -f1)
        local flair_res=$(echo "$flair_analysis" | cut -d'|' -f2)
        local flair_dims=$(echo "$flair_analysis" | cut -d'|' -f3)
        local flair_score=$(echo "$flair_analysis" | cut -d'|' -f4)
        local flair_type=$(echo "$flair_analysis" | cut -d'|' -f5)
        printf "│ %-19s │ %-11s │ %-11s │ %-7s │ %-7s │\n" \
            "$(basename "$flair_file" | cut -c1-19)" "$flair_res" "$flair_dims" "$flair_score" "$flair_type"
        echo "└─────────────────────┴─────────────┴─────────────┴─────────┴─────────┘"
    else
        echo "❌ No ORIGINAL T2-SPACE-FLAIR sequences found"
    fi
    
    echo ""
    
    # Display recommendation
    local recommended_modality=$(echo "$auto_decision" | cut -d'|' -f1)
    local rationale=$(echo "$auto_decision" | cut -d'|' -f3)
    
    echo "🏆 SYSTEM RECOMMENDATION: $recommended_modality"
    echo "📋 RATIONALE: $rationale"
    echo ""
    
    # Get user decision
    echo "Select Reference Space:"
    echo "[1] Accept recommendation ($recommended_modality)"
    if [ "$(echo "$t1_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        echo "[2] Use T1-MPRAGE"
    fi
    if [ "$(echo "$flair_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        echo "[3] Use T2-SPACE-FLAIR"
    fi
    echo "[4] Show detailed comparison"
    echo ""
    echo -n "Enter selection (1-4): "
    read -r selection
    
    case "$selection" in
        "1")
            echo "$auto_decision"
            ;;
        "2")
            if [ "$(echo "$t1_analysis" | cut -d'|' -f1)" != "NONE" ]; then
                local t1_file=$(echo "$t1_analysis" | cut -d'|' -f1)
                echo "T1|$t1_file|User selected T1 override"
            else
                echo "ERROR||T1 not available"
            fi
            ;;
        "3")
            if [ "$(echo "$flair_analysis" | cut -d'|' -f1)" != "NONE" ]; then
                local flair_file=$(echo "$flair_analysis" | cut -d'|' -f1)
                echo "FLAIR|$flair_file|User selected FLAIR override"
            else
                echo "ERROR||FLAIR not available"
            fi
            ;;
        "4")
            show_detailed_comparison "$t1_analysis" "$flair_analysis"
            # Recurse to get final decision
            present_interactive_decision_matrix "$t1_analysis" "$flair_analysis" "$auto_decision"
            ;;
        *)
            echo "Invalid selection. Using recommendation."
            echo "$auto_decision"
            ;;
    esac
}

# Show detailed comparison between T1 and FLAIR
show_detailed_comparison() {
    local t1_analysis="$1"
    local flair_analysis="$2"
    
    echo ""
    echo "========== DETAILED COMPARISON =========="
    echo ""
    
    # Detailed T1 information
    if [ "$(echo "$t1_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        local t1_file=$(echo "$t1_analysis" | cut -d'|' -f1)
        echo "T1-MPRAGE Analysis:"
        echo "  File: $(basename "$t1_file")"
        echo "  Full path: $t1_file"
        if command -v fslinfo &> /dev/null && [ -f "$t1_file" ]; then
            echo "  Image details:"
            fslinfo "$t1_file" | grep -E "(dim[1-4]|pixdim[1-4]|datatype)"
        fi
        echo ""
    fi
    
    # Detailed FLAIR information
    if [ "$(echo "$flair_analysis" | cut -d'|' -f1)" != "NONE" ]; then
        local flair_file=$(echo "$flair_analysis" | cut -d'|' -f1)
        echo "T2-SPACE-FLAIR Analysis:"
        echo "  File: $(basename "$flair_file")"
        echo "  Full path: $flair_file"
        if command -v fslinfo &> /dev/null && [ -f "$flair_file" ]; then
            echo "  Image details:"
            fslinfo "$flair_file" | grep -E "(dim[1-4]|pixdim[1-4]|datatype)"
        fi
        echo ""
    fi
    
    echo "Press Enter to continue..."
    read -r
}

# Log decision rationale for automated mode
log_decision_rationale() {
    local decision="$1"
    local modality=$(echo "$decision" | cut -d'|' -f1)
    local file=$(echo "$decision" | cut -d'|' -f2)
    local rationale=$(echo "$decision" | cut -d'|' -f3)
    
    log_formatted "SUCCESS" "Reference space selected: $modality"
    log_message "Selected file: $(basename "$file")"
    log_message "Rationale: $rationale"
}

# Export functions for external use
export -f select_optimal_reference_space
export -f discover_original_sequences
export -f is_original_acquisition
export -f analyze_sequence_quality
export -f make_reference_space_decision
export -f present_interactive_decision_matrix

log_message "Reference space selection module loaded"
