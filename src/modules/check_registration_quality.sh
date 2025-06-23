#!/usr/bin/env bash
#
# check_registration_quality.sh - Assess the quality of image registration
#
# This script provides a comprehensive assessment of image registration quality
# by computing various metrics and generating visualizations.
#
# Usage: ./check_registration_quality.sh <reference_image> <registered_image> [output_dir]
#

# Ensure we have the required arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <reference_image> <registered_image> [output_dir]"
    echo ""
    echo "Arguments:"
    echo "  reference_image   : The fixed/reference image (e.g., T1.nii.gz)"
    echo "  registered_image  : The registered/warped image to evaluate"
    echo "  output_dir        : Optional output directory (default: ./reg_quality)"
    exit 1
fi

# Parse arguments
REFERENCE_IMG="$1"
REGISTERED_IMG="$2"
OUTPUT_DIR="${3:-./reg_quality}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Source the necessary modules if running standalone
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${SCRIPT_DIR}/modules/environment.sh" ]; then
    source "${SCRIPT_DIR}/modules/environment.sh"
fi

if [ -f "${SCRIPT_DIR}/modules/utils.sh" ]; then
    source "${SCRIPT_DIR}/modules/utils.sh"
fi

if [ -f "${SCRIPT_DIR}/modules/registration.sh" ]; then
    source "${SCRIPT_DIR}/modules/registration.sh"
fi

# Define logging function if not available
if ! command -v log_message &> /dev/null; then
    log_message() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }
    
    log_formatted() {
        local level="$1"
        local message="$2"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $message"
    }
fi

# Define metric calculation functions if not available
if ! command -v calculate_cc &> /dev/null; then
    calculate_cc() {
        local img1="$1"
        local img2="$2"
        
        # Default to FSL's fslcc if available
        if command -v fslcc &> /dev/null; then
            local cc=$(fslcc "$img1" "$img2" | awk '{print $1}')
            echo "$cc"
        else
            # Fallback to calculating with fslmaths and fslstats
            local tmpdir=$(mktemp -d)
            fslmaths "$img1" -mul "$img2" "${tmpdir}/mul.nii.gz" 2>/dev/null
            local mul_sum=$(fslstats "${tmpdir}/mul.nii.gz" -M 2>/dev/null)
            local img1_sum=$(fslstats "$img1" -M 2>/dev/null)
            local img2_sum=$(fslstats "$img2" -M 2>/dev/null)
            local cc=$(echo "scale=6; $mul_sum / sqrt($img1_sum * $img2_sum)" | bc -l)
            rm -rf "${tmpdir}"
            echo "$cc"
        fi
    }
    
    calculate_mi() {
        local img1="$1"
        local img2="$2"
        
        # Simplified MI calculation using histogram analysis
        # This is a placeholder; a real implementation would use tools like ANTs' MeasureImageSimilarity
        echo "N/A"
    }
    
    calculate_ncc() {
        local img1="$1"
        local img2="$2"
        
        # Simplified NCC calculation 
        # This is a placeholder; a real implementation would use tools like ANTs' MeasureImageSimilarity
        echo "N/A"
    }
fi

# Check if input files exist
if [ ! -f "$REFERENCE_IMG" ]; then
    log_formatted "ERROR" "Reference image not found: $REFERENCE_IMG"
    exit 1
fi

if [ ! -f "$REGISTERED_IMG" ]; then
    log_formatted "ERROR" "Registered image not found: $REGISTERED_IMG"
    exit 1
fi

log_message "Starting registration quality assessment"
log_message "Reference image: $REFERENCE_IMG"
log_message "Registered image: $REGISTERED_IMG"
log_message "Output directory: $OUTPUT_DIR"

# Calculate metrics
log_message "Computing registration quality metrics..."

# Calculate correlation coefficient
CC=$(calculate_cc "$REFERENCE_IMG" "$REGISTERED_IMG")
log_message "Cross-correlation: $CC"

# Calculate mutual information if possible
MI=$(calculate_mi "$REFERENCE_IMG" "$REGISTERED_IMG")
log_message "Mutual information: $MI"

