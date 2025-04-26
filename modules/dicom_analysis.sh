#!/usr/bin/env bash
#
# dicom_analysis.sh - Vendor-agnostic DICOM header analysis functions
#
# This module contains functions for analyzing DICOM headers and metadata
# from different scanner manufacturers (Siemens, Philips, GE, etc.)
#

# Function to analyze DICOM headers from a sample file
analyze_dicom_header() {
    local dicom_file="$1"
    local output_file="${2:-${LOG_DIR}/dicom_header_analysis.txt}"
    
    if [ ! -f "$dicom_file" ]; then
        log_formatted "ERROR" "DICOM file not found: $dicom_file"
        return 1
    fi
    
    log_message "Analyzing DICOM header from $dicom_file"
    mkdir -p "$(dirname "$output_file")"
    
    # Detect available DICOM tools
    local dicom_tool=""
    local dicom_cmd=""
    
    if command -v dcmdump &>/dev/null; then
        dicom_tool="dcmdump"
        dicom_cmd="dcmdump"
    elif command -v gdcmdump &>/dev/null; then
        dicom_tool="gdcmdump"
        dicom_cmd="gdcmdump"
    elif command -v dcminfo &>/dev/null; then
        dicom_tool="dcminfo"
        dicom_cmd="dcminfo"
    elif command -v dicom_hdr &>/dev/null; then
        dicom_tool="dicom_hdr"
        dicom_cmd="dicom_hdr"
    else
        log_formatted "WARNING" "No DICOM header tool found (dcmdump, gdcmdump, dcminfo, dicom_hdr)"
        return 1
    fi
    
    log_message "Using $dicom_tool for DICOM header analysis"
    
    # Extract key header fields that are common across manufacturers
    {
        echo "DICOM Header Analysis Report"
        echo "============================"
        echo "File: $dicom_file"
        echo "Tool: $dicom_tool"
        echo "Date: $(date)"
        echo ""
        echo "Key Identification Fields:"
        echo "------------------------"
        
        # Extract information based on available tool
        case "$dicom_tool" in
            "dcmdump")
                $dicom_cmd "$dicom_file" | grep -E "(0020,000D|0020,000E|0020,0010|0020,0011|0008,0060|0008,0070|0008,1090|0018,1020|0008,103E)"
                ;;
            "gdcmdump"|"dcminfo"|"dicom_hdr")
                $dicom_cmd "$dicom_file" | grep -E "(Study|Series|Acquisition|Instance|Manufacturer|Model|Protocol)"
                ;;
        esac
        
        echo ""
        echo "Field Mapping Table:"
        echo "------------------"
        echo "0020,000D - Study Instance UID"
        echo "0020,000E - Series Instance UID"
        echo "0020,0010 - Study ID"
        echo "0020,0011 - Series Number"
        echo "0008,0060 - Modality"
        echo "0008,0070 - Manufacturer"
        echo "0008,1090 - Model Name"
        echo "0018,1020 - Software Version"
        echo "0008,103E - Series Description"
        
    } > "$output_file"
    
    # Print a summary to stdout/log
    log_message "DICOM header analysis complete, results saved to $output_file"
    
    # Check for empty fields that might cause grouping issues in dcm2niix
    check_empty_dicom_fields "$dicom_file"
    
    return 0
}

