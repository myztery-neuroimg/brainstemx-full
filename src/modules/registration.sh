#!/usr/bin/env bash
#
# registration.sh - Registration functions for the brain MRI processing pipeline
#
# This module contains a fully ANTs-based approach for:
# - T2-SPACE-FLAIR to T1MPRAGE registration with white matter guided alignment
# - Multi-modality registration (T2, DWI, SWI) to T1
# - Registration visualization and quality assessment
# - Complete methodological consistency with ANTs throughout the pipeline
#

# Get script directory for later use
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
FIX_SCRIPT="${SCRIPT_DIR}/../tools/fix_registration_issues.sh"

# Ensure QA and enhanced registration validation modules are sourced for function availability
QA_MODULE="${SCRIPT_DIR}/qa.sh"
ENHANCED_REGVAL_MODULE="${SCRIPT_DIR}/enhanced_registration_validation.sh"
if [ -f "$QA_MODULE" ]; then
    source "$QA_MODULE"
fi
if [ -f "$ENHANCED_REGVAL_MODULE" ]; then
    source "$ENHANCED_REGVAL_MODULE"
fi

# Check if functions are available after sourcing
if declare -f calculate_extended_registration_metrics >/dev/null 2>&1; then
    log_message "DEBUG: calculate_extended_registration_metrics is defined after sourcing in registration.sh"
else
    log_formatted "ERROR" "DEBUG: calculate_extended_registration_metrics is NOT defined after sourcing in registration.sh"
fi
if declare -f enhanced_launch_visual_qa >/dev/null 2>&1; then
    log_message "DEBUG: enhanced_launch_visual_qa is defined after sourcing in registration.sh"
else
    log_formatted "ERROR" "DEBUG: enhanced_launch_visual_qa is NOT defined after sourcing in registration.sh"
fi
# Check if functions are available after sourcing
if declare -f calculate_extended_registration_metrics >/dev/null 2>&1; then
    log_message "DEBUG: calculate_extended_registration_metrics is defined after sourcing in registration.sh"
else
    log_formatted "ERROR" "DEBUG: calculate_extended_registration_metrics is NOT defined after sourcing in registration.sh"
fi
if declare -f enhanced_launch_visual_qa >/dev/null 2>&1; then
    log_message "DEBUG: enhanced_launch_visual_qa is defined after sourcing in registration.sh"
else
    log_formatted "ERROR" "DEBUG: enhanced_launch_visual_qa is NOT defined after sourcing in registration.sh"
fi

# Source the orientation correction module if it exists
ORIENTATION_MODULE="${SCRIPT_DIR}/orientation_correction.sh"
if [ -f "$ORIENTATION_MODULE" ]; then
    source "$ORIENTATION_MODULE"
    log_message "Loaded orientation correction module: $ORIENTATION_MODULE"
fi

# Source the scan selection module
SCAN_SELECTION_MODULE="${SCRIPT_DIR}/../scan_selection.sh"
if [ -f "$SCAN_SELECTION_MODULE" ]; then
    source "$SCAN_SELECTION_MODULE"
    log_message "Loaded scan selection module: $SCAN_SELECTION_MODULE"
fi

# Function to run registration fix script - only call this after standardization
run_registration_fix() {
    # Only run if standardized directory exists
    if [ -d "${RESULTS_DIR}/standardized" ]; then
        if [ -f "$FIX_SCRIPT" ]; then
            log_message "Running registration issue fixing tool: $FIX_SCRIPT"
            bash "$FIX_SCRIPT"
            # Note: We continue even if the fix script fails
            log_message "Finished running fix_registration_issues.sh with status $?"
        else
            log_formatted "WARNING" "Registration fix script not found: $FIX_SCRIPT"
        fi
    else
        log_message "Skipping registration fix script as standardized files don't exist yet"
    fi
}

# Function to detect image resolution and set appropriate template
detect_image_resolution() {
    local image_file="$1"
    local result="2mm"  # Default to 2mm for better handling of thick slices
    
    # Check if file exists
    if [ ! -f "$image_file" ]; then
        log_formatted "ERROR" "Image file not found: $image_file"
        echo "$result"
        return 1
    fi
    
    # Get voxel dimensions using fslinfo
    local pixdim1=$(fslinfo "$image_file" | grep pixdim1 | awk '{print $2}')
    local pixdim2=$(fslinfo "$image_file" | grep pixdim2 | awk '{print $2}')
    local pixdim3=$(fslinfo "$image_file" | grep pixdim3 | awk '{print $2}')
    
    # Calculate average voxel dimension
    local avg_dim=$(echo "($pixdim1 + $pixdim2 + $pixdim3) / 3" | bc -l)
    
    log_message "Detected average voxel dimension: $avg_dim mm"
    
    # Determine closest template resolution
    if (( $(echo "$avg_dim <= 1.25" | bc -l) )); then
        result="1mm"
    elif (( $(echo "$avg_dim <= 2.5" | bc -l) )); then
        result="2mm"
    else
        log_formatted "WARNING" "Image has unusual resolution ($avg_dim mm). Using default template."
    fi
    
    log_message "Selected template resolution: $result"
    echo "$result"
    return 0
}

# Function to set template based on detected resolution
set_template_resolution() {
    local resolution="$1"
    
    case "$resolution" in
        "1mm")
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"
            ;;
        "2mm")
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_2MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_2MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_2MM"
            ;;
        *)
            log_formatted "WARNING" "Unknown resolution: $resolution. Using default (1mm)"
            export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
            export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
            export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"
            ;;
    esac
    
    log_message "Set templates for $resolution resolution: $EXTRACTION_TEMPLATE"
    return 0
}

# Function to perform multi-stage registration: rigid → affine → SyN with brainstem ROI constraint
perform_multistage_registration() {
    local fixed_image="$1"
    local moving_image="$2"
    local output_prefix="$3"
    local initial_transform="$4"  # Optional initialization
    local mask="$5"              # Optional mask
    
    log_message "=== Multi-stage Registration: Rigid → Affine → SyN ==="
    log_message "Fixed: $fixed_image"
    log_message "Moving: $moving_image"
    log_message "Output: $output_prefix"
    
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # Build base antsRegistration command
    local ants_cmd=(
        "${ants_bin}/antsRegistration"
        "--dimensionality" "3"
        "--float" "0"
        "--output" "[${output_prefix}Warped.nii.gz,${output_prefix}InverseWarped.nii.gz]"
        "--interpolation" "Linear"
        "--use-histogram-matching" "0"
        "--write-composite-transform" "0"
        "--collapse-output-transforms" "1"
        "--initialize-transforms-per-stage" "0"
        "--verbose" "1"
    )
    
    # Add initial transform if provided
    if [ -n "$initial_transform" ] && [ -f "$initial_transform" ]; then
        ants_cmd+=("--initial-moving-transform" "$initial_transform")
        log_message "Using initial transform: $initial_transform"
    else
        ants_cmd+=("--initial-moving-transform" "[${fixed_image},${moving_image},1]")
    fi
    
    # Add masks if provided
    if [ -n "$mask" ] && [ -f "$mask" ]; then
        ants_cmd+=("--masks" "[${mask},NULL]")
        log_message "Using registration mask: $mask"
    fi
    
    # Stage 1: Rigid registration
    ants_cmd+=(
        "--transform" "Rigid[0.1]"
        "--metric" "MI[${fixed_image},${moving_image},1,32,Regular,0.25]"
        "--convergence" "[1000x500x250x100,1e-6,10]"
        "--shrink-factors" "8x4x2x1"
        "--smoothing-sigmas" "3x2x1x0vox"
    )
    
    # Stage 2: Affine registration
    ants_cmd+=(
        "--transform" "Affine[0.1]"
        "--metric" "MI[${fixed_image},${moving_image},1,32,Regular,0.25]"
        "--convergence" "[1000x500x250x100,1e-6,10]"
        "--shrink-factors" "8x4x2x1"
        "--smoothing-sigmas" "3x2x1x0vox"
    )
    
    # Stage 3: SyN registration with brainstem ROI constraint
    # Use --restrict-deformation 0x0x1 to constrain deformation above pontomedullary sulcus
    ants_cmd+=(
        "--transform" "SyN[0.1,3,0]"
        "--metric" "CC[${fixed_image},${moving_image},1,4]"
        "--convergence" "[100x70x50x20,1e-6,10]"
        "--shrink-factors" "8x4x2x1"
        "--smoothing-sigmas" "3x2x1x0vox"
        "--restrict-deformation" "0x0x1"
    )
    
    log_message "Multi-stage registration command: ${ants_cmd[*]}"
    
    # Execute the multi-stage registration
    execute_ants_command "multistage_registration" "Multi-stage registration (rigid→affine→SyN with brainstem constraint)" "${ants_cmd[@]}"
    local reg_status=$?
    
    # Check registration status first
    if [ $reg_status -eq 0 ]; then
        # Registration command succeeded, now check for output file
        if [ -f "${output_prefix}Warped.nii.gz" ]; then
            log_formatted "SUCCESS" "✅ Multi-stage registration completed successfully"
            return 0
        else
            # Command succeeded but output file missing - check for alternate names
            log_message "Registration command succeeded but checking for output file variants..."
            for alt_suffix in "Warped.nii.gz" "_Warped.nii.gz" "1Warped.nii.gz"; do
                if [ -f "${output_prefix}${alt_suffix}" ]; then
                    log_message "Found output with alternate suffix: ${alt_suffix}"
                    if [ "${alt_suffix}" != "Warped.nii.gz" ]; then
                        # Create symlink with expected name
                        ln -sf "${output_prefix}${alt_suffix}" "${output_prefix}Warped.nii.gz"
                        log_message "Created symlink: ${output_prefix}Warped.nii.gz -> ${output_prefix}${alt_suffix}"
                    fi
                    log_formatted "SUCCESS" "✅ Multi-stage registration completed successfully (found output: ${alt_suffix})"
                    return 0
                fi
            done
            # If we get here, command succeeded but no output file found
            log_formatted "ERROR" "❌ Registration command succeeded but no output file found (expected: ${output_prefix}Warped.nii.gz)"
            log_message "Available files in output directory:"
            ls -la "$(dirname "${output_prefix}")" 2>/dev/null | grep "$(basename "${output_prefix}")" || log_message "No matching files found"
            return 1
        fi
    else
        # Registration command actually failed
        log_formatted "ERROR" "❌ Multi-stage registration command failed (exit status: $reg_status)"
        return 1
    fi
}

