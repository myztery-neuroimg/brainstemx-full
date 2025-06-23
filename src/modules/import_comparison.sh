#!/usr/bin/env bash
#
# import_comparison.sh - DICOM import strategy comparison module
#
# This module provides functionality to compare different dcm2niix import strategies
# and generate detailed reports about their performance and output differences.
#

# Unset any existing functions to prevent conflicts
unset compare_import_strategies
unset test_import_strategy
unset generate_comparison_report
unset count_dicom_files

# Ensure logging functions are available (fallback if environment.sh not sourced)
if ! type log_message &>/dev/null; then
    log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
fi

if ! type log_formatted &>/dev/null; then
    log_formatted() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"; }
fi

if ! type log_error &>/dev/null; then
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2; }
fi

# Main comparison function
compare_import_strategies() {
    local dicom_dir="$1"
    local comparison_output_dir="${RESULTS_DIR}/import_strategy_comparison"
    
    log_formatted "INFO" "===== STARTING IMPORT STRATEGY COMPARISON ====="
    log_message "DICOM directory: $dicom_dir"
    log_message "Output directory: $comparison_output_dir"
    
    # Validate input directory
    if [ ! -d "$dicom_dir" ]; then
        log_formatted "ERROR" "DICOM directory does not exist: $dicom_dir"
        exit 1
    fi
    
    # Create comparison output directory
    mkdir -p "$comparison_output_dir"
    
    # Check if we have any DICOM files to work with
    local total_dicom_files=$(count_dicom_files "$dicom_dir")
    if [ "$total_dicom_files" -eq 0 ]; then
        log_formatted "WARNING" "No DICOM files found in $dicom_dir"
        echo "No DICOM files found for comparison" > "$comparison_output_dir/no_data.txt"
        log_formatted "INFO" "Import strategy comparison complete (no data to process). Exiting pipeline."
        exit 0
    fi
    
    log_message "Found $total_dicom_files DICOM files for comparison"
    
    # Clean up any previous comparison results
    log_message "Cleaning up previous comparison results..."
    rm -rf "${comparison_output_dir:?}"/*
    
    # Test each strategy
    log_formatted "INFO" "Testing strategy 1/4: PRESERVE_ALL_SLICES"
    test_import_strategy "PRESERVE_ALL_SLICES" "$dicom_dir" "${comparison_output_dir}/preserve_all"
    
    log_formatted "INFO" "Testing strategy 2/4: VENDOR_OPTIMIZED"
    test_import_strategy "VENDOR_OPTIMIZED" "$dicom_dir" "${comparison_output_dir}/vendor_optimized"
    
    log_formatted "INFO" "Testing strategy 3/4: CROP_TO_BRAIN"
    test_import_strategy "CROP_TO_BRAIN" "$dicom_dir" "${comparison_output_dir}/crop_to_brain"
    
    log_formatted "INFO" "Testing strategy 4/4: CUSTOM_NO_ANATOMICAL"
    test_import_strategy "CUSTOM_NO_ANATOMICAL" "$dicom_dir" "${comparison_output_dir}/custom_no_anatomical"
    
    # Generate comparison report
    log_formatted "INFO" "Generating comparison report..."
    generate_comparison_report "$comparison_output_dir"
    
    # Exit pipeline
    log_formatted "SUCCESS" "Import strategy comparison complete. Exiting pipeline."
    exit 0
}

# Test individual strategy
test_import_strategy() {
    local strategy="$1"
    local dicom_dir="$2"
    local output_dir="$3"
    
    log_formatted "INFO" "Testing import strategy: $strategy"
    mkdir -p "$output_dir"
    
    # Save current environment variables to restore later
    local saved_dicom_import_strategy="${DICOM_IMPORT_STRATEGY:-}"
    local saved_force_anatomical_preservation="${FORCE_ANATOMICAL_PRESERVATION:-}"
    local saved_dicom_vendor_flags="${DICOM_VENDOR_FLAGS:-}"
    
    # Set strategy-specific environment
    case "$strategy" in
        "PRESERVE_ALL_SLICES")
            export DICOM_IMPORT_STRATEGY="PRESERVE_ALL_SLICES"
            export DICOM_VENDOR_FLAGS="-m n -i n"
            log_message "Using flags: -m n -i n (preserve all slices and localizers)"
            ;;
        "VENDOR_OPTIMIZED")
            export DICOM_IMPORT_STRATEGY="VENDOR_OPTIMIZED"
            # Will use vendor detection from import_vendor_specific.sh
            log_message "Using vendor-specific optimizations"
            ;;
        "CROP_TO_BRAIN")
            export DICOM_IMPORT_STRATEGY="CROP_TO_BRAIN"
            export DICOM_VENDOR_FLAGS="-m y -i y"
            log_message "Using flags: -m y -i y (crop to brain, ignore localizers)"
            ;;
        "CUSTOM_NO_ANATOMICAL")
            export DICOM_IMPORT_STRATEGY="VENDOR_OPTIMIZED"
            export FORCE_ANATOMICAL_PRESERVATION="false"
            log_message "Using vendor optimization with anatomical preservation disabled"
            ;;
        *)
            log_formatted "ERROR" "Unknown strategy: $strategy"
            return 1
            ;;
    esac
    
    # Count input DICOM files
    local dicom_count=$(count_dicom_files "$dicom_dir")
    echo "DICOM_INPUT_COUNT=$dicom_count" > "$output_dir/metrics.txt"
    echo "STRATEGY=$strategy" >> "$output_dir/metrics.txt"
    echo "START_TIME=$(date)" >> "$output_dir/metrics.txt"
    
    # Run conversion with strategy-specific flags
    log_message "Starting dcm2niix conversion for $strategy..."
    
    # Build dcm2niix command based on strategy
    local dcm2niix_cmd="dcm2niix"
    local conversion_status="SUCCESS"
    
    case "$strategy" in
        "PRESERVE_ALL_SLICES")
            dcm2niix_cmd="dcm2niix -m n -i n -z y -f %p_%t_%s -o"
            log_message "Using flags: -m n -i n -z y (preserve all slices and localizers)"
            ;;
        "VENDOR_OPTIMIZED")
            dcm2niix_cmd="dcm2niix -ba y -z y -f %p_%t_%s -o"
            log_message "Using vendor-optimized flags: -ba y -z y"
            ;;
        "CROP_TO_BRAIN")
            dcm2niix_cmd="dcm2niix -m y -i y -x y -z y -f %p_%t_%s -o"
            log_message "Using flags: -m y -i y -x y -z y (crop to brain, ignore localizers)"
            ;;
        "CUSTOM_NO_ANATOMICAL")
            dcm2niix_cmd="dcm2niix -m y -z y -f %p_%t_%s -o"
            log_message "Using custom flags: -m y -z y (minimal anatomical preservation)"
            ;;
        *)
            dcm2niix_cmd="dcm2niix -z y -f %p_%t_%s -o"
            log_message "Using default flags with compression"
            ;;
    esac
    
    # Execute the conversion (process all DICOM files, filter outputs later)
    log_message "Running: $dcm2niix_cmd \"$output_dir\" \"$dicom_dir\""
    
    if command -v dcm2niix &>/dev/null; then
        if $dcm2niix_cmd "$output_dir" "$dicom_dir" 2>&1 | tee "$output_dir/conversion.log"; then
            conversion_status="SUCCESS"
            log_formatted "SUCCESS" "Conversion completed for $strategy"
        else
            conversion_status="FAILED"
            log_formatted "WARNING" "Conversion had issues for $strategy"
        fi
    else
        log_formatted "ERROR" "dcm2niix not found - cannot perform conversion"
        conversion_status="FAILED"
    fi
    
    # Apply filter to converted files if specified
    if [ -n "${COMPARISON_FILE_FILTER:-}" ] && [ "$conversion_status" = "SUCCESS" ]; then
        log_message "Applying filter to converted files: ${COMPARISON_FILE_FILTER}"
        
        # Move non-matching files to a filtered_out directory
        local filtered_out_dir="$output_dir/filtered_out"
        mkdir -p "$filtered_out_dir"
        
        local kept_files=0
        for nifti_file in "$output_dir"/*.nii.gz; do
            if [ -f "$nifti_file" ]; then
                local basename=$(basename "$nifti_file" .nii.gz)
                # Check if filename matches the filter pattern
                if echo "$basename" | grep -E "${COMPARISON_FILE_FILTER}" > /dev/null; then
                    kept_files=$((kept_files + 1))
                    log_message "Keeping file: $basename (matches filter)"
                else
                    # Move non-matching file to filtered_out directory
                    mv "$nifti_file" "$filtered_out_dir/"
                fi
            fi
        done
        
        log_message "Filter applied: kept $kept_files files matching pattern '${COMPARISON_FILE_FILTER}'"
        
        if [ "$kept_files" -eq 0 ]; then
            log_formatted "WARNING" "No converted files match filter pattern: ${COMPARISON_FILE_FILTER}"
        fi
    fi
    
    # Count output NIfTI files
    local nifti_count=$(find "$output_dir" -name "*.nii.gz" | wc -l)
    echo "NIFTI_OUTPUT_COUNT=$nifti_count" >> "$output_dir/metrics.txt"
    echo "CONVERSION_STATUS=$conversion_status" >> "$output_dir/metrics.txt"
    
    # Calculate conversion ratio (avoiding division by zero)
    if [ "$nifti_count" -gt 0 ]; then
        local conversion_ratio=$((dicom_count / nifti_count))
        echo "CONVERSION_RATIO=$conversion_ratio" >> "$output_dir/metrics.txt"
    else
        echo "CONVERSION_RATIO=0" >> "$output_dir/metrics.txt"
    fi
    
    # Analyze NIfTI quality metrics (if FSL is available)
    if command -v fslstats &>/dev/null && command -v fslinfo &>/dev/null; then
        log_message "Analyzing NIfTI file quality metrics..."
        
        local total_brain_voxels=0
        local total_volume_mm3=0
        local total_nonzero_voxels=0
        local max_intensity_range=0
        local file_count=0
        
        for nifti_file in "$output_dir"/*.nii.gz; do
            if [ -f "$nifti_file" ]; then
                local basename=$(basename "$nifti_file" .nii.gz)
                local quality_file="$output_dir/quality_${basename}.txt"
                
                log_message "Quality analysis for $basename..."
                
                # COMPLETENESS METRICS
                echo "=== QUALITY ANALYSIS: $basename ===" > "$quality_file"
                echo "" >> "$quality_file"
                echo "COMPLETENESS METRICS:" >> "$quality_file"
                
                local total_voxels=$(fslstats "$nifti_file" -V 2>/dev/null | awk '{print $1}' || echo '0')
                local volume_mm3=$(fslstats "$nifti_file" -V 2>/dev/null | awk '{print $2}' || echo '0')
                local nonzero_voxels=$(fslstats "$nifti_file" -l 0.1 -V 2>/dev/null | awk '{print $1}' || echo '0')
                
                echo "TOTAL_VOXELS: $total_voxels" >> "$quality_file"
                echo "VOLUME_MM3: $volume_mm3" >> "$quality_file"
                echo "NONZERO_VOXELS: $nonzero_voxels" >> "$quality_file"
                
                # Calculate information density
                if [ "$total_voxels" -gt 0 ] && command -v bc &>/dev/null; then
                    local info_density=$(echo "scale=4; $nonzero_voxels / $total_voxels * 100" | bc)
                    echo "INFORMATION_DENSITY_PCT: $info_density" >> "$quality_file"
                else
                    echo "INFORMATION_DENSITY_PCT: N/A" >> "$quality_file"
                fi
                
                # ORIENTATION AND GEOMETRY METRICS
                echo "" >> "$quality_file"
                echo "ORIENTATION_AND_GEOMETRY:" >> "$quality_file"
                
                # Get critical dimensions and orientation info
                local dims=$(fslinfo "$nifti_file" 2>/dev/null | grep -E "^dim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                local pixdims=$(fslinfo "$nifti_file" 2>/dev/null | grep -E "^pixdim[1-3]" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
                local datatype=$(fslinfo "$nifti_file" 2>/dev/null | grep "^datatype" | awk '{print $2}')
                
                # Use fslorient for reliable qform/sform code extraction
                local qform_code=$(fslorient -getqformcode "$nifti_file" 2>/dev/null || echo "0")
                local sform_code=$(fslorient -getsformcode "$nifti_file" 2>/dev/null || echo "0")
                local orientation=$(fslorient -getorient "$nifti_file" 2>/dev/null || echo "UNKNOWN")
                
                echo "DIMENSIONS: $dims" >> "$quality_file"
                echo "VOXEL_SIZE_MM: $pixdims" >> "$quality_file"
                echo "DATATYPE: $datatype" >> "$quality_file"
                echo "QFORM_CODE: $qform_code" >> "$quality_file"
                echo "SFORM_CODE: $sform_code" >> "$quality_file"
                echo "ORIENTATION: $orientation" >> "$quality_file"
                
                # Check for valid orientation codes (more comprehensive)
                if [ "$qform_code" = "1" ] || [ "$qform_code" = "2" ] || [ "$qform_code" = "3" ] || [ "$qform_code" = "4" ] || \
                   [ "$sform_code" = "1" ] || [ "$sform_code" = "2" ] || [ "$sform_code" = "3" ] || [ "$sform_code" = "4" ]; then
                    echo "ORIENTATION_STATUS: VALID" >> "$quality_file"
                elif [ "$qform_code" = "0" ] && [ "$sform_code" = "0" ]; then
                    echo "ORIENTATION_STATUS: UNKNOWN" >> "$quality_file"
                else
                    echo "ORIENTATION_STATUS: WARNING" >> "$quality_file"
                fi
                
                # INTENSITY AND CONTRAST METRICS
                echo "" >> "$quality_file"
                echo "INTENSITY_AND_CONTRAST:" >> "$quality_file"
                
                local min_val=$(fslstats "$nifti_file" -R 2>/dev/null | awk '{print $1}' || echo '0')
                local max_val=$(fslstats "$nifti_file" -R 2>/dev/null | awk '{print $2}' || echo '0')
                local mean_val=$(fslstats "$nifti_file" -M 2>/dev/null || echo '0')
                local std_val=$(fslstats "$nifti_file" -S 2>/dev/null || echo '0')
                local median_val=$(fslstats "$nifti_file" -P 50 2>/dev/null || echo '0')
                local p95_val=$(fslstats "$nifti_file" -P 95 2>/dev/null || echo '0')
                local p05_val=$(fslstats "$nifti_file" -P 5 2>/dev/null || echo '0')
                
                echo "MIN_INTENSITY: $min_val" >> "$quality_file"
                echo "MAX_INTENSITY: $max_val" >> "$quality_file"
                echo "MEAN_INTENSITY: $mean_val" >> "$quality_file"
                echo "STD_INTENSITY: $std_val" >> "$quality_file"
                echo "MEDIAN_INTENSITY: $median_val" >> "$quality_file"
                echo "P95_INTENSITY: $p95_val" >> "$quality_file"
                echo "P05_INTENSITY: $p05_val" >> "$quality_file"
                
                # Calculate dynamic range and contrast metrics
                if command -v bc &>/dev/null; then
                    local intensity_range=$(echo "scale=2; $max_val - $min_val" | bc)
                    local contrast_ratio=$(echo "scale=4; if ($mean_val > 0) $std_val / $mean_val else 0" | bc)
                    local signal_range=$(echo "scale=2; $p95_val - $p05_val" | bc)
                    
                    echo "INTENSITY_RANGE: $intensity_range" >> "$quality_file"
                    echo "CONTRAST_RATIO: $contrast_ratio" >> "$quality_file"
                    echo "SIGNAL_RANGE_P95_P05: $signal_range" >> "$quality_file"
                    
                    # Track max intensity range across files
                    if (( $(echo "$intensity_range > $max_intensity_range" | bc -l) )); then
                        max_intensity_range=$intensity_range
                    fi
                else
                    echo "INTENSITY_RANGE: N/A" >> "$quality_file"
                    echo "CONTRAST_RATIO: N/A" >> "$quality_file"
                    echo "SIGNAL_RANGE_P95_P05: N/A" >> "$quality_file"
                fi
                
                # DATA INTEGRITY CHECKS
                echo "" >> "$quality_file"
                echo "DATA_INTEGRITY:" >> "$quality_file"
                
                # Check for NaN or infinite values (basic check)
                local has_nan="false"
                local has_inf="false"
                if fslstats "$nifti_file" -R 2>/dev/null | grep -q "nan\|inf"; then
                    has_nan="true"
                fi
                echo "HAS_NAN_VALUES: $has_nan" >> "$quality_file"
                echo "HAS_INF_VALUES: $has_inf" >> "$quality_file"
                
                # Check if file appears truncated (very low max value might indicate issues)
                if command -v bc &>/dev/null && (( $(echo "$max_val < 10" | bc -l) )); then
                    echo "INTENSITY_WARNING: MAX_VALUE_VERY_LOW" >> "$quality_file"
                else
                    echo "INTENSITY_WARNING: NONE" >> "$quality_file"
                fi
                
                # Accumulate overall metrics
                total_brain_voxels=$((total_brain_voxels + nonzero_voxels))
                total_volume_mm3=$(echo "$total_volume_mm3 + $volume_mm3" | bc 2>/dev/null || echo "$total_volume_mm3")
                total_nonzero_voxels=$((total_nonzero_voxels + nonzero_voxels))
                file_count=$((file_count + 1))
            fi
        done
        
        # Generate strategy-level quality summary
        echo "STRATEGY_QUALITY_SUMMARY" > "$output_dir/strategy_quality.txt"
        echo "FILES_ANALYZED: $file_count" >> "$output_dir/strategy_quality.txt"
        echo "TOTAL_BRAIN_VOXELS: $total_brain_voxels" >> "$output_dir/strategy_quality.txt"
        echo "TOTAL_VOLUME_MM3: $total_volume_mm3" >> "$output_dir/strategy_quality.txt"
        echo "MAX_INTENSITY_RANGE: $max_intensity_range" >> "$output_dir/strategy_quality.txt"
        
        if [ "$file_count" -gt 0 ]; then
            local avg_brain_voxels=$((total_brain_voxels / file_count))
            echo "AVG_BRAIN_VOXELS_PER_FILE: $avg_brain_voxels" >> "$output_dir/strategy_quality.txt"
        fi
        
    else
        log_formatted "WARNING" "FSL not available - skipping quality analysis"
        echo "QUALITY_ANALYSIS_UNAVAILABLE=true" >> "$output_dir/metrics.txt"
    fi
    
    # Restore environment variables
    if [ -n "$saved_dicom_import_strategy" ]; then
        export DICOM_IMPORT_STRATEGY="$saved_dicom_import_strategy"
    else
        unset DICOM_IMPORT_STRATEGY
    fi
    
    if [ -n "$saved_force_anatomical_preservation" ]; then
        export FORCE_ANATOMICAL_PRESERVATION="$saved_force_anatomical_preservation"
    else
        unset FORCE_ANATOMICAL_PRESERVATION
    fi
    
    if [ -n "$saved_dicom_vendor_flags" ]; then
        export DICOM_VENDOR_FLAGS="$saved_dicom_vendor_flags"
    else
        unset DICOM_VENDOR_FLAGS
    fi
    
    log_formatted "SUCCESS" "Strategy $strategy completed: $nifti_count files"
}

# Generate comparison report
generate_comparison_report() {
    local comparison_dir="$1"
    
    log_message "================================================================="
    log_message "DICOM Import Strategy Quality Comparison Report - $(date)"
    log_message "================================================================="
    
    # Build a list of all unique filenames across strategies
    declare -A all_files
    for strategy_dir in "$comparison_dir"/*; do
        if [ -d "$strategy_dir" ]; then
            for quality_file in "$strategy_dir"/quality_*.txt; do
                if [ -f "$quality_file" ]; then
                    local basename=$(basename "$quality_file" | sed 's/quality_//' | sed 's/\.txt$//')
                    
                    # Apply filter if provided
                    if [ -n "${COMPARISON_FILE_FILTER:-}" ]; then
                        if echo "$basename" | grep -E "${COMPARISON_FILE_FILTER}" > /dev/null; then
                            all_files["$basename"]=1
                        fi
                    else
                        all_files["$basename"]=1
                    fi
                fi
            done
        fi
    done
    
    # If no files match the filter, show a message
    if [ ${#all_files[@]} -eq 0 ] && [ -n "${COMPARISON_FILE_FILTER:-}" ]; then
        log_message "No files match filter pattern: ${COMPARISON_FILE_FILTER}"
        log_message "Available files in comparison directories:"
        for strategy_dir in "$comparison_dir"/*; do
            if [ -d "$strategy_dir" ]; then
                local strategy=$(basename "$strategy_dir")
                log_message "  $strategy: $(find "$strategy_dir" -name "quality_*.txt" | wc -l) files"
                find "$strategy_dir" -name "quality_*.txt" | head -3 | while read file; do
                    local fname=$(basename "$file" | sed 's/quality_//' | sed 's/\.txt$//')
                    log_message "    Example: $fname"
                done
            fi
        done
        return 0
    fi
    
    # Generate file-by-file comparison
    log_message ""
    log_message "File-by-File Quality Comparison:"
    log_message ""
    
    for filename in "${!all_files[@]}"; do
        log_message "=== File: $filename ==="
        log_message "| Strategy | Dimensions | Voxel Size | Volume(mm³) | Brain Voxels | Info% | Signal Range | QForm | SForm | Status |"
        log_message "|----------|------------|------------|-------------|--------------|-------|--------------|-------|-------|--------|"
        
        # Compare each strategy for this file
        for strategy_dir in "$comparison_dir"/*; do
            if [ -d "$strategy_dir" ]; then
                local strategy=$(basename "$strategy_dir")
                local quality_file="$strategy_dir/quality_${filename}.txt"
                local metrics_file="$strategy_dir/metrics.txt"
                
                # For crop_to_brain strategy, prefer cropped versions
                if [ "$strategy" = "crop_to_brain" ]; then
                    local cropped_quality_file="$strategy_dir/quality_${filename}_Crop_1.txt"
                    if [ -f "$cropped_quality_file" ]; then
                        quality_file="$cropped_quality_file"
                    fi
                fi
                
                if [ -f "$quality_file" ] && [ -f "$metrics_file" ]; then
                    # Extract quality metrics for this file
                    local dimensions=$(grep "DIMENSIONS:" "$quality_file" | cut -d' ' -f2)
                    local voxel_size=$(grep "VOXEL_SIZE_MM:" "$quality_file" | cut -d' ' -f2)
                    local volume_mm3=$(grep "VOLUME_MM3:" "$quality_file" | cut -d' ' -f2)
                    local brain_voxels=$(grep "NONZERO_VOXELS:" "$quality_file" | cut -d' ' -f2)
                    local info_density=$(grep "INFORMATION_DENSITY_PCT:" "$quality_file" | cut -d' ' -f2)
                    local signal_range=$(grep "SIGNAL_RANGE_P95_P05:" "$quality_file" | cut -d' ' -f2)
                    local qform_code=$(grep "QFORM_CODE:" "$quality_file" | cut -d' ' -f2)
                    local sform_code=$(grep "SFORM_CODE:" "$quality_file" | cut -d' ' -f2)
                    local status=$(grep "CONVERSION_STATUS" "$metrics_file" | cut -d'=' -f2)
                    
                    # Handle N/A values safely
                    [ "$dimensions" = "" ] && dimensions="N/A"
                    [ "$voxel_size" = "" ] && voxel_size="N/A"
                    [ "$volume_mm3" = "" ] && volume_mm3="N/A"
                    [ "$brain_voxels" = "" ] && brain_voxels="N/A"
                    [ "$info_density" = "" ] && info_density="N/A"
                    [ "$signal_range" = "" ] && signal_range="N/A"
                    [ "$qform_code" = "" ] && qform_code="N/A"
                    [ "$sform_code" = "" ] && sform_code="N/A"
                    [ "$status" = "" ] && status="N/A"
                    
                    # Format values for display
                    if [ "$info_density" != "N/A" ] && command -v bc &>/dev/null; then
                        info_density=$(echo "scale=1; $info_density" | bc)"%"
                    fi
                    
                    if [ "$volume_mm3" != "N/A" ] && command -v bc &>/dev/null; then
                        volume_mm3=$(echo "scale=0; $volume_mm3 / 1000" | bc)"k"
                    fi
                    
                    # Truncate long dimension strings for table readability
                    if [ "$dimensions" != "N/A" ] && [ ${#dimensions} -gt 12 ]; then
                        dimensions="${dimensions:0:9}..."
                    fi
                    
                    if [ "$voxel_size" != "N/A" ] && [ ${#voxel_size} -gt 10 ]; then
                        voxel_size="${voxel_size:0:7}..."
                    fi
                    
                    log_message "| $strategy | $dimensions | $voxel_size | $volume_mm3 | $brain_voxels | $info_density | $signal_range | $qform_code | $sform_code | $status |"
                else
                    log_message "| $strategy | NOT_CONVERTED | - | - | - | - | - | - | - | MISSING |"
                fi
            fi
        done
        log_message ""
    done
    
    # Detect identical results between strategies
    log_message "=== Strategy Differences Analysis ==="
    log_message ""
    
    declare -A file_checksums
    declare -A strategy_file_counts_for_comparison
    local identical_strategies=""
    
    # Calculate checksums for each strategy's files to detect identical results
    for strategy_dir in "$comparison_dir"/*; do
        if [ -d "$strategy_dir" ]; then
            local strategy=$(basename "$strategy_dir")
            strategy_file_counts_for_comparison["$strategy"]=0
            
            # Count files and create a "signature" of the strategy's output
            local strategy_signature=""
            for nifti_file in "$strategy_dir"/*.nii.gz; do
                if [ -f "$nifti_file" ]; then
                    local basename=$(basename "$nifti_file" .nii.gz)
                    local file_size=$(stat -f%z "$nifti_file" 2>/dev/null || echo "0")
                    strategy_signature="${strategy_signature}${basename}:${file_size};"
                    strategy_file_counts_for_comparison["$strategy"]=$((strategy_file_counts_for_comparison["$strategy"] + 1))
                fi
            done
            file_checksums["$strategy"]="$strategy_signature"
        fi
    done
    
    # Compare strategies to find identical results
    local strategies=($(printf '%s\n' "${!file_checksums[@]}" | sort))
    local num_strategies=${#strategies[@]}
    
    for ((i=0; i<num_strategies; i++)); do
        for ((j=i+1; j<num_strategies; j++)); do
            local strategy1="${strategies[i]}"
            local strategy2="${strategies[j]}"
            
            if [ "${file_checksums[$strategy1]}" = "${file_checksums[$strategy2]}" ] && [ "${file_checksums[$strategy1]}" != "" ]; then
                if [ "$identical_strategies" = "" ]; then
                    identical_strategies="$strategy1,$strategy2"
                else
                    identical_strategies="$identical_strategies,$strategy2"
                fi
            fi
        done
    done
    
    if [ "$identical_strategies" != "" ]; then
        log_message "⚠️  IDENTICAL RESULTS DETECTED:"
        log_message "Strategies producing identical outputs: $identical_strategies"
        log_message ""
        log_message "This indicates that for this particular dataset, these dcm2niix"
        log_message "conversion strategies do not produce meaningfully different results."
        log_message "This is normal for some DICOM datasets and vendor implementations."
        log_message ""
    else
        log_message "✓ All strategies produced different results"
        log_message ""
    fi
    
    # Overall strategy assessment
    log_message "=== Overall Strategy Assessment ==="
    log_message ""
    
    declare -A strategy_success_count
    declare -A strategy_total_brain
    declare -A strategy_file_count
    
    # Aggregate metrics across all files
    for strategy_dir in "$comparison_dir"/*; do
        if [ -d "$strategy_dir" ]; then
            local strategy=$(basename "$strategy_dir")
            strategy_success_count["$strategy"]=0
            strategy_total_brain["$strategy"]=0
            strategy_file_count["$strategy"]=0
            
            local metrics_file="$strategy_dir/metrics.txt"
            if [ -f "$metrics_file" ]; then
                local status=$(grep "CONVERSION_STATUS" "$metrics_file" | cut -d'=' -f2)
                local nifti_count=$(grep "NIFTI_OUTPUT_COUNT" "$metrics_file" | cut -d'=' -f2)
                
                strategy_file_count["$strategy"]=$nifti_count
                
                if [ "$status" = "SUCCESS" ]; then
                    strategy_success_count["$strategy"]=1
                fi
                
                # Sum brain voxels across all files for this strategy
                for quality_file in "$strategy_dir"/quality_*.txt; do
                    if [ -f "$quality_file" ]; then
                        local brain_voxels=$(grep "NONZERO_VOXELS:" "$quality_file" | cut -d' ' -f2)
                        if [ "$brain_voxels" != "" ] && [ "$brain_voxels" != "N/A" ]; then
                            strategy_total_brain["$strategy"]=$((strategy_total_brain["$strategy"] + brain_voxels))
                        fi
                    fi
                done
            fi
        fi
    done
    
    log_message "Strategy Performance Summary:"
    log_message "| Strategy | Files Created | Total Brain Voxels | Status | Recommendation |"
    log_message "|----------|---------------|--------------------| -------|----------------|"
    
    for strategy_dir in "$comparison_dir"/*; do
        if [ -d "$strategy_dir" ]; then
            local strategy=$(basename "$strategy_dir")
            local files=${strategy_file_count["$strategy"]}
            local brain=${strategy_total_brain["$strategy"]}
            local success=${strategy_success_count["$strategy"]}
            
            local status_text="FAILED"
            if [ "$success" -eq 1 ]; then
                status_text="SUCCESS"
            fi
            
            local recommendation=""
            case "$strategy" in
                "preserve_all")
                    recommendation="Max completeness"
                    ;;
                "vendor_optimized")
                    recommendation="Balanced quality"
                    ;;
                "crop_to_brain")
                    recommendation="Space efficient"
                    ;;
                "custom_no_anatomical")
                    recommendation="Research comparison"
                    ;;
                *)
                    recommendation="General use"
                    ;;
            esac
            
            log_message "| $strategy | $files | $brain | $status_text | $recommendation |"
        fi
    done
    
    log_message ""
    log_message "Quality Interpretation:"
    log_message "- BRAIN_VOXELS: Higher = more anatomical detail preserved"
    log_message "- INFO_DENSITY: Higher % = better signal-to-background ratio"
    log_message "- MAX_RANGE: Higher = better contrast and dynamic range"
    log_message "- ORIENTATION: VALID = proper spatial coordinate system"
    log_message ""
    log_message "================================================================="
}


# Helper function to count DICOM files
count_dicom_files() {
    local dicom_dir="$1"
    local total=0
    
    # Validate input directory exists
    if [ ! -d "$dicom_dir" ]; then
        log_message "ERROR: DICOM directory does not exist: $dicom_dir"
        echo 0
        return 1
    fi
    
    # Check that required configuration variables are set
    if [ -z "${DICOM_PRIMARY_PATTERN:-}" ]; then
        log_message "ERROR: DICOM_PRIMARY_PATTERN is not set in configuration"
        echo 0
        return 1
    fi
    
    if [ -z "${DICOM_ADDITIONAL_PATTERNS:-}" ]; then
        log_message "ERROR: DICOM_ADDITIONAL_PATTERNS is not set in configuration"
        echo 0
        return 1
    fi
    
    log_message "Counting DICOM files in directory: $dicom_dir"
    log_message "Using primary pattern: $DICOM_PRIMARY_PATTERN"
    log_message "Using additional patterns: $DICOM_ADDITIONAL_PATTERNS"
    
    # Count files with primary pattern first
    local primary_count=$(find "$dicom_dir" -name "$DICOM_PRIMARY_PATTERN" -type f 2>/dev/null | wc -l)
    if [ "$primary_count" -gt 0 ]; then
        total=$primary_count
        log_message "Found $primary_count files with primary pattern: $DICOM_PRIMARY_PATTERN"
    else
        # If no files with primary pattern, try additional patterns
        log_message "No files found with primary pattern, trying additional patterns..."
        for pattern in $DICOM_ADDITIONAL_PATTERNS; do
            local count=$(find "$dicom_dir" -name "$pattern" -type f 2>/dev/null | wc -l)
            if [ "$count" -gt 0 ]; then
                total=$((total + count))
                log_message "Found $count files with pattern: $pattern"
            fi
        done
    fi
    
    log_message "Total DICOM files found: $total"
    echo $total
}

# Export functions
export -f compare_import_strategies
export -f test_import_strategy
export -f generate_comparison_report
export -f count_dicom_files

log_message "Import comparison module loaded"