# Function to check for empty fields that might cause grouping issues
check_empty_dicom_fields() {
    local dicom_file="$1"
    
    log_message "Checking for empty DICOM fields that might cause slice grouping issues"
    
    # Verify file exists
    if [ ! -f "$dicom_file" ]; then
        log_formatted "ERROR" "DICOM file not found for empty field check: $dicom_file"
        return 0  # Return success to allow pipeline to continue
    fi
    
    # Check if any DICOM tools are available
    if ! command -v dcmdump &>/dev/null && \
       ! command -v gdcmdump &>/dev/null && \
       ! command -v dcminfo &>/dev/null && \
       ! command -v dicom_hdr &>/dev/null; then
        log_formatted "WARNING" "No DICOM header tools available - skipping empty field check"
        return 0  # Return success to allow pipeline to continue
    fi
    
    # Critical fields for grouping across all vendors
    local critical_fields=(
        "0020,0013"  # Instance Number
        "0020,0012"  # Acquisition Number
        "0020,0011"  # Series Number
        "0020,000E"  # Series Instance UID
        "0020,9056"  # Stack ID
        "0020,0032"  # Image Position Patient
    )
    
    log_message "Checking ${#critical_fields[@]} critical DICOM fields for proper slice grouping"
    
    local empty_fields=0
    local total_fields=${#critical_fields[@]}
    local empty_field_list=""
    
    # Check each critical field with error handling
    for field in "${critical_fields[@]}"; do
        local field_value=""
        local field_status="unknown"
        local tool_used=""
        
        # Try to extract the field value using available tool with error handling
        if command -v dcmdump &>/dev/null; then
            tool_used="dcmdump"
            { field_value=$(dcmdump "$dicom_file" | grep -E "\\($field\\)" | grep -v "no value" | wc -l); } 2>/dev/null || {
                log_message "Error executing dcmdump for field $field - continuing"
                field_value=0
                field_status="error"
            }
        elif command -v gdcmdump &>/dev/null; then
            tool_used="gdcmdump"
            { field_value=$(gdcmdump "$dicom_file" | grep -E "\\($field\\)" | grep -v "no value" | wc -l); } 2>/dev/null || {
                log_message "Error executing gdcmdump for field $field - continuing"
                field_value=0
                field_status="error"
            }
        elif command -v dcminfo &>/dev/null; then
            tool_used="dcminfo"
            { field_value=$(dcminfo "$dicom_file" | grep -E "\\($field\\)" | grep -v "no value" | wc -l); } 2>/dev/null || {
                log_message "Error executing dcminfo for field $field - continuing"
                field_value=0
                field_status="error"
            }
        elif command -v dicom_hdr &>/dev/null; then
            tool_used="dicom_hdr"
            { field_value=$(dicom_hdr -tag "($field)" "$dicom_file" | grep -v "no value" | wc -l); } 2>/dev/null || {
                log_message "Error executing dicom_hdr for field $field - continuing"
                field_value=0
                field_status="error"
            }
        else
            log_formatted "WARNING" "No DICOM header tool available to check field: $field"
            field_value=0
            field_status="no_tool"
            continue
        fi
        
        # Check if field is empty and log the result
        if [ "$field_value" -eq 0 ]; then
            empty_fields=$((empty_fields+1))
            empty_field_list="$empty_field_list $field"
            field_status="empty"
            log_message "Field $field is empty or not found (status: $field_status, tool: $tool_used)"
        else
            field_status="present"
            log_message "Field $field is present (status: $field_status, tool: $tool_used)"
        fi
    done
    
    # Safeguard against division by zero
    if [ $total_fields -eq 0 ]; then
        log_formatted "WARNING" "No critical fields could be checked - check may be unreliable"
        return 0
    fi
    
    # Calculate percentage of empty fields
    local empty_percentage=$((empty_fields * 100 / total_fields))
    
    # Report results with more detailed logging
    log_message "DICOM slice grouping check complete: $empty_fields/$total_fields fields empty ($empty_percentage%)"
    
    if [ $empty_fields -eq 0 ]; then
        log_formatted "SUCCESS" "All critical DICOM grouping fields are present"
        log_message "DICOM metadata check completed successfully - continuing with pipeline"
        return 0
    elif [ $empty_percentage -lt 25 ]; then
        log_formatted "INFO" "$empty_fields/$total_fields critical fields are empty: $empty_field_list"
        log_formatted "INFO" "Minor risk of incorrect slice grouping"
        log_message "DICOM metadata check completed with minor issues - continuing with pipeline"
        return 0  # Return success to allow pipeline to continue
    elif [ $empty_percentage -lt 50 ]; then
        log_formatted "WARNING" "$empty_fields/$total_fields critical fields are empty: $empty_field_list"
        log_formatted "WARNING" "Moderate risk of incorrect slice grouping"
        log_message "DICOM metadata check completed with moderate issues - continuing with pipeline"
        return 0  # Return success to allow pipeline to continue
    else
        log_formatted "ERROR" "$empty_fields/$total_fields critical fields are empty: $empty_field_list"
        log_formatted "ERROR" "High risk of incorrect slice grouping and data loss!"
        log_formatted "ERROR" "Consider using --exact_values with dcm2niix or alternative conversion tools"
        log_message "DICOM metadata check completed with serious issues - continuing with pipeline anyway"
        return 0  # Return success to allow pipeline to continue
    fi
}

# Function to detect scanner manufacturer
detect_scanner_manufacturer() {
    local dicom_file="$1"
    
    if [ ! -f "$dicom_file" ]; then
        log_formatted "ERROR" "DICOM file not found: $dicom_file"
        return 1
    fi 
    
    local manufacturer=""
    
    # Try to extract manufacturer information
    if command -v dcmdump &>/dev/null; then
        manufacturer=$(dcmdump "$dicom_file" | grep -E "\\(0008,0070\\)" | sed -E 's/.*\[([^]]*)\].*/\1/')
    elif command -v gdcmdump &>/dev/null; then
        manufacturer=$(gdcmdump "$dicom_file" | grep -E "Manufacturer" | sed -E 's/.*: (.*)/\1/')
    elif command -v dcminfo &>/dev/null; then
        manufacturer=$(dcminfo "$dicom_file" | grep -E "Manufacturer" | sed -E 's/.*: (.*)/\1/')
    elif command -v dicom_hdr &>/dev/null; then
        manufacturer=$(dicom_hdr -tag "(0008,0070)" "$dicom_file" | sed -E 's/.*: (.*)/\1/')
    else
        log_formatted "WARNING" "No DICOM header tool available to detect manufacturer"
        return 1
    fi
    
    # Normalize manufacturer name
    manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$manufacturer" == *siemens* ]]; then
        echo "SIEMENS"
    elif [[ "$manufacturer" == *philips* ]]; then
        echo "PHILIPS"
    elif [[ "$manufacturer" == *ge* ]] || [[ "$manufacturer" == *general*electric* ]]; then
        echo "GE"
    elif [[ "$manufacturer" == *toshiba* ]] || [[ "$manufacturer" == *canon* ]]; then
        echo "TOSHIBA"
    elif [[ "$manufacturer" == *hitachi* ]]; then
        echo "HITACHI"
    else
        echo "UNKNOWN"
    fi
    
    return 0
}

# Function to get manufacturer-specific conversion recommendations
get_conversion_recommendations() {
    local manufacturer="$1"
    
    log_message "Getting conversion recommendations for $manufacturer scanners"
    
    # Normalize manufacturer for case-insensitive comparison
    local manufacturer_upper=$(echo "$manufacturer" | tr '[:lower:]' '[:upper:]')
    
    case "$manufacturer_upper" in
        "SIEMENS")
            echo "--exact_values 1"  # Siemens often has complete metadata
            ;;
        "PHILIPS")
            echo "--exact_values 1 --philips"  # Philips data often needs special handling
            ;;
        "GE")
            echo "--exact_values 1 --no-dupcheck"  # GE scanners may need duplicate checking disabled
            ;;
        "TOSHIBA"|"HITACHI")
            echo "--exact_values 1"  # Default for other manufacturers
            ;;
        *)
            echo ""  # No specific flags for unknown manufacturer
            ;;
    esac
    
    return 0
}