# Calculate normalized cross-correlation if possible
NCC=$(calculate_ncc "$REFERENCE_IMG" "$REGISTERED_IMG")
log_message "Normalized cross-correlation: $NCC"

# Determine quality based on CC
QUALITY="UNKNOWN"
if [ "$CC" != "N/A" ] && [ "$CC" != "" ] && [ "$CC" != "0" ]; then
    # Configurable thresholds for quality evaluation
    CC_EXCELLENT=0.7
    CC_GOOD=0.5
    CC_ACCEPTABLE=0.3
    
    if (( $(echo "$CC > $CC_EXCELLENT" | bc -l) )); then
        QUALITY="EXCELLENT"
    elif (( $(echo "$CC > $CC_GOOD" | bc -l) )); then
        QUALITY="GOOD"
    elif (( $(echo "$CC > $CC_ACCEPTABLE" | bc -l) )); then
        QUALITY="ACCEPTABLE"
    else
        QUALITY="POOR"
    fi
fi

# Create visualizations
log_message "Creating visualizations..."

# Create difference image
DIFF_IMG="${OUTPUT_DIR}/difference.nii.gz"
log_message "Creating difference map..."

# Normalize both images first (more robust)
NORM_REF="${OUTPUT_DIR}/ref_norm.nii.gz"
NORM_REG="${OUTPUT_DIR}/reg_norm.nii.gz"

fslmaths "$REFERENCE_IMG" -inm 1 "$NORM_REF" 2>/dev/null
fslmaths "$REGISTERED_IMG" -inm 1 "$NORM_REG" 2>/dev/null

# Create absolute difference map
fslmaths "$NORM_REF" -sub "$NORM_REG" -abs "$DIFF_IMG" 2>/dev/null

# Create overlay visualization script
cat > "${OUTPUT_DIR}/view_overlay.sh" << EOL
#!/usr/bin/env bash
# Registration visualization script (overlay)
fsleyes "$REFERENCE_IMG" -cm greyscale "$REGISTERED_IMG" -cm greyscale -a 50 "$DIFF_IMG" -cm hot -a 70
EOL
chmod +x "${OUTPUT_DIR}/view_overlay.sh"

# Create side-by-side visualization script
cat > "${OUTPUT_DIR}/view_side_by_side.sh" << EOL
#!/usr/bin/env bash
# Registration visualization script (side-by-side)
fsleyes "$REFERENCE_IMG" -cm greyscale "$REGISTERED_IMG" -cm greyscale
EOL
chmod +x "${OUTPUT_DIR}/view_side_by_side.sh"

# Create quality report
log_message "Generating quality report..."
cat > "${OUTPUT_DIR}/quality_report.txt" << EOL
Registration Quality Assessment Report
=====================================
Reference image: $REFERENCE_IMG
Registered image: $REGISTERED_IMG

Quality Metrics:
- Cross-correlation: $CC
- Mutual information: $MI
- Normalized cross-correlation: $NCC

Overall Quality: $QUALITY

Quality Thresholds:
- Excellent: > $CC_EXCELLENT
- Good: > $CC_GOOD
- Acceptable: > $CC_ACCEPTABLE
- Poor: <= $CC_ACCEPTABLE

Visualizations:
- Difference map: $DIFF_IMG
- Overlay view: ./view_overlay.sh
- Side-by-side view: ./view_side_by_side.sh

Report generated: $(date)
EOL

echo "$QUALITY" > "${OUTPUT_DIR}/quality.txt"

log_message "Registration quality assessment complete"
log_message "Overall quality: $QUALITY"
log_message "Full report: ${OUTPUT_DIR}/quality_report.txt"

# Provide instructions to the user
echo ""
echo "Registration Quality Assessment: $QUALITY"
echo ""
echo "To view registration results:"
echo " - Overlay view:     ${OUTPUT_DIR}/view_overlay.sh"
echo " - Side-by-side:     ${OUTPUT_DIR}/view_side_by_side.sh"
echo ""
echo "Quality report saved to: ${OUTPUT_DIR}/quality_report.txt"

exit 0