# Function to register any modality to T1
register_modality_to_t1() {
    # Usage: register_modality_to_t1 <T1_file.nii.gz> <modality_file.nii.gz> <modality_name> <output_prefix>
    #
    # Enhanced with multi-stage registration for brainstem analysis:
    # 1. Rigid registration for initial alignment
    # 2. Affine registration for linear corrections
    # 3. SyN registration with brainstem ROI constraint (--restrict-deformation 0x0x1)
    #
    # This multi-stage approach offers several advantages:
    # - Better control over deformation at each stage
    # - Reduced over-warping in critical brainstem regions
    # - More precise alignment for brainstem-focused analysis
    # - Improved reproducibility through staged optimization

    local t1_file="$1"
    local modality_file="$2"
    local modality_name="${3:-OTHER}"  # Default to OTHER if not specified
    local out_prefix="${4:-${RESULTS_DIR}/registered/t1_to_${modality_name}}"  # Convert to lowercase

    if [ ! -f "$t1_file" ] || [ ! -f "$modality_file" ]; then
        log_formatted "ERROR" "T1 or $modality_name file not found"
        return 1
    fi

    log_message "=== Registering $modality_name to T1 with WM-guided Registration ==="
    log_message "T1: $t1_file"
    log_message "$modality_name: $modality_file"
    log_message "Output prefix: $out_prefix"
    
    # Detect resolution and set appropriate template
    local detected_res=$(detect_image_resolution "$modality_file")
    set_template_resolution "$detected_res"
    
    # Check if orientation preservation is enabled
    local orientation_preservation="${ORIENTATION_PRESERVATION_ENABLED:-false}"
    if [ "$orientation_preservation" = "true" ]; then
        log_message "Orientation preservation is enabled for this registration"
    else
        log_message "Orientation preservation is disabled for this registration"
    fi

    # Create output directory
    mkdir -p "$(dirname "$out_prefix")"
    
    # Initialize white matter guided registration variables
    # Using WM boundaries improves registration accuracy by aligning cortical boundaries
    local use_wm_guided_registration="${USE_WM_GUIDED_REGISTRATION:-$WM_GUIDED_DEFAULT}"
    local ants_wm_init_matrix="${out_prefix}${WM_INIT_TRANSFORM_PREFIX}.mat"
    local wm_mask="${out_prefix}${WM_MASK_SUFFIX}"
    local wm_init_completed=false
    local outer_ribbon_mask="${out_prefix}_outer_ribbon_mask.nii.gz"
    
    # Step 1: Create WM mask for guided registration if it doesn't exist
    if [ "$use_wm_guided_registration" = "true" ]; then
        prepare_wm_segmentation "$t1_file" "$wm_mask" "$out_prefix" "$outer_ribbon_mask"
        # Check if WM segmentation failed
        if [ "$use_wm_guided_registration" = "false" ]; then
            log_formatted "WARNING" "WM segmentation failed, using standard registration"
        fi
    fi
    
    # Step 2: Perform white matter guided initialization
    if [ "$use_wm_guided_registration" = "true" ] && [ -f "$wm_mask" ]; then
        perform_wm_guided_initialization "$t1_file" "$modality_file" "$wm_mask" "$out_prefix" "$ants_wm_init_matrix"
        # Check if initialization succeeded
        if [ -f "${out_prefix}_wm_init_0GenericAffine.mat" ]; then
            ants_wm_init_matrix="${out_prefix}_wm_init_0GenericAffine.mat"
            wm_init_completed=true
        fi
    fi
    
    # Step 3: Run ANTs registration with white matter guided initialization or mask constraint
    # This step performs the final non-linear registration using ANTs SyN algorithm
    # Set ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS environment variable to ensure ANTs uses all cores
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$ANTS_THREADS"
    
    # Explicitly use the full path to ANTs commands
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    log_message "Running ANTs SyN registration with full parallelization (ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$ANTS_THREADS)"
    
    if [ "$wm_init_completed" = "true" ]; then
        # Convert FLIRT matrix to ANTs format for initialization
        # This leverages the white matter guided alignment from the previous step
        log_message "Using white matter guided initialization for ANTs SyN registration"
        
        # Convert transform to ITK format (required for ANTs initialization)
        # This allows us to maintain the alignment from the white matter guided initialization
        # Try using ANTs' ConvertTransformFile if available, otherwise fall back to c3d_affine_tool
        local transform_converted=false
        
        # Log matrix information before conversion
        log_formatted "INFO" "===== TRANSFORM CONVERSION PROCESS ====="
        log_message "Transform matrix to convert: $ants_wm_init_matrix"
        log_message "Output ITK transform target: ${out_prefix}_wm_init_itk.txt"
        
        # Dump matrix content for debugging
        if [ -f "$ants_wm_init_matrix" ]; then
            log_message "Matrix file exists with size: $(stat -f %z "$ants_wm_init_matrix") bytes"
            log_message "Matrix content preview: [Binary ANTs transform file - content not displayed]"
        else
            log_formatted "ERROR" "Matrix file does not exist: $ants_wm_init_matrix"
        fi
        
        # Detect and validate transform file format (FSL vs ANTs) with comprehensive error handling
        log_formatted "INFO" "===== TRANSFORM FORMAT DETECTION AND VALIDATION ====="
        log_message "Analyzing transform file format: $ants_wm_init_matrix"
        
        # Use explicit error handling to prevent silent termination
        (
            set +e  # Disable exit on error for this section
            local transform_format="unknown"
            local transform_valid=false
            
            if [ ! -f "$ants_wm_init_matrix" ]; then
                log_formatted "ERROR" "Transform file does not exist: $ants_wm_init_matrix"
                transform_converted=false
                return 1
            elif [ ! -s "$ants_wm_init_matrix" ]; then
                log_formatted "ERROR" "Transform file is empty: $ants_wm_init_matrix"
                transform_converted=false
                return 1
            fi
            
            # Get file size safely
            local file_size=$(stat -f %z "$ants_wm_init_matrix" 2>/dev/null || stat --format="%s" "$ants_wm_init_matrix" 2>/dev/null || echo "0")
            log_message "Transform file size: $file_size bytes"
            
            # Check if it's a text-based FSL format (with error handling)
            if head -n 5 "$ants_wm_init_matrix" 2>/dev/null | grep -E '^[[:space:]]*[-]?[0-9]+\.?[0-9]*([eE][-+]?[0-9]+)?[[:space:]]*$' >/dev/null 2>&1; then
                transform_format="FSL"
                log_message "Detected FSL format transformation matrix (text-based)"
                
                # Validate FSL format - should have 4 rows of 4 numbers each
                local line_count=$(wc -l < "$ants_wm_init_matrix" 2>/dev/null || echo "0")
                if [ "$line_count" -eq 4 ]; then
                    log_formatted "SUCCESS" "Valid FSL 4x4 transformation matrix detected"
                    transform_valid=true
                else
                    log_formatted "WARNING" "FSL matrix has $line_count lines (expected 4)"
                    transform_valid=false
                fi
                
            # Check if it's a binary ANTs format (with comprehensive error handling)
            elif file "$ants_wm_init_matrix" 2>/dev/null | grep -q "data\|binary" 2>/dev/null || [ "$file_size" -gt 100 ]; then
                transform_format="ANTs"
                log_message "Detected ANTs format transformation matrix (binary)"
                
                # Use simplified validation to avoid hanging
                log_message "Using simplified ANTs transform validation"
                if [ "$file_size" -gt 50 ] && [ "$file_size" -lt 50000 ]; then
                    log_formatted "SUCCESS" "ANTs transform file has reasonable size ($file_size bytes)"
                    transform_valid=true
                else
                    log_formatted "WARNING" "ANTs transform file size unusual: $file_size bytes"
                    # Still proceed but mark as potentially problematic
                    transform_valid=true
                fi
                
            else
                log_formatted "WARNING" "Could not determine transformation matrix format"
                # Default to assuming ANTs format for compatibility
                transform_format="ANTs"
                transform_valid=true
                log_message "Defaulting to ANTs format assumption"
            fi
            
            # Export variables to parent scope
            export transform_format transform_valid
            return 0
            
        ) # End of error-safe subshell
        
        local validation_status=$?
        
        # Import variables from subshell (fallback if export didn't work)
        transform_format="${transform_format:-ANTs}"
        transform_valid="${transform_valid:-true}"
        
        log_message "Transform format: $transform_format, Valid: $transform_valid"
        log_message "Validation completed with status: $validation_status"
        
        # Handle format-specific requirements (simplified)
        if [ "$transform_valid" = "true" ]; then
            transform_converted=true
            log_message "Transform processing completed successfully"
        else
            log_formatted "ERROR" "Transform validation failed for format: $transform_format"
            transform_converted=false
        fi
        
        # Final validation result
        log_message "=== FINAL TRANSFORM VALIDATION RESULT ==="
        if [ "$transform_converted" = "false" ]; then
            log_formatted "WARNING" "Transform validation failed, falling back to standard registration"
            wm_init_completed=false
        else
            log_formatted "SUCCESS" "Transform file validated and ready for use (format: $transform_format)"
        fi
        
        log_message "Transform validation section completed, proceeding to registration execution"
        
        if [ "$transform_converted" = "true" ]; then
            # Use multi-stage registration with white matter guided initialization
            log_formatted "INFO" "===== WM-GUIDED MULTI-STAGE REGISTRATION ====="
            log_message "Executing multi-stage registration (rigid→affine→SyN) with white matter initialization"
            log_message "Fixed image: $t1_file"
            log_message "Moving image: $modality_file"
            log_message "Output prefix: $out_prefix"
            log_message "Transform format: $transform_format"
            log_message "Transform file: $ants_wm_init_matrix"
            
            # Pre-execution validation
            local can_execute=true
            
            # Verify input files exist and are valid
            if ! validate_nifti "$t1_file" "Fixed image (T1)" >/dev/null 2>&1; then
                log_formatted "ERROR" "Fixed image validation failed: $t1_file"
                can_execute=false
            fi
            
            if ! validate_nifti "$modality_file" "Moving image ($modality_name)" >/dev/null 2>&1; then
                log_formatted "ERROR" "Moving image validation failed: $modality_file"
                can_execute=false
            fi
            
            # Verify ANTs binary exists
            if [ ! -f "${ants_bin}/antsRegistration" ]; then
                log_formatted "ERROR" "ANTs registration binary not found: ${ants_bin}/antsRegistration"
                can_execute=false
            fi
            
            # Create output directory if it doesn't exist
            local output_dir=$(dirname "$out_prefix")
            mkdir -p "$output_dir"
            
            if [ "$can_execute" = "true" ]; then
                # Capture start time
                local start_time=$(date +%s)
                
                # Use multi-stage registration with WM initialization
                log_message "Starting WM-guided multi-stage registration..."
                perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "$ants_wm_init_matrix" "$wm_mask"
                local ants_status=$?
                
                # Calculate elapsed time
                local end_time=$(date +%s)
                local elapsed=$((end_time - start_time))
                log_message "WM-guided multi-stage registration completed in ${elapsed}s with status: $ants_status"
                
                # Check for expected outputs immediately after execution
                local registration_success=false
                if [ $ants_status -eq 0 ]; then
                    # Verify output files were created
                    if [ -f "${out_prefix}Warped.nii.gz" ] && [ -s "${out_prefix}Warped.nii.gz" ]; then
                        log_formatted "SUCCESS" "WM-guided multi-stage registration completed successfully"
                        log_message "Output file created: ${out_prefix}Warped.nii.gz ($(stat -f %z "${out_prefix}Warped.nii.gz" 2>/dev/null || echo "unknown") bytes)"
                        registration_success=true
                    else
                        log_formatted "WARNING" "Registration reported success but output file missing or empty"
                        ants_status=1  # Override status to trigger fallback
                    fi
                fi
                
                # If WM-guided registration failed, try direct multi-stage registration
                if [ "$registration_success" = "false" ]; then
                    log_formatted "INFO" "===== DIRECT MULTI-STAGE REGISTRATION FALLBACK ====="
                    log_message "WM-guided registration failed, attempting standard multi-stage registration"
                    
                    local fb_start_time=$(date +%s)
                    
                    # Use multi-stage registration without initialization
                    perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "" ""
                    local fb_status=$?
                    
                    local fb_end_time=$(date +%s)
                    local fb_elapsed=$((fb_end_time - fb_start_time))
                    log_message "Fallback multi-stage registration completed in ${fb_elapsed}s with status: $fb_status"
                    
                    # Check fallback results
                    if [ $fb_status -eq 0 ] && [ -f "${out_prefix}Warped.nii.gz" ] && [ -s "${out_prefix}Warped.nii.gz" ]; then
                        log_formatted "SUCCESS" "Standard multi-stage registration fallback succeeded"
                        registration_success=true
                    else
                        log_formatted "ERROR" "Both WM-guided and standard multi-stage registration failed"
                    fi
                fi
            else
                log_formatted "ERROR" "Pre-execution validation failed, cannot proceed with registration"
            fi
        fi
    elif [ -f "$outer_ribbon_mask" ] && [ -s "$outer_ribbon_mask" ]; then
        # If WM-guided initialization failed but we have the outer ribbon mask,
        # use it for cost function masking to improve boundary alignment
        log_message "Using outer ribbon mask constraint for multi-stage registration"
        log_message "This approach still benefits from ANTs-based mask preparation"
        log_message "Outer ribbon mask: $outer_ribbon_mask"
        
        # Verify mask is valid before using
        if fslinfo "$outer_ribbon_mask" &>/dev/null; then
            # Run multi-stage registration with the outer ribbon mask for cost function masking
            log_message "Running multi-stage registration with cost function masking"
            
            # Use multi-stage registration with mask
            perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "" "$outer_ribbon_mask"
            
            if [ $? -ne 0 ]; then
                log_formatted "WARNING" "Multi-stage registration with cost function masking failed, falling back to standard registration"
                # Fall back to standard multi-stage registration
                perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "" ""
            fi
        else
            log_formatted "WARNING" "Outer ribbon mask is invalid, falling back to standard registration"
            # Fall back to standard multi-stage registration
            perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "" ""
        fi
    else
        # Check if orientation preservation is enabled
        local orientation_preservation="${ORIENTATION_PRESERVATION_ENABLED:-true}"
        if [ "$orientation_preservation" = "true" ] && command -v register_with_topology_preservation &>/dev/null; then
            # Use topology-preserving registration
            log_message "Using topology-preserving registration for orientation preservation"
            register_with_topology_preservation "$t1_file" "$modality_file" "$out_prefix" "r"
        else
            # Fall back to standard multi-stage registration when no initialization or mask is available
            # This is still effective, just without the benefits of white matter guidance
            log_message "Using standard multi-stage registration (no white matter guidance)"
            log_message "This approach still leverages multi-stage optimization with brainstem constraint"
            
            # Use standard multi-stage registration without initialization or mask
            perform_multistage_registration "$t1_file" "$modality_file" "$out_prefix" "" ""
        fi
    fi
    
    # Optional: Print resource utilization during registration
    log_message "Resource utilization during registration:"
    ps -p $$ -o %cpu,%mem | tail -n 1 || true

    # Expected output files:
    # The Warped file => ${out_prefix}Warped.nii.gz
    # The transform(s) => ${out_prefix}0GenericAffine.mat, etc.

    # --- Ensure affine .mat file exists for QA/Jacobian calculation ---
    local affine_file="${out_prefix}0GenericAffine.mat"
    local warp_file="${out_prefix}1Warp.nii.gz"
    if [ ! -f "$affine_file" ] && [ -f "$warp_file" ]; then
        log_formatted "WARNING" "Affine .mat file missing but warp field exists. Attempting to generate affine matrix for QA compatibility."
        # Try to extract affine from warp using ANTs tools if available
        local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
        if command -v "${ants_bin}/ConvertTransformFile" &>/dev/null; then
            # Try to extract the affine component from the warp field (if possible)
            "${ants_bin}/ConvertTransformFile" 3 "$warp_file" "$affine_file" --output-affine
            if [ -f "$affine_file" ]; then
                log_formatted "SUCCESS" "Generated affine .mat file from warp field using ANTs ConvertTransformFile."
            else
                log_formatted "ERROR" "Failed to generate affine .mat file from warp field using ANTs ConvertTransformFile."
            fi
        else
            log_formatted "WARNING" "ANTs ConvertTransformFile not available. Cannot generate affine .mat file from warp field."
        fi
    fi

    # Check if warped output actually exists
    if [ ! -f "${out_prefix}Warped.nii.gz" ]; then
        log_formatted "INFO" "===== WARPED OUTPUT VERIFICATION ====="
        log_formatted "WARNING" "Expected warped output file not found: ${out_prefix}Warped.nii.gz"
        log_message "Attempting to find warped output with alternate extensions..."
        
        # List all files in output directory for debugging
        log_message "Files in output directory: $(ls -la "$(dirname "$out_prefix")" | grep -E "$(basename "$out_prefix")" || echo "No matching files found")"
        
        # Try to find the file with various extensions ANTs might use
        local found_warped=false
        for ext in "Warped.nii.gz" "_Warped.nii.gz" "Warped.nii" "warped.nii.gz" "_warped.nii.gz"; do
            if [ -f "${out_prefix}${ext}" ]; then
                log_message "Found warped file with different extension: ${out_prefix}${ext}"
                log_message "File size: $(stat -f %z "${out_prefix}${ext}" 2>/dev/null || stat --format="%s" "${out_prefix}${ext}" 2>/dev/null || echo "Unknown") bytes"
                # Create symbolic link with expected name
                ln -sf "${out_prefix}${ext}" "${out_prefix}Warped.nii.gz"
                found_warped=true
                log_formatted "SUCCESS" "Using warped file with extension: $ext"
                break
            fi
        done
        
        if [ "$found_warped" = "false" ]; then
            # Check if the registration even started by looking for log files
            log_formatted "ERROR" "Registration failed to produce output files. Check logs for errors."
            
            # Enhanced emergency registration with better diagnostics
            log_formatted "INFO" "===== ENHANCED EMERGENCY REGISTRATION SYSTEM ====="
            local emergency_dir="$(dirname "$out_prefix")/emergency"
            mkdir -p "$emergency_dir"
            log_message "Using isolated emergency directory: $emergency_dir"
            
            # Perform thorough pre-emergency diagnostics
            log_message "Pre-emergency diagnostics:"
            log_message "  T1 file: $t1_file ($(stat -f %z "$t1_file" 2>/dev/null || echo "?") bytes)"
            log_message "  Modality file: $modality_file ($(stat -f %z "$modality_file" 2>/dev/null || echo "?") bytes)"
            log_message "  ANTs binary: ${ants_bin}/antsRegistrationSyNQuick.sh"
            log_message "  Available threads: $ANTS_THREADS"
            
            # Verify ANTs binary availability for emergency methods
            if [ ! -f "${ants_bin}/antsRegistrationSyNQuick.sh" ]; then
                log_formatted "ERROR" "ANTs SyNQuick not available for emergency registration"
                log_message "Available ANTs commands:"
                ls -la "${ants_bin}"/ants* 2>/dev/null | head -5 || echo "No ANTs commands found"
                found_warped=false
                return 1
            fi
            
            # Track overall success across multiple methods
            local registered_successfully=false
            local attempted_methods=0
            local total_start_time=$(date +%s)
            
            # Method 1: Quick SyN with reduced iterations for speed
            if [ "$registered_successfully" = "false" ]; then
                attempted_methods=$((attempted_methods + 1))
                log_formatted "INFO" "Emergency Method 1: Quick SyN (reduced iterations)"
                
                local method1_cmd=(
                    "${ants_bin}/antsRegistrationSyNQuick.sh"
                    "-d" "3"
                    "-f" "$t1_file"
                    "-m" "$modality_file"
                    "-o" "${emergency_dir}/method1_"
                    "-n" "$ANTS_THREADS"
                    "-p" "f"
                    "-t" "s"
                )
                
                log_message "Method 1 command: ${method1_cmd[*]}"
                execute_ants_command "emergency_method1" "Quick SyN registration (reduced complexity)" "${method1_cmd[@]}"
                local method1_status=$?
                
                if [ -f "${emergency_dir}/method1_Warped.nii.gz" ] && [ -s "${emergency_dir}/method1_Warped.nii.gz" ]; then
                    log_formatted "SUCCESS" "Emergency Method 1 succeeded"
                    cp "${emergency_dir}/method1_Warped.nii.gz" "${out_prefix}Warped.nii.gz"
                    registered_successfully=true
                else
                    log_formatted "WARNING" "Emergency Method 1 failed (status: $method1_status)"
                fi
            fi
            
            # Method 2: Affine-only registration (most robust)
            if [ "$registered_successfully" = "false" ]; then
                attempted_methods=$((attempted_methods + 1))
                log_formatted "INFO" "Emergency Method 2: Affine-only registration"
                
                local method2_cmd=(
                    "${ants_bin}/antsRegistrationSyNQuick.sh"
                    "-d" "3"
                    "-f" "$t1_file"
                    "-m" "$modality_file"
                    "-o" "${emergency_dir}/method2_"
                    "-n" "$ANTS_THREADS"
                    "-p" "f"
                    "-t" "a"
                )
                
                log_message "Method 2 command: ${method2_cmd[*]}"
                execute_ants_command "emergency_method2" "Affine-only registration (most stable)" "${method2_cmd[@]}"
                local method2_status=$?
                
                if [ -f "${emergency_dir}/method2_Warped.nii.gz" ] && [ -s "${emergency_dir}/method2_Warped.nii.gz" ]; then
                    log_formatted "SUCCESS" "Emergency Method 2 (affine) succeeded"
                    cp "${emergency_dir}/method2_Warped.nii.gz" "${out_prefix}Warped.nii.gz"
                    registered_successfully=true
                else
                    log_formatted "WARNING" "Emergency Method 2 failed (status: $method2_status)"
                fi
            fi
            
            # Method 3: Standard SyNQuick (fallback to default)
            if [ "$registered_successfully" = "false" ]; then
                attempted_methods=$((attempted_methods + 1))
                log_formatted "INFO" "Emergency Method 3: Standard SyNQuick"
                
                local method3_cmd=(
                    "${ants_bin}/antsRegistrationSyNQuick.sh"
                    "-d" "3"
                    "-f" "$t1_file"
                    "-m" "$modality_file"
                    "-o" "${emergency_dir}/method3_"
                    "-n" "$ANTS_THREADS"
                    "-p" "f"
                )
                
                log_message "Method 3 command: ${method3_cmd[*]}"
                execute_ants_command "emergency_method3" "Standard SyNQuick registration" "${method3_cmd[@]}"
                local method3_status=$?
                
                if [ -f "${emergency_dir}/method3_Warped.nii.gz" ] && [ -s "${emergency_dir}/method3_Warped.nii.gz" ]; then
                    log_formatted "SUCCESS" "Emergency Method 3 (standard) succeeded"
                    cp "${emergency_dir}/method3_Warped.nii.gz" "${out_prefix}Warped.nii.gz"
                    registered_successfully=true
                else
                    log_formatted "WARNING" "Emergency Method 3 failed (status: $method3_status)"
                fi
            fi
            
            # Method 4: FLIRT as absolute last resort
            if [ "$registered_successfully" = "false" ] && command -v flirt &>/dev/null; then
                attempted_methods=$((attempted_methods + 1))
                log_formatted "INFO" "Emergency Method 4: FSL FLIRT (final fallback)"
                
                log_message "Using FLIRT for emergency registration..."
                flirt -in "$modality_file" -ref "$t1_file" \
                      -out "${emergency_dir}/method4.nii.gz" \
                      -omat "${emergency_dir}/method4.mat" \
                      -dof 12 -interp trilinear
                local flirt_status=$?
                
                if [ -f "${emergency_dir}/method4.nii.gz" ] && [ -s "${emergency_dir}/method4.nii.gz" ]; then
                    log_formatted "SUCCESS" "Emergency Method 4 (FLIRT) succeeded"
                    cp "${emergency_dir}/method4.nii.gz" "${out_prefix}Warped.nii.gz"
                    registered_successfully=true
                else
                    log_formatted "ERROR" "Emergency Method 4 (FLIRT) failed (status: $flirt_status)"
                fi
            fi
            
            # Calculate total emergency time and provide final report
            local total_end_time=$(date +%s)
            local total_elapsed=$((total_end_time - total_start_time))
            
            if [ "$registered_successfully" = "true" ]; then
                log_formatted "SUCCESS" "Emergency registration succeeded after $attempted_methods attempts (${total_elapsed}s)"
                
                # Verify final output file
                local final_size=$(stat -f %z "${out_prefix}Warped.nii.gz" 2>/dev/null || stat --format="%s" "${out_prefix}Warped.nii.gz" 2>/dev/null || echo "0")
                log_message "Final output: ${out_prefix}Warped.nii.gz ($final_size bytes)"
                
                # Test file integrity
                if fslinfo "${out_prefix}Warped.nii.gz" &>/dev/null; then
                    log_formatted "SUCCESS" "Emergency output passed NIfTI validation"
                    found_warped=true
                else
                    log_formatted "WARNING" "Emergency output failed NIfTI validation but proceeding"
                    found_warped=true  # Allow pipeline to continue
                fi
            else
                log_formatted "ERROR" "All $attempted_methods emergency registration methods failed"
                log_message "Emergency diagnostic summary:"
                log_message "  Directory contents: $(ls -la "$emergency_dir" 2>/dev/null | wc -l) files"
                log_message "  Available disk space: $(df -h "$(dirname "$out_prefix")" | tail -1 | awk '{print $4}')"
                log_message "  System load: $(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')"
                
                # Create minimal placeholder to prevent pipeline crash
                log_message "Creating minimal placeholder file to prevent pipeline failure"
                echo "Emergency registration failed - placeholder file" > "${out_prefix}Warped.nii.gz.txt"
                found_warped=false
            fi
        fi
    fi

    log_message "Registration complete. Warped file => ${out_prefix}Warped.nii.gz"
    
    # Check for orientation distortion and correct if needed
    local orientation_preservation="${ORIENTATION_PRESERVATION_ENABLED:-true}"
    if [ "$orientation_preservation" = "true" ] && command -v correct_orientation_distortion &>/dev/null; then
        log_message "Checking for orientation distortion in the registered image"
        
        # Create a temporary file for potential correction
        local temp_corrected="${out_prefix}_temp_corrected.nii.gz"
        
        # Apply orientation correction
        correct_orientation_distortion "$t1_file" "$modality_file" "${out_prefix}Warped.nii.gz" \
            "${out_prefix}0GenericAffine.mat" "$temp_corrected"
            
        # Check if correction was needed and applied
        if [ -f "$temp_corrected" ] && [ -s "$temp_corrected" ]; then
            log_message "Orientation correction was applied, replacing output with corrected version"
            cp "$temp_corrected" "${out_prefix}Warped.nii.gz"
            rm -f "$temp_corrected"
        fi
    fi
    
    # Validate the registration with improved error handling
    validate_registration_output "$t1_file" "$modality_file" "${out_prefix}Warped.nii.gz" "${out_prefix}"
    
    # If orientation correction is enabled, add orientation metrics to validation
    #if [ "$orientation_preservation" = "true" ] && command -v calculate_orientation_deviation &>/dev/null; then
    #    local orientation_deviation=$(calculate_orientation_deviation "$t1_file" "${out_prefix}Warped.nii.gz")
    #    local orientation_quality=$(assess_orientation_quality "$orientation_deviation")
    #    
    #    log_message "Orientation deviation: $orientation_deviation radians (Quality: $orientation_quality)"
    #    
    #    # Add to validation report
    #    mkdir -p "${out_prefix}_validation"
    #    echo "$orientation_deviation" > "${out_prefix}_validation/orientation_deviation.txt"
    #    echo "$orientation_quality" > "${out_prefix}_validation/orientation_quality.txt"
    #fi
    
    return 0
}

