#!/usr/local/bin/bash
set -e
set -u
set -o pipefail


# Process DiCOM MRI images into NiFTi files appropriate for use in FSL/freeview
# My intention is to try to use the `ants` library as well where it can optimise conversions etc.. this is a second attempt only

# Function for logging with timestamps
log_message() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" >&2 | tee -a "$log_file"
}   

SRC_DIR="../DiCOM"
EXTRACT_DIR="../extracted"
RESULTS_DIR="../mri_results"
# N4 Bias Field Correction parameters
N4_ITERATIONS="50x50x50x50"
N4_CONVERGENCE="0.000001"

# Configuration parameters for MRI processing pipeline
# Optimized for high-quality processing (512x512x512 resolution)

#############################################
# General processing parameters
#############################################

# Data directories
SRC_DIR="../DiCOM"
EXTRACT_DIR="../extracted"
RESULTS_DIR="../mri_results"

# Logging
LOG_DIR="${RESULTS_DIR}/logs"
LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# Data type for processing (float32 for processing, int16 for storage)
PROCESSING_DATATYPE="float"
OUTPUT_DATATYPE="int"

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

# Template creation options

# Number of iterations for template creation
TEMPLATE_ITERATIONS=4
# Gradient step size
TEMPLATE_GRADIENT_STEP=0.2
# Transformation model: Rigid, Affine, SyN
TEMPLATE_TRANSFORM_MODEL="SyN"
# Similarity metric: CC, MI, MSQ
TEMPLATE_SIMILARITY_METRIC="CC"
# Registration shrink factors
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
# Smoothing sigmas
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
# Similarity metric weights
TEMPLATE_WEIGHTS="100x70x50x10"



#############################################
# N4 Bias Field Correction parameters
#############################################

# Presets for different quality levels
# Format: iterations, convergence, b-spline grid resolution, shrink factor
N4_PRESET_LOW="25x25x25,0.0001,150,4"
N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
N4_PRESET_FLAIR="75x75x75x75,0.0000001,250,2"

# Parse preset into individual parameters
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    N4_PARAMS=$N4_PRESET_HIGH
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    N4_PARAMS=$N4_PRESET_MEDIUM
else
    N4_PARAMS=$N4_PRESET_LOW
fi

# Parse N4 parameters
N4_ITERATIONS=$(echo $N4_PARAMS | cut -d',' -f1)
N4_CONVERGENCE=$(echo $N4_PARAMS | cut -d',' -f2)
N4_BSPLINE=$(echo $N4_PARAMS | cut -d',' -f3)
N4_SHRINK=$(echo $N4_PARAMS | cut -d',' -f4)

# Set parameters by sequence type
N4_ITERATIONS_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo $N4_PRESET_FLAIR | cut -d',' -f4)

#############################################
# Registration and motion correction parameters
#############################################

# Registration parameters for antsRegistrationSyN.sh
# Options: 0=rigid, 1=affine, 2=rigid+affine+syn (default), 3=affine+syn
REG_TRANSFORM_TYPE=2

# For cross-modality registration (T2/FLAIR to T1)
# Options: CC=cross-correlation, MI=mutual information, Mattes=Mattes mutual information
REG_METRIC_CROSS_MODALITY="MI"

# For same-modality registration
REG_METRIC_SAME_MODALITY="CC"

# Number of threads for ANTs tools
ANTS_THREADS=8

# Registration precision (0=float, 1=double)
REG_PRECISION=1

#############################################
# Hyperintensity detection parameters
#############################################

# Threshold-based method parameters
# Threshold = WM_mean + (WM_SD * THRESHOLD_WM_SD_MULTIPLIER)
THRESHOLD_WM_SD_MULTIPLIER=2.5

# Minimum hyperintensity cluster size (in voxels)
MIN_HYPERINTENSITY_SIZE=5

# Atropos segmentation parameters
# Number of tissue classes for T1 segmentation
ATROPOS_T1_CLASSES=3

# Number of tissue classes for FLAIR segmentation (including hyperintensities)
ATROPOS_FLAIR_CLASSES=4

# Atropos convergence: max_iterations,convergence_threshold
ATROPOS_CONVERGENCE="5,0.0"

# Atropos smoothing factor: MRF_radius,MRF_strength
ATROPOS_MRF="[0.1,1x1x1]"

# Atropos initialization method: kmeans, otsu, or priorprobabilityimages
ATROPOS_INIT_METHOD="kmeans"

#############################################
# Cropping and padding parameters
#############################################

# Padding in voxels for each dimension
PADDING_X=5
PADDING_Y=5
PADDING_Z=5

# C3D cropping threshold (below this value is considered background)
C3D_CROP_THRESHOLD=0.1

# Padding in mm for C3D cropping
C3D_PADDING_MM=5


# Check if all required tools for MRI processing are installed
# Compatible with macOS/Apple Silicon

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log_formatted() {
  local level=$1
  local message=$2
  
  case $level in
    "INFO") echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR") echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
  esac
}

standardize_datatype() {
  local input=$1
  local output=$2
  local datatype=${3:-"float"}
  
  fslmaths "$input"  "$output" -odt "$datatype"
  log_message "Standardized $input to $datatype datatype"
}

# Function to set sequence-specific parameters
set_sequence_params() {
    local file="$1"
    
    # Base parameters
    local params=()
    
    if [[ "$file" == *"FLAIR"* ]]; then
        # FLAIR-specific parameters
        params+=("FLAIR")
        params+=("$N4_ITERATIONS_FLAIR")
        params+=("$THRESHOLD_WM_SD_MULTIPLIER")
    elif [[ "$file" == *"DWI"* || "$file" == *"ADC"* ]]; then
        # DWI-specific parameters
        params+=("DWI")
        params+=("$N4_ITERATIONS")
        params+=("2.0") # Different threshold multiplier for DWI
    elif [[ "$file" == *"SWI"* ]]; then
        # SWI-specific parameters
        params+=("SWI")
        params+=("$N4_ITERATIONS")
        params+=("3.0") # Different threshold multiplier for SWI
    else
        # Default parameters
        params+=("T1")
        params+=("$N4_ITERATIONS")
        params+=("$THRESHOLD_WM_SD_MULTIPLIER")
    fi
    
    log_message "${params[@]}"
}




# Function to check if a command exists
check_command() {
  local cmd=$1
  local package=$2
  local install_hint=${3:-""}
  
  if command -v $cmd &> /dev/null; then
     log_formatted "SUCCESS" "✓ $package is installed ($(command -v $cmd))"
    return 0
  else
    log_formatted "ERROR" "✗ $package is not installed or not in PATH"
    if [ -n "$install_hint" ]; then
      log_formatted "INFO"  "$install_hint"
    fi
    return 1
  fi
}

