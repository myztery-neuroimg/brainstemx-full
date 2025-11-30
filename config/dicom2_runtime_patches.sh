#!/bin/bash
# Runtime patch for pipeline.sh hardcoded patterns
# This patches the running pipeline to use DICOM2-compatible patterns

# Source the comprehensive fix first
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/dicom2_comprehensive_fix.sh"

# ===== PATCH HARDCODED PIPELINE PATTERNS =====

# Override Step 2 preprocessing patterns
patch_step2_patterns() {
    log_message "PATCH: Overriding Step 2 hardcoded patterns for DICOM2 data"
    
    # Replace the hardcoded patterns in pipeline.sh variables
    T1_PRIORITY_PATTERN="*T1*.nii.gz"
    FLAIR_PRIORITY_PATTERN="*FLAIR*.nii.gz"
    
    log_message "  T1 pattern updated: $T1_PRIORITY_PATTERN"
    log_message "  FLAIR pattern updated: $FLAIR_PRIORITY_PATTERN"
}

# Override Step 6 analysis patterns
patch_step6_patterns() {
    log_message "PATCH: Overriding Step 6 analysis patterns for DICOM2 data"
    
    # Patch the find commands in analysis step
    if [ -n "$MANUAL_T1_FILE" ] && [ -f "$MANUAL_T1_FILE" ]; then
        orig_t1="$MANUAL_T1_FILE"
        log_message "  Using manual T1: $(basename "$orig_t1")"
    fi
    
    if [ -n "$MANUAL_FLAIR_FILE" ] && [ -f "$MANUAL_FLAIR_FILE" ]; then
        orig_flair="$MANUAL_FLAIR_FILE"
        log_message "  Using manual FLAIR: $(basename "$orig_flair")"
    fi
}

# Override reference space selection patterns
patch_reference_space_patterns() {
    log_message "PATCH: Overriding reference space selection patterns"
    
    # This needs to be called before select_optimal_reference_space
    export T1_SEARCH_PATTERNS_OVERRIDE=true
    export FLAIR_SEARCH_PATTERNS_OVERRIDE=true
}

# ===== APPLY PATCHES BASED ON PIPELINE STAGE =====

apply_runtime_patches() {
    local stage="${1:-unknown}"
    
    log_message "Applying DICOM2 runtime patches for stage: $stage"
    
    case "$stage" in
        "preprocess"|"2")
            patch_step2_patterns
            patch_reference_space_patterns
            ;;
        "analysis"|"6")
            patch_step6_patterns
            ;;
        *)
            # Apply all patches
            patch_step2_patterns
            patch_reference_space_patterns
            patch_step6_patterns
            ;;
    esac
}

# ===== ENHANCED FILE DISCOVERY =====

# Smarter T1 file discovery for DICOM2
discover_dicom2_t1_files() {
    local search_dir="$1"
    
    # Manual override first
    if [ -n "$MANUAL_T1_FILE" ] && [ -f "$MANUAL_T1_FILE" ]; then
        echo "$MANUAL_T1_FILE"
        return 0
    fi
    
    # Search with DICOM2-specific priorities
    local candidates=()
    
    # Priority 1: 3D isotropic T1 (best for your data)
    candidates+=($(find "$search_dir" -name "*T1W_3D_TFE_sag*.nii.gz" 2>/dev/null))
    
    # Priority 2: Other 3D T1 sequences
    candidates+=($(find "$search_dir" -name "*MPR*T1*.nii.gz" 2>/dev/null))
    
    # Priority 3: Any T1 sequences
    candidates+=($(find "$search_dir" -name "*T1*.nii.gz" ! -name "*mask*" ! -name "*brain*" 2>/dev/null))
    
    # Return the first (highest priority) candidate
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[0]}"
    fi
}

# Smarter FLAIR file discovery for DICOM2
discover_dicom2_flair_files() {
    local search_dir="$1"
    
    # Manual override first
    if [ -n "$MANUAL_FLAIR_FILE" ] && [ -f "$MANUAL_FLAIR_FILE" ]; then
        echo "$MANUAL_FLAIR_FILE"
        return 0
    fi
    
    # Search for FLAIR files
    local candidates=()
    
    # Priority 1: Explicit FLAIR naming
    candidates+=($(find "$search_dir" -name "*FLAIR*.nii.gz" 2>/dev/null))
    
    # Priority 2: T2 SPACE FLAIR
    candidates+=($(find "$search_dir" -name "*T2*SPACE*FLAIR*.nii.gz" 2>/dev/null))
    
    # Return the first candidate
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[0]}"
    fi
}

# Export enhanced discovery functions
export -f discover_dicom2_t1_files
export -f discover_dicom2_flair_files
export -f apply_runtime_patches

log_message "DICOM2 runtime patches loaded - call apply_runtime_patches() before processing"