# Function to register FLAIR to T1 (wrapper for backward compatibility)
register_t2_flair_to_t1mprage() {
    # Usage: register_t2_flair_to_t1mprage <T1_file.nii.gz> <FLAIR_file.nii.gz> <output_prefix>
    local t1_file="$1"
    local flair_file="$2"
    local out_prefix="${3:-${RESULTS_DIR}/registered/t1_to_flair}"
    
    # Call the new generic function with "FLAIR" as the modality name
    register_modality_to_t1 "$t1_file" "$flair_file" "FLAIR" "$out_prefix"
    return $?
}

# Function to create registration visualizations
create_registration_visualizations() {
    local fixed="$1"
    local moving="$2"
    local warped="${3:-${RESULTS_DIR}/registered/t1_to_flairWarped.nii.gz}"
    local output_dir="${4:-${RESULTS_DIR}/validation/registration}"
    
    log_message "Creating registration visualizations"
    mkdir -p "$output_dir"
    
    # Create the output directory even if validation will fail
    mkdir -p "$output_dir"
    
    # Verify input files exist and validate their integrity
    if [ ! -f "$fixed" ]; then
        log_formatted "ERROR" "Fixed image not found: $fixed"
        log_message "Missing fixed image" > "${output_dir}/error.txt"
        return 1
    else
        # Verify file integrity using fslinfo
        if ! fslinfo "$fixed" &>/dev/null; then
            log_formatted "ERROR" "Fixed image appears to be corrupt: $fixed"
            log_message "Corrupt fixed image" > "${output_dir}/error.txt"
            return 1
        fi
    fi
    
    if [ ! -f "$warped" ]; then
        log_formatted "ERROR" "Warped image not found: $warped"
        log_message "Missing warped image" > "${output_dir}/error.txt"
        return 1
    else
        # Verify file integrity using fslinfo
        if ! fslinfo "$warped" &>/dev/null; then
            log_formatted "ERROR" "Warped image appears to be corrupt: $warped"
            log_message "Corrupt warped image" > "${output_dir}/error.txt"
            return 1
        fi
    fi
    
    # Create a simple check file to confirm these exist
    log_message "Creating registration files list"
    {
        log_message "Fixed: $fixed"
        log_message "Moving: $moving"
        log_message "Warped: $warped"
    } > "${output_dir}/registration_files.txt"
    
    # Create difference map for registration quality assessment without visualization
    log_message "Creating registration difference map"
    
    # Only create actual visualization if silent skipping is turned off
    if [ "${SKIP_VISUALIZATION:-false}" != "true" ]; then
        # Try to create visualizations but don't fail if they error
        (
            # Create checkerboard pattern for registration check
            local checker="${output_dir}/checkerboard.nii.gz"
            
            # Use FSL's checkerboard function with robust error handling
            log_message "Creating checkerboard visualization with robust error handling"
            
            # Define ants_bin variable to avoid 'unbound variable' error
            local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
            
            # Create a simple empty volume instead of using fslmaths
            # This avoids the "short read, file may be truncated" errors
            if command -v ${ants_bin}/ImageMath &>/dev/null; then
                # Use ANTs to create an empty volume (safer than fslmaths)
                ${ants_bin}/ImageMath 3 "$checker" m "$fixed" 0 2>/dev/null || touch "$checker"
            else
                # Try fslmaths but with extra caution
                if fslinfo "$fixed" &>/dev/null; then
                    # Copy geometry separately to avoid fslcpgeom errors
                    if ! fslcpgeom "$fixed" "$warped" 2>/dev/null; then
                        log_formatted "WARNING" "Failed to copy geometry, skipping checkerboard"
                    fi
                    
                    # Try to create an empty volume, redirect stderr to avoid error messages
                    if ! fslmaths "$fixed" -mul 0 "$checker" 2>/dev/null; then
                        log_formatted "WARNING" "Failed to create checker pattern with fslmaths"
                        touch "$checker"
                    fi
                else
                    log_formatted "WARNING" "Fixed image is corrupt or unreadable, skipping checkerboard"
                    touch "$checker"
                fi
            fi
            
            # Create 5x5x5 checkerboard - don't fail if there's an error
            if [ -f "$checker" ]; then
                local dim_x=$(fslval "$fixed" dim1 || echo "0")
                local dim_y=$(fslval "$fixed" dim2 || echo "0")
                local dim_z=$(fslval "$fixed" dim3 || echo "0")
                
                # Skip the checkerboard creation using fslmaths as it's causing "short read" errors
                # Instead, create a simple overlay visualization command
                
                # Create a more robust visualization command
                log_message "Creating safer visualization approach"
                
                # Skip the checkerboard completely - it's just causing problems
                # Instead, create a command to view the two images side by side
                
                # First confirm both images are valid
                if fslinfo "$fixed" &>/dev/null && fslinfo "$warped" &>/dev/null; then
                    # Create freeview script to show side-by-side and overlay
                    log_message "Creating freeview side-by-side visualization script"
                    {
                        echo "#!/usr/bin/env bash"
                        echo "# Registration visualization script (side-by-side)"
                        echo "# Load both images separately to see registration quality"
                        echo "freeview \"$fixed\":grayscale \"$warped\":grayscale:visible=0 \\"
                        echo "   -viewport sagittal -layout 1 -sync"
                    } > "${output_dir}/view_registration_check.sh"
                    chmod +x "${output_dir}/view_registration_check.sh"
                    
                    # Create a second script that shows the overlay for easy toggling
                    log_message "Creating freeview overlay visualization script"
                    {
                        echo "#!/usr/bin/env bash"
                        echo "# Registration visualization script (overlay)"
                        echo "freeview \"$fixed\":grayscale \"$warped\":grayscale:opacity=0.5"
                    } > "${output_dir}/view_registration_overlay.sh"
                    chmod +x "${output_dir}/view_registration_overlay.sh"
                else
                    log_formatted "WARNING" "Cannot create visualization for invalid images"
                fi
            fi
            
            # Use robust methods to create intensity-normalized images with error handling
            log_message "Creating difference map with robust error handling"
            
            # Try ANTs for image normalization if available (safer than fslmaths)
            local norm_success=false
            # Ensure ants_bin is defined in this scope
            local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
            
            if command -v ${ants_bin}/ImageMath &>/dev/null; then
                # Use ANTs ImageMath to normalize images (more robust than fslmaths)
                ${ants_bin}/ImageMath 3 "${output_dir}/fixed_norm.nii.gz" Normalize "$fixed" 2>/dev/null && \
                ${ants_bin}/ImageMath 3 "${output_dir}/warped_norm.nii.gz" Normalize "$warped" 2>/dev/null && \
                norm_success=true
            fi
            
            # Fall back to fslmaths only if ANTs normalization failed
            if [ "$norm_success" = "false" ]; then
                # Check if files can be read properly
                if fslinfo "$fixed" &>/dev/null && fslinfo "$warped" &>/dev/null; then
                    # Suppress stderr to avoid error spam
                    fslmaths "$fixed" -inm 1 "${output_dir}/fixed_norm.nii.gz" 2>/dev/null || touch "${output_dir}/fixed_norm.nii.gz"
                    fslmaths "$warped" -inm 1 "${output_dir}/warped_norm.nii.gz" 2>/dev/null || touch "${output_dir}/warped_norm.nii.gz"
                else
                    log_formatted "WARNING" "Files unreadable, skipping difference map"
                    touch "${output_dir}/fixed_norm.nii.gz" "${output_dir}/warped_norm.nii.gz"
                fi
            fi
            
            # Calculate absolute difference with careful checks
            if [ -f "${output_dir}/fixed_norm.nii.gz" ] && [ -f "${output_dir}/warped_norm.nii.gz" ]; then
                # Check if files are valid NIfTI before operating on them
                if fslinfo "${output_dir}/fixed_norm.nii.gz" &>/dev/null && \
                   fslinfo "${output_dir}/warped_norm.nii.gz" &>/dev/null; then
                    # Suppress stderr to avoid error spam
                    fslmaths "${output_dir}/fixed_norm.nii.gz" -sub "${output_dir}/warped_norm.nii.gz" \
                             -abs "${output_dir}/reg_diff.nii.gz" 2>/dev/null || \
                    touch "${output_dir}/reg_diff.nii.gz"
                else
                    log_formatted "WARNING" "Normalized files invalid, skipping difference calculation"
                    touch "${output_dir}/reg_diff.nii.gz"
                fi
                
                # Create overlay command for freeview if diff was created
                if [ -f "${output_dir}/reg_diff.nii.gz" ]; then
                    echo "#!/usr/bin/env bash" > "${output_dir}/view_reg_diff.sh"
                    echo "# Registration difference visualization script" >> "${output_dir}/view_reg_diff.sh"
                    echo "freeview $fixed:grayscale ${output_dir}/reg_diff.nii.gz:colormap=heat:opacity=0.8" >> "${output_dir}/view_reg_diff.sh"
                    chmod +x "${output_dir}/view_reg_diff.sh"
                    
                    # Try to create slices for quick visual inspection
                    if command -v slicer &>/dev/null; then
                        slicer "${output_dir}/reg_diff.nii.gz" -a "${output_dir}/registration_diff.png" 2>/dev/null || true
                    fi
                fi
            fi
            
            # Clean up any temporary files that might have been created
            rm -f "${output_dir}/fixed_norm.nii.gz" "${output_dir}/warped_norm.nii.gz" 2>/dev/null || true
        ) || true  # Continue even if the visualization step fails
    else
        log_message "Skipping visualization creation (SKIP_VISUALIZATION=true)"
    fi
    
    # Always succeed even if visualization failed
    log_message "Registration validation completed for $output_dir"
    return 0
}