# Function to check for ANTs tools
check_ants() {
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  
  log_formatted "INFO" "Checking ANTs tools..."
  
  # Check for ANTSPATH environment variable
  if [ -z "$ANTSPATH" ]; then
    log_formatted "WARNING" "ANTSPATH environment variable is not set. This may cause issues with some ANTs scripts."
  else
    log_formatted "SUCCESS" "ANTSPATH is set to $ANTSPATH"
  fi
  
  # Check each required ANTs tool
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
   log_formatted  "ERROR" "Some ANTs tools are missing. Install ANTs from:"
    log_formatted "INFO" "  • Using Homebrew: brew install ants"
    log_formatted "INFO" "  • Or from source: https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-MacOS"
    return 1
  else
    return 0
  fi
}

# Function to check for FSL tools
check_fsl() {
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  
  log_formatted "INFO" "Checking FSL tools..."
  
  # Check for FSLDIR environment variable
  if [ -z "$FSLDIR" ]; then
    log_formatted "WARNING" "FSLDIR environment variable is not set. This may cause issues with some FSL scripts."
  else
    log_formatted "SUCCESS" "FSLDIR is set to $FSLDIR"
  fi
  
  # Check each required FSL tool
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log_formatted "ERROR" "Some FSL tools are missing. Install FSL from:"
    log_formatted "INFO" "  • Download from: https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FslInstallation"
    log_formatted "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for FreeSurfer tools
check_freesurfer() {
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  
  log_formatted "INFO" "Checking FreeSurfer tools..."
  
  # Check for FREESURFER_HOME environment variable
  if [ -z "$FREESURFER_HOME" ]; then
    log_formatted "WARNING" "FREESURFER_HOME environment variable is not set. This may cause issues with some FreeSurfer tools."
  else
    log_formatted "SUCCESS" "FREESURFER_HOME is set to $FREESURFER_HOME"
  fi
  
  # Check each required FreeSurfer tool
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log_formatted "ERROR" "Some FreeSurfer tools are missing. Install FreeSurfer from:"
    log_formatted "INFO" "  • Download from: https://surfer.nmr.mgh.harvard.edu/fswiki/DownloadAndInstall"
    log_formatted "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for Convert3D (c3d)
check_c3d() {
  log_formatted "INFO" "Checking Convert3D..."
  
  if ! check_command "c3d" "Convert3D" "Download from: http://www.itksnap.org/pmwiki/pmwiki.php?n=Downloads.C3D"; then
    return 1
  else
    return 0
  fi
}

# Function to check for dcm2niix
check_dcm2niix() {
  log_formatted "INFO" "Checking dcm2niix..."
  
  if ! check_command "dcm2niix" "dcm2niix" "Install with: brew install dcm2niix"; then
    return 1
  else
    # Check version
    local version=$(dcm2niix -v 2>&1 | head -n 1)
    log_formatted "INFO" "  dcm2niix version: $version"
    return 0
  fi
}

# Check if running on macOS
check_os() {
  log_formatted "INFO" "Checking operating system..."
  
  if [[ "$(uname)" == "Darwin" ]]; then
    log_formatted "SUCCESS" "✓ Running on macOS"
    
    # Check if running on Apple Silicon
    if [[ "$(uname -m)" == "arm64" ]]; then
      log_formatted "SUCCESS" "✓ Running on Apple Silicon"
    else
      log_formatted "INFO" "Running on Intel-based Mac"
    fi
    return 0  
  else
    log_formatted "ERROR" "This script is designed for macOS"
    exit 1
  fi
}

error_count=0

log_formatted "INFO" "==== MRI Processing Dependency Checker ===="

check_os || error_count=$((error_count+1))
check_dcm2niix || error_count=$((error_count+1))
check_ants || error_count=$((error_count+1))
check_fsl || error_count=$((error_count+1))
check_freesurfer || error_count=$((error_count+1))
check_c3d || error_count=$((error_count+1))

log_formatted "INFO" "==== Checking optional but recommended tools ===="

# Check for ImageMagick (useful for image manipulation)
check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || log_formatted "WARNING" "ImageMagick is recommended for image conversions"

# Check for parallel (useful for parallel processing)
check_command "parallel" "GNU Parallel" "Install with: brew install parallel" || log_formatted "WARNING" "GNU Parallel is recommended for faster processing"

# Summary
log_formatted "INFO" "==== Dependency Check Summary ===="

if [ $error_count -eq 0 ]; then
  log_formatted "SUCCESS" "All required dependencies are installed!"
else
  log_formatted "ERROR" "$error_count required dependencies are missing."
  log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
  exit 1
fi

# Create directories
mkdir -p "$EXTRACT_DIR"
mkdir -p "$RESULTS_DIR"
mkdir -p "$LOG_DIR"
log_file="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"



# Check for required dependencies
if ! command -v fslstats &> /dev/null || ! command -v fslroi &> /dev/null; then
    log_message "Error: FSL is not installed or not in your PATH."
    exit 1
fi

NUM_SRC_DICOM_FILES=`find ${SRC_DIR} -name Image"*"  | wc -l`

log_message "There are ${NUM_SRC_DICOM_FILES} in ${SRC_DIR}. You have 5 seconds to cancel the script if that's wrong. Going to extract to ${EXTRACT_DIR}"
sleep 5 

combine_multiaxis_images() {
    local sequence_type="$1"
    # Handle different naming conventions
    if [ "$sequence_type" = "T1" ]; then
        sequence_type="T1"
    fi
    local output_dir="$2"
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Find all matching sequence files
    sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | fgrep "SAG" | egrep -v "^[0-9]" || true))
    cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | fgrep "COR" | egrep -v "^[0-9]" || true))
    ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | fgrep "AX" | egrep -v "^[0-9]" || true))
    
    log_formatted "INFO" "Found ${#sag_files[@]} sagittal, ${#cor_files[@]} coronal, and ${#ax_files[@]} axial ${sequence_type} files"
    
    # Skip if no files found
    if [ ${#sag_files[@]} -eq 0 ] && [ ${#cor_files[@]} -eq 0 ] && [ ${#ax_files[@]} -eq 0 ]; then
        log_formatted "WARNING" "No ${sequence_type} files found to combine"
        return 1
    fi
    
    # Find highest resolution file in each orientation
    local best_sag=""
    local best_cor=""
    local best_ax=""
    local best_sag_res=0
    local best_cor_res=0
    local best_ax_res=0
    
    # Process sagittal files
    for file in "${sag_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
        
        if [ $res -gt $best_sag_res ]; then
            best_sag="$file"
            best_sag_res=$res
        fi
    done
    for file in "${ax_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
     
        if [ $res -gt $best_ax_res ]; then 
            best_ax="$file"
            best_ax_res=$res
        fi   
    done 
    for file in "${cor_files[@]}"; do
        # Get resolution
        dim1=$(fslval "$file" dim1)
        dim2=$(fslval "$file" dim2)
        dim3=$(fslval "$file" dim3)
        res=$((dim1 * dim2 * dim3))
     
        if [ $res -gt $best_cor_res ]; then 
            best_cor="$file"
            best_cor_res=$res
        fi   
    done 

    # Create output filename
    local output_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"
    
    # Register and combine the best files using ANTs
    log_formatted "INFO" "Combining best ${sequence_type} images to create high-resolution volume"
    
    if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
        # Use ANTs multivariate template creation to combine the three views
         antsMultivariateTemplateConstruction2.sh \
             -d 3 \
             -o "${output_dir}/${sequence_type}_template_" \
             -i ${TEMPLATE_ITERATIONS} \
             -g ${TEMPLATE_GRADIENT_STEP} \
             -j ${ANTS_THREADS} \
             -f ${TEMPLATE_SHRINK_FACTORS} \
             -s ${TEMPLATE_SMOOTHING_SIGMAS} \
             -q ${TEMPLATE_WEIGHTS} \
             -t ${TEMPLATE_TRANSFORM_MODEL} \
             -m ${TEMPLATE_SIMILARITY_METRIC} \
             -c 0 \
             "$best_sag" "$best_cor" "$best_ax"


        
        # Move the final template to our desired output
        mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$output_file"
        
        # Ensure INT16 output format
        standardize_datatype "$output_file" "$output_file" "$OUTPUT_DATATYPE"
        
        log_formatted "SUCCESS" "Created high-resolution ${sequence_type} volume: $output_file"
        return 0
    elif [ -n "$best_sag" ] || [ -n "$best_cor" ] || [ -n "$best_ax" ]; then
        # If we have at least one orientation, use that
        local best_file=""
        if [ -n "$best_sag" ]; then
            best_file="$best_sag"
        elif [ -n "$best_cor" ]; then
            best_file="$best_cor"
        else
            best_file="$best_ax"
        fi
        
        # Copy and ensure INT16 format
        cp "$best_file" "$output_file"
        standardize_datatype "$output_file" "$output_file" "$OUTPUT_DATATYPE"
        
        log_formatted "INFO" "Only one orientation available for ${sequence_type}, using: $best_file"
        return 0
    else
        log_formatted "ERROR" "No suitable ${sequence_type} files found"
        return 1
    fi
}



# Get sequence-specific N4 parameters
get_n4_parameters() {
    local file="$1"
    params=($(set_sequence_params "$file")) 
    local iterations=$N4_ITERATIONS
    local convergence=$N4_CONVERGENCE
    local bspline=$N4_BSPLINE
    local shrink=$N4_SHRINK
    
    # Use FLAIR-specific parameters if it's a FLAIR sequence
    if [[ "$file" == *"FLAIR"* ]]; then
        iterations=$N4_ITERATIONS_FLAIR
        convergence=$N4_CONVERGENCE_FLAIR
        bspline=$N4_BSPLINE_FLAIR
        shrink=$N4_SHRINK_FLAIR
    fi
    
    #log_message "$iterations" "$convergence" "$bspline" "$shrink"
}


# Add this before the DICOM to NIfTI conversion (around line 778)
log_message "==== Extracting DICOM metadata for processing optimization ===="
mkdir -p "${RESULTS_DIR}/metadata"

# Create a function to extract key Siemens parameters
extract_siemens_metadata() {
    local dicom_dir="$1"
    local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
    
    log_message "Extracting Siemens MAGNETOM Sola metadata..."
    
    # Find the first DICOM file for metadata extraction
    local first_dicom=$(find "$dicom_dir" -name "Image*" -type f | head -1)
    
    if [ -z "$first_dicom" ]; then
        log_message "⚠️ No DICOM files found for metadata extraction."
        return 1
    fi
    
    # Use dcmdump to extract key Siemens parameters
    # Extracting manufacturer, field strength, and protocol name
    local manufacturer=$(dcmdump "$first_dicom" | grep -i "Manufacturer" | head -1 | sed 's/.*\[\(.*\)\].*/\1/')
    local field_strength=$(dcmdump "$first_dicom" | grep -i "MagneticFieldStrength" | head -1 | sed 's/.*\[\(.*\)\].*/\1/')
    local protocol=$(dcmdump "$first_dicom" | grep -i "ProtocolName" | head -1 | sed 's/.*\[\(.*\)\].*/\1/')
    local model=$(dcmdump "$first_dicom" | grep -i "ManufacturerModelName" | head -1 | sed 's/.*\[\(.*\)\].*/\1/')
    
    # Extract Siemens-specific private tags using dcmdump
    # These contain advanced sequence parameters
    local siemens_specific=$(dcmdump "$first_dicom" | grep -i "SIEMENS" | grep -v "Manufacturer")
    
    # Create JSON file with extracted metadata
    echo "{" > "$metadata_file"
    echo "  \"manufacturer\": \"$manufacturer\"," >> "$metadata_file"
    echo "  \"fieldStrength\": $field_strength," >> "$metadata_file"
    echo "  \"protocolName\": \"$protocol\"," >> "$metadata_file"
    echo "  \"modelName\": \"$model\"," >> "$metadata_file"
    
    # Extract key Siemens MAGNETOM Sola parameters related to distortion correction
    # This requires pydicom for more advanced extraction
    if command -v python3 &> /dev/null; then
        # Create a temporary Python script to extract advanced parameters
        cat > "${RESULTS_DIR}/metadata/extract_siemens.py" << EOF
import pydicom
import json
import sys
import os

# Read the DICOM file
dcm = pydicom.dcmread(sys.argv[1])

# Extract Siemens CSA header (contains advanced parameters)
siemens_data = {}

# Check if it's a Siemens DICOM
if hasattr(dcm, 'ManufacturerModelName') and 'MAGNETOM Sola' in dcm.ManufacturerModelName:
    # Extract key parameters used by MAGNETOM Sola
    try:
        # Extract relevant tags
        if hasattr(dcm, 'Private_0029_1010'):
            siemens_data['hasCSAHeader'] = True
        if hasattr(dcm, 'ImageOrientationPatient'):
            siemens_data['orientation'] = dcm.ImageOrientationPatient
        if hasattr(dcm, 'PixelSpacing'):
            siemens_data['pixelSpacing'] = dcm.PixelSpacing
        if hasattr(dcm, 'SliceThickness'):
            siemens_data['sliceThickness'] = dcm.SliceThickness
        if hasattr(dcm, 'SpacingBetweenSlices'):
            siemens_data['spacingBetweenSlices'] = dcm.SpacingBetweenSlices
            
        # Get sequence-specific parameters
        if hasattr(dcm, 'SequenceName'):
            siemens_data['sequenceName'] = dcm.SequenceName
        
        # Extract B-value for DWI if present
        if hasattr(dcm, 'DiffusionBValue'):
            siemens_data['bValue'] = dcm.DiffusionBValue
            
        # Get key parameters for distortion correction in EPI sequences
        if hasattr(dcm, 'Private_0019_1018'):  # EPI factor
            siemens_data['epiFactor'] = dcm.Private_0019_1018
            
    except Exception as e:
        siemens_data['error'] = str(e)

# Write to JSON file
with open(sys.argv[2], 'w') as f:
    json.dump(siemens_data, f, indent=2)
EOF

        python3 "${RESULTS_DIR}/metadata/extract_siemens.py" "$first_dicom" "${RESULTS_DIR}/metadata/siemens_advanced.json"
        
        # Merge the Python-extracted data into our main JSON
        if [ -f "${RESULTS_DIR}/metadata/siemens_advanced.json" ]; then
            # Format the Python output to be merged into our JSON
            siemens_advanced=$(cat "${RESULTS_DIR}/metadata/siemens_advanced.json" | sed '1d;$d' | sed 's/^/  /')
            echo "$siemens_advanced," >> "$metadata_file"
        fi
    fi
    
    # Close the JSON file
    echo "  \"siemensSpecificTags\": \"extracted\"" >> "$metadata_file"
    echo "}" >> "$metadata_file"
    
    log_message "✅ Siemens metadata extracted to: $metadata_file"
}

# Extract metadata
extract_siemens_metadata "$SRC_DIR"

# Function to optimize ANTs parameters based on scanner metadata
optimize_ants_parameters() {
    local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
    
    # Default optimized parameters
    TEMPLATE_DIR="$ANTSPATH/data"
    EXTRACTION_TEMPLATE="T_template0.nii.gz"
    PROBABILITY_MASK="T_template0_BrainCerebellumProbabilityMask.nii.gz"
    REGISTRATION_MASK="T_template0_BrainCerebellumRegistrationMask.nii.gz"
    
    # Check if metadata exists
    if [ ! -f "$metadata_file" ]; then
        log_message "⚠️ No metadata found. Using default ANTs parameters."
        return
    fi
    
    # Check if jq is available (JSON parser)
    if ! command -v jq &> /dev/null; then
        log_message "⚠️ jq not found. Cannot parse metadata JSON. Using default ANTs parameters."
        return
    fi
    
    # Extract field strength from metadata
    local field_strength=$(jq -r '.fieldStrength // 3' "$metadata_file")
    
    # Optimize template selection based on field strength
    # ANTs provides different templates for different field strengths
    if (( $(echo "$field_strength > 2.5" | bc -l) )); then
        log_message "Optimizing for 3T scanner (field strength: $field_strength T)"
        EXTRACTION_TEMPLATE="T_template0.nii.gz"  # 3T template
    else
        log_message "Optimizing for 1.5T scanner (field strength: $field_strength T)"
        EXTRACTION_TEMPLATE="T_template0_1.5T.nii.gz"  # 1.5T template (if available)
        # If 1.5T template doesn't exist, it will fall back to default
        if [ ! -f "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" ]; then
            log_message "⚠️ 1.5T template not found. Using default 3T template."
            EXTRACTION_TEMPLATE="T_template0.nii.gz"
        fi
    fi
    
    # Check for Siemens MAGNETOM Sola specific optimizations
    local model=$(jq -r '.modelName // ""' "$metadata_file")
    if [[ "$model" == *"MAGNETOM Sola"* ]]; then
        log_message "Applying optimizations specific to Siemens MAGNETOM Sola"
        
        # Adjust parameters based on MAGNETOM Sola characteristics
        # These values are hypothetical examples - adjust based on actual testing
        REG_TRANSFORM_TYPE=3  # Use more aggressive transformation model
        REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"  # More robust mutual information
        N4_BSPLINE=200  # Optimized for MAGNETOM Sola field inhomogeneity profile
    fi
    
    log_message "✅ ANTs parameters optimized based on scanner metadata"
}

# Call the optimization function
optimize_ants_parameters

# Step 1: Convert DICOM to NIfTI using dcm2niix with Siemens optimizations
log_message "==== Step 1: DICOM to NIfTI Conversion ===="
log_message "convert DICOM files from ${SRC_DIR} to ${EXTRACT_DIR} in NiFTi .nii.gz format using dcm2niix"
dcm2niix -b y -z y -f "%p_%s" -o "$EXTRACT_DIR" -m y -p y -s y "${SRC_DIR}"

# Check conversion success
if [ $(find "$EXTRACT_DIR" -name "*.nii.gz" | wc -l) -eq 0 ]; then
    log_message "⚠️ No NIfTI files created. DICOM conversion may have failed."
    exit 1
fi

sleep 5

find "${EXTRACT_DIR}" -name "*.nii.gz" -print0 | while IFS= read -r -d '' file; do
  log_message "Checking ${file}..:"
  fslinfo "${file}" >> ${EXTRACT_DIR}/tmp_fslinfo.log
  fslstats "${file}" -R -M -S >> ${EXTRACT_DIR}/tmp_fslinfo.log
done

log_message "==== Combining multi-axis images for high-resolution volumes ===="
export COMBINED_DIR="${RESULTS_DIR}/combined"
combine_multiaxis_images "FLAIR" "${RESULTS_DIR}/combined"
log_message "Combined FLAIR"
combine_multiaxis_images "T1" "${RESULTS_DIR}/combined"
log_message "Combined T1"
combine_multiaxis_images "SWI" "${RESULTS_DIR}/combined"
log_message "Combined SWI"


log_message "Opening freeview with all the files in case you want to check"
nohup freeview ${RESULTS_DIR}/combined/*.nii.gz &

# Input directory
TRIMMED_OUTPUT_SUFFIX="${EXTRACT_DIR}_trimmed"

process_all_nifti_files_in_dir(){
    file="$1"
    # Skip if no files are found
    [ -e "$file" ] || continue

    echo "Processing: $file"

    # Get the base filename (without path)
    base=$(basename "${file}" .nii.gz)

    # Get smallest bounding box of nonzero voxels
    bbox=($(fslstats "${file}" -w))

    xmin=${bbox[0]}
    xsize=${bbox[1]}
    ymin=${bbox[2]}
    ysize=${bbox[3]}
    zmin=${bbox[4]}
    zsize=${bbox[5]}

    echo "Cropping region: X=($xmin, $xsize) Y=($ymin, $ysize) Z=($zmin, $zsize)"

    # Output filename
    output_file="${EXTRACT_DIR}/${base}${TRIMMED_OUTPUT_SUFFIX}.nii.gz"

    # Add padding to avoid cutting too close
    xpad=$PADDING_X
    ypad=$PADDING_Y
    zpad=$PADDING_Z

    # Get image dimensions
    xdim=$(fslval "$file" dim1)
    ydim=$(fslval "$file" dim2)
    zdim=$(fslval "$file" dim3)
    
    # Calculate safe starting points with padding
    safe_xmin=$((xmin > PADDING_X ? xmin - PADDING_X : 0))
    safe_ymin=$((ymin > PADDING_Y ? ymin - PADDING_Y : 0))
    safe_zmin=$((zmin > PADDING_Z ? zmin - PADDING_Z : 0))
    
    # Calculate safe sizes ensuring we don't exceed dimensions
    safe_xsize=$((xsize + 2*PADDING_X))
    if [ $((safe_xmin + safe_xsize)) -gt "$xdim" ]; then
        safe_xsize=$((xdim - safe_xmin))
    fi
    
    safe_ysize=$((ysize + 2*PADDING_Y))
    if [ $((safe_ymin + safe_ysize)) -gt "$ydim" ]; then
        safe_ysize=$((ydim - safe_ymin))
    fi
    
    safe_zsize=$((zsize + 2*PADDING_Z))
    if [ $((safe_zmin + safe_zsize)) -gt "$zdim" ]; then
        safe_zsize=$((zdim - safe_zmin))
    fi
    
    # Apply the cropping with safe boundaries
    fslroi "$file" "$output_file" $safe_xmin $safe_xsize $safe_ymin $safe_ysize $safe_zmin $safe_zsize

    echo "Saved trimmed file: ${output_file}"
    fslinfo "${output_file}"
}

export -f process_all_nifti_files_in_dir  # Ensure function is available in subshells

find "${RESULTS_DIR}/combined" -name "*.nii.gz" -print0 | parallel -0 -j 8 process_all_nifti_files_in_dir {}

echo "✅ All files processed to trim missing slices."

# Step 2: N4 Bias Field Correction with ANTs
log_message "==== Step 2: ANTs N4 Bias Field Correction ===="
mkdir -p "${RESULTS_DIR}/bias_corrected"

# N4BiasFieldCorrection parameters
###-d 3 - Dimensionality parameter
###
###Specifies that we're working with 3D image data
###Options: 2, 3, or 4 (for 2D, 3D, or 4D images)
###
###-b [200] - B-spline grid resolution control
###
###Controls the resolution of the B-spline mesh used to model the bias field
###Lower values (e.g., [100]) = smoother bias field with less detail
###Higher values (e.g., [300]) = more detailed bias field that captures local variations
###Can specify different resolutions per dimension: [200x200x200]
###
###-s 4 - Shrink factor
###
###Downsamples the input image to speed up processing
###Higher values = faster but potentially less accurate
###Typical values: 2-4
###For high-resolution images, 4 is good; for lower resolution, use 2
###
###Other important parameters that could be configurable:
###-w - Weight image
###
###Optional binary mask defining the region where bias correction is applied
###Different from the exclusion mask (-x)
###
###-n - Number of histogram bins used for N4
###
###Default is usually 200
###Controls precision of intensity histogram
###Lower = faster but less precise; higher = more precise but slower
###
###--weight-spline-order - B-spline interpolation order
###
###Default is 3
###Controls smoothness of the B-spline interpolation
###Range: 0-5 (higher = smoother but more computation)

process_n4_correction() {
    local file="$1"
    local basename=$(basename "$file" .nii.gz)
    local output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"

    log_message "Performing bias correction on: $basename"

    # Create an initial brain mask for better bias correction
    #antsBrainExtraction.sh -d 3 -a "$file" -o "${RESULTS_DIR}/bias_corrected/${basename}_" \
    #    -e "$ANTSPATH/data/T_template0.nii.gz" \
    #    -m "$ANTSPATH/data/T_template0_BrainCerebellumProbabilityMask.nii.gz" \
    #    -f "$ANTSPATH/data/T_template0_BrainCerebellumRegistrationMask.nii.gz"

    antsBrainExtraction.sh -d 3 -a "$file" -o "${output_prefix}" \
        -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
        -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

    # Get sequence-specific N4 parameters
    n4_params=($(get_n4_parameters "$file"))

    # Run N4 bias correction
    #N4BiasFieldCorrection -d 3 \
    #j    -i "$file" \
    #    -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
    #    -o "$output_file" \
    #    -b [${n4_params[2]}] \
    #    -s ${n4_params[3]} \
    #    -c "[${n4_params[0]},${n4_params[1]}]"

    # Use optimized parameters from metadata if available
    if [[ -n "$N4_BSPLINE" ]]; then
        N4BiasFieldCorrection -d 3 \
            -i "$file" \
            -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
            -o "$output_file" \
            -b [$N4_BSPLINE] \
            -s ${n4_params[3]} \
            -c "[${n4_params[0]},${n4_params[1]}]"
    else
        N4BiasFieldCorrection -d 3 \
            -i "$file" \
            -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
            -o "$output_file" \
            -b [${n4_params[2]}] \
            -s ${n4_params[3]} \
            -c "[${n4_params[0]},${n4_params[1]}]"
    fi

    log_message "Saved bias-corrected image to: $output_file"
}

export -f process_n4_correction get_n4_parameters log_message  # Export functions

find "$COMBINED_DIR" -name "*.nii.gz" -maxdepth 1 -type f -print0 | \
parallel -0 -j 8 process_n4_correction {}

log_message "✅ Bias field correction complete."

# Step 3: ANTs-based motion correction and registration
log_message "==== Step 3: ANTs Motion Correction and Registration ===="
mkdir -p "${RESULTS_DIR}/registered"

# First identify a T1w reference image if available
reference_image=""
#t1_files=($(find "$RESULTS_DIR/bias_corrected" -name "*T1*n4.nii.gz" -o -name "*T1*n4.nii.gz"))
t1_files=($(find "$RESULTS_DIR/standardized" -name "*T1*n4_std.nii.gz"))

if [ ${#t1_files[@]} -gt 0 ]; then
  best_t1=""
  best_res=0
  
  for t1 in "${t1_files[@]}"; do
      xdim=$(fslval "$t1" dim1)
      ydim=$(fslval "$t1" dim2)
      zdim=$(fslval "$t1" dim3)
      res=$((xdim * ydim * zdim))
  
      if [ $res -gt $best_res ]; then
          best_t1="$t1"
          best_res=$res
      fi
  done
  
  reference_image="$best_t1"
  log_message "Using ${reference_image} as reference for registration"
else
   # If no T1w found, use the first file
   reference_image=$(find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" | head -1)
   log_message "No T1w reference found. Using ${reference_image} as reference"
fi

# Process all images - register to the reference
#find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" -print0 | while IFS= read -r -d '' file; do
find "$RESULTS_DIR/standardized" -name "*n4_std.nii.gz" -print0 | while IFS= read -r -d '' file; do

    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/registered/${basename}_"
    
    log_message "Registering: $basename to reference using ANTs"
    
    # For FLAIR or T2 to T1 registration, use mutual information metric
    # This handles cross-modality registration better
    if [[ "$file" == *"FLAIR"* || "$file" == *"T2"* ]]; then
        # Use optimized cross-modality registration metric if available
        if [[ -n "$REG_METRIC_CROSS_MODALITY" ]]; then
            antsRegistrationSyN.sh -d 3 \
                -f "$reference_image" \
                -m "$file" \
                -o "$output_prefix" \
                -t $REG_TRANSFORM_TYPE \
                -n 4 \
                -p f \
                -j 1 \
                -x "$REG_METRIC_CROSS_MODALITY"
        else
            antsRegistrationSyN.sh -d 3 \
                -f "$reference_image" \
                -m "$file" \
                -o "$output_prefix" \
                -t r \
                -n 4 \
                -p f \
                -j 1
        fi
    else
        # For same modality, use cross-correlation which works better
        antsRegistrationSyN.sh -d 3 \
            -f "$reference_image" \
            -m "$file" \
            -o "$output_prefix" \
            -t r \
            -n 4 \
            -p f \
            -j 1
    fi
    
    log_message "Saved registered image to: ${output_prefix}Warped.nii.gz"
    
    # Create a symlink with a more intuitive name
    ln -sf "${output_prefix}Warped.nii.gz" "${RESULTS_DIR}/registered/${basename}_reg.nii.gz"
done

log_message "✅ ANTs registration complete."

# Step 4: ANTs-based quality assessment 
log_message "==== Step 4: ANTs-based Quality Assessment ===="
mkdir -p "${RESULTS_DIR}/quality_checks"

# Process each registered file
find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/quality_checks/${basename}_"
    
    log_message "Performing quality checks on: $basename"
    
    # Extract brain with ANTs for more accurate SNR calculation
    antsBrainExtraction.sh -d 3 \
        -a "$file" \
        -o "$output_prefix" \
    #    -e "$ANTSPATH/data/T_template0.nii.gz" \
    #    -m "$ANTSPATH/data/T_template0_BrainCerebellumProbabilityMask.nii.gz" \
    #    -f "$ANTSPATH/data/T_template0_BrainCerebellumRegistrationMask.nii.gz"
        -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
        -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
        -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

    
    # Calculate SNR using ANTs tools
    # Get mean signal in brain
    signal=$(ImageMath 3 ${output_prefix}signal.nii.gz m "$file" "${output_prefix}BrainExtractionMask.nii.gz")
    signal_mean=$(ImageStats "$file" "${output_prefix}BrainExtractionMask.nii.gz" 2 | awk '{print $2}')
    
    # Create background mask (inverted brain mask with erosion)
    ImageMath 3 "${output_prefix}background_mask.nii.gz" MC "${output_prefix}BrainExtractionMask.nii.gz" 0
    ImageMath 3 "${output_prefix}background_mask_eroded.nii.gz" ME "${output_prefix}background_mask.nii.gz" 3
    
    # Get noise standard deviation in background
    noise_sd=$(ImageStats "$file" "${output_prefix}background_mask_eroded.nii.gz" 5 | awk '{print $2}')
    
    # Calculate SNR
    snr=$(echo "$signal_mean / $noise_sd" | bc -l)
    
    # Save to log
    echo "$basename,$snr" >> "${RESULTS_DIR}/quality_checks/snr_values.csv"
    log_message "SNR for $basename: $snr"
    
    # For qualitative assessment, generate a check image
    CreateTiledMosaic -i "$file" -r "$reference_image" -o "${output_prefix}check.png" -a 0.3 -t -1x-1 -p mask -m "${output_prefix}BrainExtractionMask.nii.gz"
done

log_message "✅ Quality assessment complete."

# Step 5: ANTs-based intensity normalization for FLAIR
log_message "==== Step 5: ANTs-based Intensity Normalization ===="
mkdir -p "${RESULTS_DIR}/intensity_normalized"

# Find all FLAIR images after registration
flair_files=($(find "$RESULTS_DIR/registered" -name "*FLAIR*reg.nii.gz"))

if [ ${#flair_files[@]} -gt 0 ]; then
    log_message "Found ${#flair_files[@]} FLAIR images to normalize"
    
    for file in "${flair_files[@]}"; do
        basename=$(basename "$file" .nii.gz)
        output_file="${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz"
        
        log_message "Normalizing: $basename"
        
        # Advanced intensity normalization using N4 and histogram matching
        ImageMath 3 "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz" RescaleImage "$file" 0 1000
        
        # Use N4 again for better results on the registered data
        N4BiasFieldCorrection -d 3 \
            -i "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz" \
            -o "$output_file" \
            -b [200] \
            -s 2 \
            -c [50x50x50,0.000001]
        
        # Clean up
        rm -f "${RESULTS_DIR}/intensity_normalized/${basename}_temp.nii.gz"
        
        log_message "Saved intensity-normalized image to: $output_file"
    done
    
    log_message "✅ Intensity normalization complete for FLAIR images."
else
    log_message "⚠️ No FLAIR images found for intensity normalization."
fi

log_message "==== Step 2.5: Standardizing Image Dimensions ===="
mkdir -p "${RESULTS_DIR}/standardized"

# Target dimensions (512×512×512)
TARGET_X=512
TARGET_Y=512
TARGET_Z=512

standardize_dimensions() {
    local input_file="$1"
    local basename=$(basename "$input_file" .nii.gz)
    local output_file="${RESULTS_DIR}/standardized/${basename}_std.nii.gz"
    
    log_message "Standardizing dimensions for: $basename"
    
    # Get current image dimensions and spacings
    local x_dim=$(fslval "$input_file" dim1)
    local y_dim=$(fslval "$input_file" dim2)
    local z_dim=$(fslval "$input_file" dim3)
    local x_pixdim=$(fslval "$input_file" pixdim1)
    local y_pixdim=$(fslval "$input_file" pixdim2)
    local z_pixdim=$(fslval "$input_file" pixdim3)
    
    # Calculate target voxel size to maintain physical dimensions
    # This ensures the brain size remains the same, just with different sampling
    local physical_x=$(echo "$x_dim * $x_pixdim" | bc -l)
    local physical_y=$(echo "$y_dim * $y_pixdim" | bc -l)
    local physical_z=$(echo "$z_dim * $z_pixdim" | bc -l)
    
    local target_x_pixdim=$(echo "$physical_x / $TARGET_X" | bc -l)
    local target_y_pixdim=$(echo "$physical_y / $TARGET_Y" | bc -l)
    local target_z_pixdim=$(echo "$physical_z / $TARGET_Z" | bc -l)
    
    # Use ANTs ResampleImage for high-quality resampling
    # This is better than using FSL's flirt for pure resampling
    ResampleImage 3 \
        "$input_file" \
        "$output_file" \
        ${TARGET_X}x${TARGET_Y}x${TARGET_Z} \
        0 # 0 = use linear interpolation, 1 = use nearest neighbor
    
    log_message "Saved standardized image to: $output_file"
    
    # Update NIFTI header with correct physical dimensions
    # This ensures consistent physical space representation
    c3d "$output_file" -spacing "$target_x_pixdim"x"$target_y_pixdim"x"$target_z_pixdim"mm -o "$output_file"
    
    # Note: An alternative approach is to maintain voxel size and pad/crop:
    # c3d "$input_file" -pad-to $TARGET_X $TARGET_Y $TARGET_Z 0 -o "$output_file"
}

export -f standardize_dimensions log_message

# Process all bias-corrected images
find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" -print0 | \
parallel -0 -j 8 standardize_dimensions {}

log_message "✅ Dimension standardization complete."

# Update reference to use standardized files for subsequent steps
# Modify this line at the registration step
# Find all T1w reference images if available
reference_image=""
t1_files=($(find "$RESULTS_DIR/standardized" -name "*T1*n4_std.nii.gz"))


# Step 6: Hyperintensity detection for FLAIR (using ANTs tools)
if [ ${#flair_files[@]} -gt 0 ]; then
    log_message "==== Step 6: Hyperintensity Detection on FLAIR ===="
    mkdir -p "${RESULTS_DIR}/hyperintensities"
    
    for file in "${flair_files[@]}"; do
        basename=$(basename "$file" .nii.gz)
        output_prefix="${RESULTS_DIR}/hyperintensities/${basename}_"
        
        # Use normalized version if available
        if [ -f "${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz" ]; then
            input_file="${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz"
        else
            input_file="$file"
        fi
        
        log_message "Detecting hyperintensities on: $basename"
        
        # First get brain mask
        cp "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" "${output_prefix}brain_mask.nii.gz"
        
        # Now find T1 to use for segmentation
        t1_reg=""
        for t1_candidate in "${RESULTS_DIR}/registered/"*T1*reg.nii.gz; do
            if [ -f "$t1_candidate" ]; then
                t1_reg="$t1_candidate"
                break
            fi
        done
        
        # If T1 is available, use it for tissue segmentation
        if [ -n "$t1_reg" ]; then
            log_message "Using $t1_reg for tissue segmentation"
            
            # Run ANTs segmentation on T1
             Atropos -d 3 \
                 -a "$input_file" \
                 -x "${output_prefix}brain_mask.nii.gz" \
                 -o [${output_prefix}atropos_segmentation.nii.gz,${output_prefix}atropos_prob%d.nii.gz] \
                 -c [${ATROPOS_CONVERGENCE}] \
                 -m ${ATROPOS_MRF} \
                 -i ${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}] \
                 -k Gaussian
            ln -sf "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}segmentation.nii.gz"

            
                        
            # Extract WM (label 3) and GM (label 2)
            ThresholdImage 3 "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            ThresholdImage 3 "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2


            log_message "T1-based tissue segmentation complete."
        else
            # Fallback to intensity-based segmentation on FLAIR
            log_message "No T1 found. Using intensity-based segmentation on FLAIR."
            
            # Use Otsu thresholding to create rough tissue classes
            ThresholdImage 3 "$input_file" "${output_prefix}otsu.nii.gz" Otsu 3 "${output_prefix}brain_mask.nii.gz"
            
            # Extract approximate WM (highest intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            
            # Extract approximate GM (middle intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2
        fi
        
  # Method 1: Morphological approach for hyperintensity detection
  log_message "Using morphological approach for hyperintensity detection..."
  
  # First get WM statistics for initial threshold
  wm_mean=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 2 | awk '{print $2}')
  wm_sd=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 5 | awk '{print $2}')
  
  # Get sequence-specific parameters
  params=($(set_sequence_params "$file"))
  sequence_type="${params[0]}"
  iterations="${params[1]}"
  threshold_multiplier="${params[2]}"
  
  # Define threshold based on sequence type
  threshold=$(echo "$wm_mean + $threshold_multiplier * $wm_sd" | bc -l)
  log_message "$sequence_type WM mean: $wm_mean, WM SD: $wm_sd, Threshold multiplier: $threshold_multiplier, Final threshold: $threshold"
  
  # Initial threshold using intensity
  ThresholdImage 3 "$input_file" "${output_prefix}init_threshold.nii.gz" $threshold 99999 "${output_prefix}brain_mask.nii.gz"
  
  # Create tissue-specific masks to avoid false positives
  # Exclude CSF and non-brain areas
  if [ -f "${output_prefix}wm_mask.nii.gz" ] && [ -f "${output_prefix}gm_mask.nii.gz" ]; then
      # Combine WM and GM masks
      ImageMath 3 "${output_prefix}brain_tissue.nii.gz" + "${output_prefix}wm_mask.nii.gz" "${output_prefix}gm_mask.nii.gz"
      
      # Apply tissue mask to the initial threshold
      ImageMath 3 "${output_prefix}tissue_threshold.nii.gz" m "${output_prefix}init_threshold.nii.gz" "${output_prefix}brain_tissue.nii.gz"
  else
      # Just use the brain mask if tissue segmentation isn't available
      cp "${output_prefix}init_threshold.nii.gz" "${output_prefix}tissue_threshold.nii.gz"
  fi
  
  # Morphological operations to clean up the segmentation
  # Erosion to remove small connections and noise
  ImageMath 3 "${output_prefix}eroded.nii.gz" ME "${output_prefix}tissue_threshold.nii.gz" 1
  
  # Dilation to recover original size while maintaining disconnected regions
  ImageMath 3 "${output_prefix}eroded_dilated.nii.gz" MD "${output_prefix}eroded.nii.gz" 1
  
  # Connected component analysis to remove small islands
  ImageMath 3 "${output_prefix}hyperintensities_clean.nii.gz" GetLargestComponents "${output_prefix}eroded_dilated.nii.gz" $MIN_HYPERINTENSITY_SIZE
  
  # Calculate final hyperintensity volume and other metrics
  hyper_voxels=$(ImageStats "${output_prefix}hyperintensities_clean.nii.gz" 0 | grep "Voxels" | cut -d: -f2)
  log_message "Detected $hyper_voxels hyperintensity voxels"
  
  # Measure intensity distribution within hyperintensities
  mean_intensity=$(ImageStats "$input_file" "${output_prefix}hyperintensities_clean.nii.gz" 2 | awk '{print $2}')
  peak_intensity=$(ImageStats "$input_file" "${output_prefix}hyperintensities_clean.nii.gz" 9 | awk '{print $2}')
  log_message "Hyperintensity mean intensity: $mean_intensity, peak intensity: $peak_intensity"
  
  log_message "✅ Morphological hyperintensity detection complete."
  
          
 # Create overlay files for visualization in freeview
 # These .mgz files are appropriate for freeview overlay
 # Scale probability map to 0-100 range for better visualization
 ImageMath 3 "${output_prefix}hyperintensities_prob_scaled.nii.gz" m "${output_prefix}hyperintensities_prob.nii.gz" 100
          
 # Convert all results to .mgz format for FSL/Freeview
 # This requires mri_convert from FreeSurfer
 mri_convert "${output_prefix}hyperintensities_clean.nii.gz" "${output_prefix}hyperintensities_clean.mgz"
 mri_convert "${output_prefix}hyperintensities_atropos.nii.gz" "${output_prefix}hyperintensities_atropos.mgz"
 mri_convert "${output_prefix}hyperintensities_prob_scaled.nii.gz" "${output_prefix}hyperintensities_prob.mgz"
          
 # Also convert the normalized FLAIR for viewing
 mri_convert "$input_file" "${output_prefix}flair_norm.mgz"
          
 log_message "Converted results to .mgz format for Freeview."
          
 # Create a convenience script for opening in freeview with proper overlays
 cat > "${output_prefix}view_in_freeview.sh" << EOL
  
# Open results in Freeview with proper overlays
freeview -v "${output_prefix}flair_norm.mgz" \\
         -v "${output_prefix}hyperintensities_clean.mgz:colormap=heat:opacity=0.5" \\
         -v "${output_prefix}hyperintensities_prob.mgz:colormap=jet:opacity=0.7"
EOL
        chmod +x "${output_prefix}view_in_freeview.sh"
    done
fi

# Final step: Create cropped versions with padding using ANTs (better than FSL's fslroi)
log_message "==== Creating Cropped Versions with Padding ===="
mkdir -p "${RESULTS_DIR}/cropped"

find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"
    
    log_message "Creating cropped version with padding for: $basename"
    
    # Use ExtractRegionFromImageByMask from ANTs
    # This provides better cropping with customizable padding
    c3d "$file" -as S "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" -push S -thresh $C3D_CROP_THRESHOLD 1 1 0 -trim ${C3D_PADDING_MM}mm -o "$output_file"
    
    log_message "Saved cropped file: $output_file"
done

log_message "✅ All processing steps complete!"

# Create a summary report
log_message "==== Creating Summary Report ===="

# Find all generated hyperintensity files
hyperintensity_files=($(find "${RESULTS_DIR}/hyperintensities" -name "*hyperintensities_clean.nii.gz"))

# Calculate volume statistics
echo "Hyperintensity Volumetric Results:" > "${RESULTS_DIR}/hyperintensity_report.txt"
echo "-----------------------------------" >> "${RESULTS_DIR}/hyperintensity_report.txt"
echo "Filename, Volume (mm³), % of Brain Volume" >> "${RESULTS_DIR}/hyperintensity_report.txt"

for file in "${hyperintensity_files[@]}"; do
    basename=$(basename "$file" _hyperintensities_clean.nii.gz)
    
    # Get voxel volume in mm³
    voxel_volume=$(c3d "$file" -info-full | grep "Voxel spacing" | awk '{print $4 * $5 * $6}')
    
    # Get number of hyperintensity voxels
    num_voxels=$(c3d "$file" -thresh 0.5 inf 1 0 -voxel-sum | awk '{print $3}')
    
    # Calculate total volume
    volume=$(echo "$voxel_volume * $num_voxels" | bc -l)
    
    # Get brain mask and calculate brain volume
    brain_mask="${RESULTS_DIR}/hyperintensities/${basename}_reg_brain_mask.nii.gz"
    brain_voxels=$(c3d "$brain_mask" -thresh 0.5 inf 1 0 -voxel-sum | awk '{print $3}')
    brain_volume=$(echo "$voxel_volume * $brain_voxels" | bc -l)
    
    # Calculate percentage
    percentage=$(echo "scale=4; ($volume / $brain_volume) * 100" | bc -l)
    
    echo "$basename, $volume, $percentage%" >> "${RESULTS_DIR}/hyperintensity_report.txt"
done

log_message "Summary report created at ${RESULTS_DIR}/hyperintensity_report.txt"

# Create a comprehensive freeview script that includes all relevant overlays
cat > "${RESULTS_DIR}/view_all_results.sh" << EOL

# Open all results in Freeview with proper overlays

# Find FLAIR files
flair_files=(\$(find "${RESULTS_DIR}/intensity_normalized" -name "*FLAIR*norm.nii.gz"))

if [ \${#flair_files[@]} -gt 0 ]; then
    # Use the first FLAIR as base
    base_file="\${flair_files[0]}"
    
    # Build command
    cmd="freeview -v \$base_file"
    
    # Add hyperintensity overlays
    for overlay in "${RESULTS_DIR}/hyperintensities/"*hyperintensities_clean.nii.gz; do
        if [ -f "\$overlay" ]; then
            cmd="\$cmd -v \$overlay:colormap=heat:opacity=0.5"
        fi
    done
    
    # Add probability map overlays
    for overlay in "${RESULTS_DIR}/hyperintensities/"*hyperintensities_prob.nii.gz; do
        if [ -f "\$overlay" ]; then
            cmd="\$cmd -v \$overlay:colormap=jet:opacity=0.3:visible=0"
        fi
    done
    
    # Execute command
    log_message "Running: \$cmd"
    eval \$cmd
else
    log_message "No FLAIR files found. Cannot open freeview."
fi
EOL
chmod +x "${RESULTS_DIR}/view_all_results.sh"

log_message "Created comprehensive freeview script at ${RESULTS_DIR}/view_all_results.sh"
log_message "==== Processing Pipeline Complete! ===="

