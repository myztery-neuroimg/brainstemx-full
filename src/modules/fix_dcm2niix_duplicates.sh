#!/bin/bash
#
# Script to analyze DICOM headers and fix dcm2niix duplicate detection issues
#

# Function to check if a command is available
command_exists() {
    command -v "$1" &> /dev/null
}

# Function to print colorized output
print_color() {
    local color=$1
    local text=$2
    
    case $color in
        "red") echo -e "\033[0;31m$text\033[0m" ;;
        "green") echo -e "\033[0;32m$text\033[0m" ;;
        "yellow") echo -e "\033[0;33m$text\033[0m" ;;
        "blue") echo -e "\033[0;34m$text\033[0m" ;;
        *) echo "$text" ;;
    esac
}

# Function to analyze DICOM headers using Python script
analyze_with_python() {
    local dicom_dir=$1
    
    if command_exists python || command_exists python3; then
        local python_cmd="python"
        command_exists python3 && python_cmd="python3"
        
        # Check multiple possible locations for the analyze_dicom_headers.py script
        local script_paths=(
            "analyze_dicom_headers.py"
            "src/analyze_dicom_headers.py"
            "../analyze_dicom_headers.py"
            "$(dirname "$0")/analyze_dicom_headers.py"
            "$(dirname "$0")/../analyze_dicom_headers.py"
        )
        
        local script_found=false
        local script_path=""
        
        for path in "${script_paths[@]}"; do
            if [ -f "$path" ]; then
                script_found=true
                script_path="$path"
                break
            fi
        done
        
        if [ "$script_found" = true ]; then
            print_color "blue" "Running DICOM header analysis with script: $script_path"
            $python_cmd "$script_path" "$dicom_dir"
            return 0
        else
            print_color "yellow" "analyze_dicom_headers.py not found in any expected location"
            return 1
        fi
    else
        print_color "yellow" "Python not found"
        return 1
    fi
}

# Function to run improved dcm2niix command
run_fixed_dcm2niix() {
    local input_dir=$1
    local output_dir=$2
    
    mkdir -p "$output_dir"
    
    print_color "blue" "Running dcm2niix with enhanced flags to prevent duplicate detection..."
    
    # Get dcm2niix version
    local version_info=$(dcm2niix -v 2>&1 | head -1)
    print_color "green" "Using $version_info"
    
    # Check for modern features
    if dcm2niix -h 2>&1 | grep -q "no-collapse"; then
        print_color "green" "Modern dcm2niix detected, using --no-collapse flag"
        dcm2niix -z y -f "%p_%s" --no-collapse --ignore-derived --exact_values 1 -m y -i y -o "$output_dir" "$input_dir"
    else
        print_color "yellow" "Older dcm2niix detected, using alternative flags"
        dcm2niix -z y -f "%p_%s" --exact_values 1 -m y -i y -o "$output_dir" "$input_dir"
    fi
    
    # Check result
    local nifti_files=$(find "$output_dir" -name "*.nii.gz" | wc -l)
    print_color "blue" "Created $nifti_files NIfTI files in $output_dir"
}

# Function to run per-series conversion (divide and conquer approach)
run_series_by_series() {
    local input_dir=$1
    local output_dir=$2
    local temp_dir="${output_dir}/temp_conversion"
    
    mkdir -p "$temp_dir"
    mkdir -p "$output_dir"
    
    print_color "blue" "Running series-by-series conversion to avoid cross-series issues..."
    
    # Find all series directories
    series_dirs=$(find "$input_dir" -type d -exec sh -c 'ls "{}" | head -1 | grep -q "Image" && echo "{}"' \; || true)
    
    if [ -z "$series_dirs" ]; then
        # No subdirectories - process the whole directory
        print_color "yellow" "No series subdirectories found, processing entire input directory"
        run_fixed_dcm2niix "$input_dir" "$output_dir"
        return
    fi
    
    # Process each series directory separately
    for series_dir in $series_dirs; do
        print_color "blue" "Processing series: $(basename "$series_dir")"
        series_output="${temp_dir}/$(basename "$series_dir")"
        mkdir -p "$series_output"
        
        run_fixed_dcm2niix "$series_dir" "$series_output"
    done
    
    # Move all NIfTI files to the final output directory
    find "$temp_dir" -name "*.nii.gz" -exec mv {} "$output_dir/" \;
    
    # Clean up
    rm -rf "$temp_dir"
    
    print_color "green" "Series-by-series conversion complete"
}

# Main script logic
main() {
    # Check arguments
    if [ $# -lt 2 ]; then
        print_color "red" "Usage: $0 <dicom_directory> <output_directory> [--analyze-only | --series-by-series]"
        exit 1
    fi
    
    local dicom_dir="$1"
    local output_dir="$2"
    local mode="${3:---fix}"
    
    # Check if directories exist
    if [ ! -d "$dicom_dir" ]; then
        print_color "red" "DICOM directory does not exist: $dicom_dir"
        exit 1
    fi
    
    # Check if dcm2niix is installed
    if ! command_exists dcm2niix; then
        print_color "red" "dcm2niix is not installed or not in PATH"
        exit 1
    fi
    
    # Analyze DICOM headers if dcmdump is available
    if [ "$mode" = "--analyze-only" ] || command_exists dcmdump; then
        analyze_with_python "$dicom_dir"
        
        if [ "$mode" = "--analyze-only" ]; then
            exit 0
        fi
    else
        print_color "yellow" "dcmdump not found, skipping detailed analysis"
    fi
    
    # Run the conversion
    if [ "$mode" = "--series-by-series" ]; then
        run_series_by_series "$dicom_dir" "$output_dir"
    else
        run_fixed_dcm2niix "$dicom_dir" "$output_dir"
    fi
    
    print_color "green" "Conversion complete"
}

# Run the main function
main "$@"