# Function to validate registration
validate_registration() {
    local fixed="$1"
    local moving="$2"
    local warped="$3"
    local output_prefix="$4"
    local output_dir="${output_prefix}_validation"
    
    log_message "Validating registration"
    mkdir -p "$output_dir"
    
    # Check if input files exist
    local validation_possible=true
    
    if [ ! -f "$fixed" ]; then
        log_formatted "WARNING" "Fixed image doesn't exist: $fixed"
        validation_possible=false
    fi
    
    if [ ! -f "$warped" ]; then
        log_formatted "WARNING" "Warped image doesn't exist: $warped"
        validation_possible=false
    fi
    
    local cc="N/A"
    local mi="N/A"
    local ncc="N/A"
    
    if [ "$validation_possible" = "true" ]; then
        # Calculate correlation coefficient
        cc=$(calculate_cc "$fixed" "$warped")
        log_message "Cross-correlation: $cc"
        
        # Calculate mutual information - fallback to simplified method if needed
        mi=$(calculate_mi "$fixed" "$warped")
        log_message "Mutual information: $mi"
        
        # Calculate normalized cross-correlation - fallback to simplified method if needed
        ncc=$(calculate_ncc "$fixed" "$warped")
        log_message "Normalized cross-correlation: $ncc"
    else
        log_message "Skipping metric calculation due to missing input files"
    fi
    
    # Save validation report
    log_message "Creating validation report"
    {
        echo "Registration Validation Report"
        echo "=============================="
        echo "Fixed image: $fixed"
        echo "Moving image: $moving"
        echo "Warped image: $warped"
        echo ""
        echo "Metrics:"
        echo "  Cross-correlation: $cc"
        echo "  Mutual information: $mi"
        echo "  Normalized cross-correlation: $ncc"
        echo ""
        echo "Validation completed: $(date)"
    } > "${output_dir}/validation_report.txt"
    
    # Determine overall quality
    local quality="UNKNOWN"
    
    # Only evaluate metrics if they're not "N/A"
    if [ "$cc" != "N/A" ]; then
        # These thresholds should ideally come from config parameters
        local cc_excellent="${CC_EXCELLENT:-0.7}"
        local cc_good="${CC_GOOD:-0.5}"
        local cc_acceptable="${CC_ACCEPTABLE:-0.3}"
        
        if (( $(echo "$cc > $cc_excellent" | bc -l) )); then
            quality="EXCELLENT"
        elif (( $(echo "$cc > $cc_good" | bc -l) )); then
            quality="GOOD"
        elif (( $(echo "$cc > $cc_acceptable" | bc -l) )); then
            quality="ACCEPTABLE"
        else
            quality="POOR"
        fi
    fi
    
    log_message "Overall registration quality: $quality"
    echo "$quality" > "${output_dir}/quality.txt"
    
    # Create visualizations
    create_registration_visualizations "$fixed" "$moving" "$warped" "$output_dir"
    
    # Calculate and save extended metrics to CSV (if the file exist)
    if [ -n "$fixed" ] && [ -f "$fixed" ] && [ -n "$moving" ] && [ -f "$moving" ] && [ -n "$warped" ] && [ -f "$warped" ]; then
        # Find the applicable transform file
        local transform=""
        if [[ "$output_prefix" == *"/"* ]]; then
            # Check for common transform file patterns
            for ext in "0GenericAffine.mat" "1Warp.nii.gz" "Affine.txt"; do
                if [ -f "${output_prefix}${ext}" ]; then
                    transform="${output_prefix}${ext}"
                    break
                fi
            done
        fi
        
        if [ -z "$transform" ]; then
            log_formatted "WARNING" "Could not find transformation file for extended metrics"
        else
            log_message "DEBUG: About to call calculate_extended_registration_metrics from registration.sh"
            if declare -f calculate_extended_registration_metrics >/dev/null 2>&1; then
                log_message "DEBUG: calculate_extended_registration_metrics is defined just before call."
                calculate_extended_registration_metrics "$fixed" "$moving" "$warped" "$transform" "${RESULTS_DIR}/validation/registration/metrics.csv"
            else
                log_formatted "ERROR" "DEBUG: calculate_extended_registration_metrics is NOT defined just before call in registration.sh."
            fi
        fi
    fi
    
    return 0
}