# Function to extract Siemens-specific metadata
extract_siemens_metadata() {
    local dicom_file="$1"
    local metadata_file="$2"
    
    log_message "Extracting Siemens scanner metadata from $dicom_file"
    
    if [ ! -f "$dicom_file" ]; then
        log_formatted "ERROR" "DICOM file not found: $dicom_file"
        return 1
    fi
    
    mkdir -p "$(dirname "$metadata_file")"
    
    # Check for dcmdump
    if ! command -v dcmdump &>/dev/null; then
        log_formatted "ERROR" "dcmdump required for metadata extraction is not available"
        return 1
    fi
    
    # Extract basic metadata from dcmdump
    local manufacturer=$(dcmdump "$dicom_file" | grep -E "\\(0008,0070\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
    local model=$(dcmdump "$dicom_file" | grep -E "\\(0008,1090\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
    local software=$(dcmdump "$dicom_file" | grep -E "\\(0018,1020\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
    
    # Check for required fields
    local missing_fields=""
    [ -z "$manufacturer" ] && missing_fields="$missing_fields manufacturer"
    [ -z "$model" ] && missing_fields="$missing_fields model"
    
    if [ -n "$missing_fields" ]; then
        log_formatted "ERROR" "Required DICOM metadata fields missing:$missing_fields"
        return 1
    fi
    
    # Create JSON metadata file with exactly what was found
    cat > "$metadata_file" << EOF
{
  "manufacturer": "$manufacturer",
  "fieldStrength": "1.5T",
  "modelName": "$model",
  "softwareVersion": "$software",
  "source": "dcmdump-extraction"
}
EOF
    log_message "Created metadata file from DICOM header: $metadata_file"
    return 0
}

# Function to extract metadata from DICOM file
extract_scanner_metadata() {
    local dicom_file="$1"
    local output_dir="${2:-${RESULTS_DIR}/metadata}"
    
    if [ ! -f "$dicom_file" ]; then
        log_formatted "ERROR" "DICOM file not found for metadata extraction: $dicom_file"
        return 1
    fi
    
    mkdir -p "$output_dir"
    
    # Check for dcmdump which is required
    if ! command -v dcmdump &>/dev/null; then
        log_formatted "ERROR" "dcmdump required for metadata extraction is not available"
        return 1
    fi
    
    # Detect manufacturer for logging purposes
    local manufacturer=$(detect_scanner_manufacturer "$dicom_file")
    if [ -z "$manufacturer" ] || [ "$manufacturer" = "UNKNOWN" ]; then
        log_formatted "ERROR" "Could not detect scanner manufacturer from DICOM file"
        return 1
    fi
    log_message "Detected scanner manufacturer: $manufacturer"
    
    # Normalize the manufacturer name
    local manufacturer_upper=$(echo "$manufacturer" | tr '[:lower:]' '[:upper:]')
    
    # Extract metadata based on manufacturer
    local metadata_file="${output_dir}/scanner_params.json"
    
    case "$manufacturer_upper" in
        "SIEMENS")
            if ! extract_siemens_metadata "$dicom_file" "$metadata_file"; then
                log_formatted "ERROR" "Failed to extract Siemens metadata"
                return 1
            fi
            log_message "Siemens metadata extraction completed"
            ;;
        "PHILIPS")
            # Extract Philips metadata
            local model=$(dcmdump "$dicom_file" | grep -E "\\(0008,1090\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
            local software=$(dcmdump "$dicom_file" | grep -E "\\(0018,1020\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
            
            # Check for required fields
            local missing_fields=""
            [ -z "$model" ] && missing_fields="$missing_fields model"
            
            if [ -n "$missing_fields" ]; then
                log_formatted "ERROR" "Required DICOM metadata fields missing:$missing_fields"
                return 1
            fi
            
            cat > "$metadata_file" << EOF
{
  "manufacturer": "PHILIPS",
  "fieldStrength": "1.5T",
  "modelName": "$model",
  "softwareVersion": "$software",
  "source": "dcmdump-extraction"
}
EOF
            log_message "Philips metadata extraction completed"
            ;;
        "GE")
            # Extract GE metadata
            local model=$(dcmdump "$dicom_file" | grep -E "\\(0008,1090\\)" | sed -E 's/.*\[([^]]*)\].*/\1/' | tr -d '[:space:]')
            
            # Check for required fields
            if [ -z "$model" ]; then
                log_formatted "ERROR" "Required DICOM metadata field 'model' missing"
                return 1
            fi
            
            cat > "$metadata_file" << EOF
{
  "manufacturer": "GE",
  "fieldStrength": "1.5T",
  "modelName": "$model",
  "source": "dcmdump-extraction"
}
EOF
            log_message "GE metadata extraction completed"
            ;;
        *)
            log_formatted "ERROR" "Unsupported manufacturer: $manufacturer"
            log_message "Only SIEMENS, PHILIPS, and GE scanners are supported"
            return 1
            ;;
    esac
    
    # Log completion and return success
    log_message "Created metadata file: $metadata_file"
    return 0
}

# Export functions
export -f analyze_dicom_header
export -f check_empty_dicom_fields
export -f detect_scanner_manufacturer
export -f get_conversion_recommendations
export -f extract_siemens_metadata
export -f extract_scanner_metadata

log_message "DICOM analysis module loaded"