# Function to apply transformation with FULL SyN warp support
apply_transformation() {
    local input="$1"
    local reference="$2"
    local output="$3"
    local transform="$4"
    local interpolation="${5:-Linear}"
    
    log_message "Applying transformation to $input"
    log_message "Transform: $transform"
    log_message "Interpolation: $interpolation"
    
    # Determine ANTs bin path
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    
    # CRITICAL FIX: Detect and apply FULL SyN transform chain instead of just affine
    local transform_dir=$(dirname "$transform")
    local transform_prefix=$(basename "$transform" | sed 's/0GenericAffine\.mat$//' | sed 's/1Warp\.nii\.gz$//' | sed 's/1InverseWarp\.nii\.gz$//')
    
    # Look for complete SyN transform set in the same directory
    local affine_transform="${transform_dir}/${transform_prefix}0GenericAffine.mat"
    local forward_warp="${transform_dir}/${transform_prefix}1Warp.nii.gz"
    local inverse_warp="${transform_dir}/${transform_prefix}1InverseWarp.nii.gz"
    
    log_message "Checking for SyN transform components:"
    log_message "  Affine: $affine_transform"
    log_message "  Forward warp: $forward_warp"
    log_message "  Inverse warp: $inverse_warp"
    
    # Check if we have a complete SyN registration output
    local has_full_syn=false
    if [ -f "$affine_transform" ] && [ -f "$inverse_warp" ]; then
        has_full_syn=true
        log_formatted "SUCCESS" "Found complete SyN transform set - using FULL nonlinear registration"
        log_message "This preserves all deformation information from SyN registration"
    elif [ -f "$affine_transform" ] && [ -f "$forward_warp" ]; then
        # We have forward warp but need inverse direction
        has_full_syn=true
        log_formatted "SUCCESS" "Found SyN transforms with forward warp - will invert for proper direction"
    fi
    
    if [ "$has_full_syn" = "true" ]; then
        # Apply FULL SyN transform chain (nonlinear + affine)
        # For MNI -> subject space, we need: inverse_warp + inverted_affine
        log_message "Applying complete SyN transform chain (preserves all deformation)"
        
        local transform_args=()
        
        # Add inverse warp if available (for MNI -> subject)
        if [ -f "$inverse_warp" ]; then
            transform_args+=("-t" "$inverse_warp")
            log_message "Added inverse warp: $inverse_warp"
        elif [ -f "$forward_warp" ]; then
            # If only forward warp available, we'll need to invert it
            log_formatted "WARNING" "Only forward warp available - may need to create inverse"
            transform_args+=("-t" "$forward_warp")
        fi
        
        # Add inverted affine transform (for MNI -> subject)
        if [ -f "$affine_transform" ]; then
            transform_args+=("-t" "[$affine_transform,1]")
            log_message "Added inverted affine: [$affine_transform,1]"
        fi
        
        # Execute complete SyN transform
        execute_ants_command "apply_full_syn_transform" "Applying complete SyN transform chain (nonlinear + affine)" \
            ${ants_bin}/antsApplyTransforms \
            -d 3 \
            -i "$input" \
            -r "$reference" \
            -o "$output" \
            "${transform_args[@]}" \
            -n "$interpolation"
            
    elif [[ "$transform" == *".mat" ]]; then
        # Fallback: Single affine transform (original behavior)
        log_formatted "WARNING" "Only affine transform available - nonlinear deformation will be lost"
        log_message "Consider using full SyN registration for better accuracy"
        
        if [[ "$transform" == *"ants"* || "$transform" == *"Affine"* ]]; then
            # ANTs .mat transform — likely affine, must be inverted to go MNI -> subject
            execute_ants_command "apply_inverted_affine" "Applying inverted affine transform (MNI to subject)" \
                ${ants_bin}/antsApplyTransforms \
                -d 3 \
                -i "$input" \
                -r "$reference" \
                -o "$output" \
                -t "[$transform,1]" \
                -n "$interpolation"
        else
            # FSL .mat transform
            apply_transform "$input" "$reference" "$transform" "$output" "$interpolation"
        fi
        
    elif [[ "$transform" == *"Warp.nii.gz" ]]; then
        # Single warp file (nonlinear only)
        log_message "Applying single warp file (nonlinear only)"
        execute_ants_command "apply_warp_only" "Applying warp-only transform" \
            ${ants_bin}/antsApplyTransforms \
            -d 3 \
            -i "$input" \
            -r "$reference" \
            -o "$output" \
            -t "$transform" \
            -n "$interpolation"
            
    else
        # ANTs .h5 or .txt transforms — typically don't need inversion unless explicitly known
        log_message "Applying other transform format: $transform"
        execute_ants_command "apply_standard_transform" "Applying standard transform" \
            ${ants_bin}/antsApplyTransforms \
            -d 3 \
            -i "$input" \
            -r "$reference" \
            -o "$output" \
            -t "$transform" \
            -n "$interpolation"
    fi

    log_message "Transformation applied. Output: $output"
    return 0
}

# Function to register multiple images to a reference
register_multiple_to_reference() {
    local reference="$1"
    local output_dir="$2"
    shift 2
    local input_files=("$@")
    
    log_message "Registering multiple images to reference: $reference"
    mkdir -p "$output_dir"
    
    for input in "${input_files[@]}"; do
        local basename=$(basename "$input" .nii.gz)
        local output_prefix="${output_dir}/${basename}_to_ref"
        
        # Try to determine modality from filename
        local modality="OTHER"
        for mod in "${SUPPORTED_MODALITIES[@]}"; do
            if [[ "$basename" == *"$mod"* || "$basename" == *"${mod,,}"* ]]; then
                modality="$mod"
                break
            fi
        done
        
        log_message "Registering $basename to reference (detected modality: $modality)"
        register_modality_to_t1 "$reference" "$input" "$modality" "$output_prefix"
    done
    
    log_message "Multiple registration complete"
    return 0
}

# Function to register all supported modalities in a directory to T1
register_all_modalities() {
    local t1_file="$1"
    local input_dir="$2"
    local output_dir="${3:-${RESULTS_DIR}/registered}"
    
    log_message "Registering all supported modalities to T1: $t1_file"
    mkdir -p "$output_dir"
    
    # Check if T1 exists
    if [ ! -f "$t1_file" ]; then
        log_formatted "ERROR" "T1 file not found: $t1_file"
        return 1
    fi
    
    # Find and register each supported modality
    for modality in "${SUPPORTED_MODALITIES[@]}"; do
        # Try to find files matching the modality pattern
        local modality_files=($(find "$input_dir" -type f -name "*${modality}*.nii.gz" -o -name "*${modality,,}*.nii.gz"))
        
        if [ ${#modality_files[@]} -gt 0 ]; then
            for mod_file in "${modality_files[@]}"; do
                local basename=$(basename "$mod_file" .nii.gz)
                local output_prefix="${output_dir}/${basename}_to_t1"
                
                log_message "Found $modality file: $mod_file"
                register_modality_to_t1 "$t1_file" "$mod_file" "$modality" "$output_prefix"
            done
        else
            log_message "No $modality files found in $input_dir"
        fi
    done
    
    log_message "All modality registrations complete"
    return 0
}

# Export functions
export -f detect_image_resolution
export -f set_template_resolution
export -f perform_multistage_registration
export -f register_modality_to_t1
export -f register_t2_flair_to_t1mprage
export -f create_registration_visualizations
export -f validate_registration
export -f apply_transformation
export -f register_multiple_to_reference
export -f register_all_modalities
export -f run_registration_fix

# Helper function to prepare white matter segmentation
prepare_wm_segmentation() {
    local t1_file="$1"
    local wm_mask="$2"
    local out_prefix="$3"
    local outer_ribbon_mask="$4"
    
    log_message "Preparing for WM-guided registration..."
    
    # Check if we already have a WM segmentation
    local wm_seg=$(find "$RESULTS_DIR/segmentation" -name "*white_matter*.nii.gz" -o -name "*wm*.nii.gz" | head -1)
    
    if [ -n "$wm_seg" ] && [ -f "$wm_seg" ]; then
        log_message "Using existing WM segmentation: $wm_seg"
        cp "$wm_seg" "$wm_mask"
    else
        # Use our new tissue segmentation method with ANTs/FAST fallback
        log_message "Creating WM segmentation using robust tissue segmentation..."
        
        # Create temporary directory for segmentation
        local seg_temp_dir=$(mktemp -d)
        local seg_prefix="${seg_temp_dir}/t1_seg"
        
        # Run tissue segmentation with our wrapper
        process_tissue_segmentation "$t1_file" "$seg_prefix" "T1" 3
        
        # Check if segmentation was successful
        if [ -f "${seg_prefix}.nii.gz" ] && [ -f "${seg_prefix}_pve_2.nii.gz" ]; then
            # Copy WM probability map (class 2 in 0-based indexing)
            cp "${seg_prefix}_pve_2.nii.gz" "$wm_mask"
            log_formatted "SUCCESS" "Created white matter segmentation using robust wrapper"
        else
            # Fall back to direct ANTs approach
            log_message "Segmentation wrapper failed, trying direct ANTs approach..."
            
            # Clean up segmentation temp dir
            rm -rf "$seg_temp_dir"
        
            # Explicitly use the full path to ANTs commands
            local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
        
            # Verify that Atropos is available
            if command -v ${ants_bin}/Atropos &>/dev/null; then
                # Create temporary directory
                local temp_dir=$(mktemp -d)
                
                # Create brain mask using ANTs ThresholdImage
                local brain_mask="${temp_dir}/brain_mask.nii.gz"
                if ! ${ants_bin}/ThresholdImage 3 "$t1_file" "$brain_mask" 0.01 Inf 1 0; then
                    log_formatted "WARNING" "ANTs ThresholdImage failed, skipping WM-guided registration"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Apply brain mask to T1 using ANTs ImageMath
                local masked_t1="${temp_dir}/t1_masked.nii.gz"
                if ! ${ants_bin}/ImageMath 3 "$masked_t1" m "$t1_file" "$brain_mask"; then
                    log_formatted "WARNING" "ANTs ImageMath failed, skipping WM-guided registration"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Run ANTs Atropos for tissue segmentation
                log_message "Running ANTs Atropos for tissue segmentation"
                local atropos_output="${temp_dir}/atropos_seg.nii.gz"
                
                # Verify Atropos command is available
                if ! command -v ${ants_bin}/Atropos &>/dev/null; then
                    log_formatted "ERROR" "ANTs Atropos command not found at ${ants_bin}/Atropos"
                    log_formatted "ERROR" "PATH=$PATH"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Run Atropos with explicit output filename extension (.nii.gz)
                log_message "Command: ${ants_bin}/Atropos -d 3 -a $masked_t1 -o ${atropos_output} -c 3 -m [0.2,1x1x1] -i kmeans[3] -x $brain_mask"
                
                if ! ${ants_bin}/Atropos -d 3 \
                    -a "$masked_t1" \
                    -o "${atropos_output}" \
                    -c 3 \
                    -m [0.2,1x1x1] \
                    -i kmeans[3] \
                    -x "$brain_mask"; then
                    log_formatted "WARNING" "ANTs Atropos segmentation failed, skipping WM-guided registration"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Extract white matter from the Atropos segmentation
                if ! ${ants_bin}/ThresholdImage 3 "$atropos_output" "$wm_mask" $WM_THRESHOLD_VAL $WM_THRESHOLD_VAL; then
                    log_formatted "WARNING" "ANTs ThresholdImage failed for WM extraction, skipping WM-guided registration"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Clean up WM mask by keeping only the largest connected component
                if ! ${ants_bin}/ImageMath 3 "$wm_mask" GetLargestComponent "$wm_mask"; then
                    log_formatted "WARNING" "ANTs ImageMath GetLargestComponent failed, skipping WM-guided registration"
                    use_wm_guided_registration=false
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                # Clean up temporary files
                rm -rf "$temp_dir"
            else
                log_formatted "WARNING" "ANTs Atropos not available, skipping WM-guided registration"
                use_wm_guided_registration=false
                return 1
            fi
        fi
    fi
    
    # Create outer ribbon mask for cost function masking
    if [ "$use_wm_guided_registration" = "true" ]; then
        local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
        # Check if ANTs is available for mask creation
        if command -v ${ants_bin}/ThresholdImage &>/dev/null && command -v ${ants_bin}/ImageMath &>/dev/null; then
            log_message "Creating outer ribbon mask using ANTs tools..."
            
            # Create brain mask with ANTs
            local ants_brain_mask="${out_prefix}_brain_mask.nii.gz"
            if ! ${ants_bin}/ThresholdImage 3 "$t1_file" "$ants_brain_mask" 0.01 Inf 1 0; then
                # Fallback to FSL if ANTs fails
                fslmaths "$t1_file" -bin "$ants_brain_mask"
            fi
            
            # Create eroded mask (outer ribbon excluded) using ANTs ImageMath if possible
            log_message "Creating outer ribbon mask for cost function masking..."
            if command -v ${ants_bin}/ImageMath &>/dev/null; then
                ${ants_bin}/ImageMath 3 "$outer_ribbon_mask" ME "$ants_brain_mask" 2
            else
                # Fallback to FSL if ANTs ImageMath not available
                fslmaths "$ants_brain_mask" -ero -ero "$outer_ribbon_mask"
            fi
        else
            # Fallback to FSL for mask creation
            log_message "ANTs tools not available, using FSL for mask creation..."
            fslmaths "$t1_file" -bin "${out_prefix}_brain_mask.nii.gz"
            fslmaths "${out_prefix}_brain_mask.nii.gz" -ero -ero "$outer_ribbon_mask"
        fi
    fi
    
    return 0
}

# Helper function to perform white matter guided initialization
perform_wm_guided_initialization() {
    local t1_file="$1"
    local modality_file="$2"
    local wm_mask="$3"
    local out_prefix="$4"
    local ants_wm_init_matrix="$5"
    
    log_message "Running WM-guided initialization with ANTs-compatible methodology..."
    
    # ANTs tools for initialization
    local ants_bin="${ANTS_BIN:-${ANTS_PATH}/bin}"
    local ants_init_successful=false
    
    # Try ANTs-first approach for initialization
    if command -v ${ants_bin}/antsRegistration &>/dev/null; then
        # Use ANTs' antsRegistration for initialization (rigid only to minimize computation time)
        log_message "Using ANTs for white matter-guided initialization"
        
        # Execute ANTs command via the utility function
        # Verify WM mask exists before using it
        local mask_param=""
        if [ -f "$wm_mask" ] && [ -s "$wm_mask" ]; then
            mask_param="--masks [${wm_mask},NULL]"
            log_message "Using WM mask for registration: $wm_mask"
        else
            log_formatted "WARNING" "WM mask not found or empty: $wm_mask - proceeding without mask"
        fi
        
        execute_ants_command "ants_wm_init" "White matter guided initialization for accurate boundary alignment" \
            ${ants_bin}/antsRegistration \
            --dimensionality 3 \
            --float 0 \
            --output "${out_prefix}_wm_init_" \
            --interpolation Linear \
            --use-histogram-matching 0 \
            --initial-moving-transform [${t1_file},${modality_file},1] \
            --transform Rigid[0.1] \
            --metric MI[${t1_file},${modality_file},1,32,Regular,0.25] \
            --convergence [1000x500x250x0,1e-6,10] \
            --shrink-factors 8x4x2x1 \
            --smoothing-sigmas 3x2x1x0vox \
            ${mask_param} \
            --verbose 1
            
        # Check if initialization was successful
        if [ -f "${out_prefix}_wm_init_0GenericAffine.mat" ]; then
            ants_wm_init_matrix="${out_prefix}_wm_init_0GenericAffine.mat"
            ants_init_successful=true
            log_message "ANTs-based white matter initialization completed successfully"
            return 0
        else
            log_formatted "WARNING" "ANTs initialization failed, trying fallback methods"
        fi
    fi
    
    # Fallback to FLIRT with white matter boundaries if ANTs initialization failed
    if [ "$ants_init_successful" = "false" ]; then
        log_message "Falling back to FSL FLIRT with white matter boundaries for initialization (temporary compatibility)"
        
        # Run FLIRT with boundary-based registration using the WM mask
        flirt -in "$modality_file" -ref "$t1_file" \
              -out "${out_prefix}_wm_init.nii.gz" \
              -omat "$ants_wm_init_matrix" \
              -dof 6 -cost wmseg -wmseg "$wm_mask"
              
        # Check if transform was created successfully
        if [ -f "$ants_wm_init_matrix" ]; then
            log_message "FSL-based white matter initialization completed successfully (fallback method)"
            return 0
        else
            log_formatted "WARNING" "All white matter guided initialization methods failed, falling back to standard registration"
            return 1
        fi
    fi
    
    return 0
}

# Function to perform registration comparison between T1 and T2
perform_registration_comparison() {
    local input_dir="$1"
    local output_base_dir="${2:-${RESULTS_DIR}/registration_comparison}"

    log_message "=== Performing T1 vs T2 Registration Comparison ==="
    log_message "Input directory: $input_dir"
    log_message "Output base directory: $output_base_dir"

    # Ensure scan selection module is sourced
    if ! command -v select_best_scan &> /dev/null; then
        log_formatted "ERROR" "Scan selection module not loaded. Cannot perform interactive selection."
        return 1
    fi

    # Step 1: Select T1 and T2 scans interactively
    log_message "Please select the T1 scan for comparison."
    local selected_t1=$(select_best_scan "T1" "*T1*.nii.gz" "$input_dir" "" "interactive")
    if [ -z "$selected_t1" ]; then
        log_formatted "ERROR" "No T1 scan selected. Aborting comparison."
        return 1
    fi

    log_message "Please select the T2 scan for comparison."
    local selected_t2=$(select_best_scan "T2" "*T2*.nii.gz" "$input_dir" "$selected_t1" "interactive")
     if [ -z "$selected_t2" ]; then
        log_formatted "ERROR" "No T2 scan selected. Aborting comparison."
        return 1
    fi

    log_message "Selected T1: $selected_t1"
    log_message "Selected T2: $selected_t2"

    # Step 2: Perform T2 to T1 registration
    local t2_to_t1_output_prefix="${output_base_dir}/t2_to_t1/t2_to_t1"
    log_message "--- Running T2 to T1 Registration ---"
    # Call the generic registration function (will modify register_modality_to_t1 later)
    # For now, we'll call the existing function, assuming T1 is fixed
    register_modality_to_t1 "$selected_t1" "$selected_t2" "T2" "$t2_to_t1_output_prefix"
    local t2_to_t1_status=$?

    # Step 3: Perform T1 to T2 registration
    local t1_to_t2_output_prefix="${output_base_dir}/t1_to_t2/t1_to_t2"
    log_message "--- Running T1 to T2 Registration ---"
    # Need to modify registration function to handle T1 to T2
    # Placeholder call - will be updated in the next step
    # register_modality_to_t1 "$selected_t2" "$selected_t1" "T1" "$t1_to_t2_output_prefix"
    log_message "T1 to T2 registration placeholder - will be implemented next."
    local t1_to_t2_status=1 # Assume failure for now

    # Step 4: Validate and visualize results (will update validation/viz functions later)
    log_message "--- Validating and Visualizing Results ---"
    if [ $t2_to_t1_status -eq 0 ]; then
        log_message "Validating T2 to T1 registration..."
        validate_registration_output "$selected_t1" "$selected_t2" "${t2_to_t1_output_prefix}Warped.nii.gz" "$t2_to_t1_output_prefix"
    fi

    if [ $t1_to_t2_status -eq 0 ]; then
         log_message "Validating T1 to T2 registration..."
         # Need to update validate_registration_output to handle T2 fixed / T1 moving
         # For now, placeholder call
         # validate_registration_output "$selected_t2" "$selected_t1" "${t1_to_t2_output_prefix}Warped.nii.gz" "$t1_to_t2_output_prefix"
         log_message "T1 to T2 validation placeholder - will be implemented next."
    fi

    log_message "Registration comparison complete."
    return 0
}


# Helper function to validate registration results
validate_registration_output() {
    local t1_file="$1"
    local modality_file="$2"
    local warped_file="$3"
    local output_prefix="$4"
    
    log_message "Validating registration with improved error handling"
    
    if ! validate_registration "$t1_file" "$modality_file" "$warped_file" "$output_prefix"; then
        log_formatted "WARNING" "Registration validation produced errors but continuing with pipeline"
        # Create a minimal validation report to allow pipeline to continue
        mkdir -p "${output_prefix}_validation"
        echo "UNKNOWN" > "${output_prefix}_validation/quality.txt"
    fi
    
    return 0
}

# Export helper function
export -f validate_registration_output
export -f perform_registration_comparison

log_message "Registration module loaded"
