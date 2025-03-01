#!/usr/local/bin/bash
set -e
set -u
set -o pipefail


# Process DiCOM MRI images into NiFTi files appropriate for use in FSL/freeview
# My intention is to try to use the `ants` library as well where it can optimise conversions etc.. this is a second attempt only

SRC_DIR="../DiCOM"
EXTRACT_DIR="../extracted"
RESULTS_DIR="../mri_results"
# N4 Bias Field Correction parameters
N4_ITERATIONS="50x50x50x50"
N4_CONVERGENCE="0.000001"

#!/usr/local/bin/bash
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
OUTPUT_DATATYPE="int16"

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

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
ANTS_THREADS=$(nproc)

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
log() {
  local level=$1
  local message=$2
  
  case $level in
    "INFO") echo -e "${BLUE}[INFO]${NC} $message" ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
    "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
  esac
}

standardize_datatype() {
  local input=$1
  local output=$2
  local datatype=${3:-"float"}
  
  fslmaths "$input" -dt "$datatype" "$output" -odt "$datatype"
  log "Standardized $input to $datatype datatype"
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
    
    echo "${params[@]}"
}




# Function to check if a command exists
check_command() {
  local cmd=$1
  local package=$2
  local install_hint=${3:-""}
  
  if command -v $cmd &> /dev/null; then
    log "SUCCESS" "✓ $package is installed ($(command -v $cmd))"
    return 0
  else
    log "ERROR" "✗ $package is not installed or not in PATH"
    if [ -n "$install_hint" ]; then
      log "INFO" "  $install_hint"
    fi
    return 1
  fi
}

# Function to check for ANTs tools
check_ants() {
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  
  log "INFO" "Checking ANTs tools..."
  
  # Check for ANTSPATH environment variable
  if [ -z "$ANTSPATH" ]; then
    log "WARNING" "ANTSPATH environment variable is not set. This may cause issues with some ANTs scripts."
  else
    log "SUCCESS" "ANTSPATH is set to $ANTSPATH"
  fi
  
  # Check each required ANTs tool
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log "ERROR" "Some ANTs tools are missing. Install ANTs from:"
    log "INFO" "  • Using Homebrew: brew install ants"
    log "INFO" "  • Or from source: https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-MacOS"
    return 1
  else
    return 0
  fi
}

# Function to check for FSL tools
check_fsl() {
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  
  log "INFO" "Checking FSL tools..."
  
  # Check for FSLDIR environment variable
  if [ -z "$FSLDIR" ]; then
    log "WARNING" "FSLDIR environment variable is not set. This may cause issues with some FSL scripts."
  else
    log "SUCCESS" "FSLDIR is set to $FSLDIR"
  fi
  
  # Check each required FSL tool
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log "ERROR" "Some FSL tools are missing. Install FSL from:"
    log "INFO" "  • Download from: https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FslInstallation"
    log "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for FreeSurfer tools
check_freesurfer() {
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  
  log "INFO" "Checking FreeSurfer tools..."
  
  # Check for FREESURFER_HOME environment variable
  if [ -z "$FREESURFER_HOME" ]; then
    log "WARNING" "FREESURFER_HOME environment variable is not set. This may cause issues with some FreeSurfer tools."
  else
    log "SUCCESS" "FREESURFER_HOME is set to $FREESURFER_HOME"
  fi
  
  # Check each required FreeSurfer tool
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  
  if [ $missing -gt 0 ]; then
    log "ERROR" "Some FreeSurfer tools are missing. Install FreeSurfer from:"
    log "INFO" "  • Download from: https://surfer.nmr.mgh.harvard.edu/fswiki/DownloadAndInstall"
    log "INFO" "  • Follow the macOS installation instructions"
    return 1
  else
    return 0
  fi
}

# Function to check for Convert3D (c3d)
check_c3d() {
  log "INFO" "Checking Convert3D..."
  
  if ! check_command "c3d" "Convert3D" "Download from: http://www.itksnap.org/pmwiki/pmwiki.php?n=Downloads.C3D"; then
    return 1
  else
    return 0
  fi
}

# Function to check for dcm2niix
check_dcm2niix() {
  log "INFO" "Checking dcm2niix..."
  
  if ! check_command "dcm2niix" "dcm2niix" "Install with: brew install dcm2niix"; then
    return 1
  else
    # Check version
    local version=$(dcm2niix -v 2>&1 | head -n 1)
    log "INFO" "  dcm2niix version: $version"
    return 0
  fi
}

# Check if running on macOS
check_os() {
  log "INFO" "Checking operating system..."
  
  if [[ "$(uname)" == "Darwin" ]]; then
    log "SUCCESS" "✓ Running on macOS"
    
    # Check if running on Apple Silicon
    if [[ "$(uname -m)" == "arm64" ]]; then
      log "SUCCESS" "✓ Running on Apple Silicon"
    else
      log "INFO" "Running on Intel-based Mac"
    fi
    return 0  
  else
    log "ERROR" "This script is designed for macOS"
    exit 1
  fi
}

error_count=0

log "INFO" "==== MRI Processing Dependency Checker ===="

check_os || error_count=$((error_count+1))
check_dcm2niix || error_count=$((error_count+1))
check_ants || error_count=$((error_count+1))
check_fsl || error_count=$((error_count+1))
check_freesurfer || error_count=$((error_count+1))
check_c3d || error_count=$((error_count+1))

log "INFO" "==== Checking optional but recommended tools ===="

# Check for ImageMagick (useful for image manipulation)
check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || log "WARNING" "ImageMagick is recommended for image conversions"

# Check for parallel (useful for parallel processing)
check_command "parallel" "GNU Parallel" "Install with: brew install parallel" || log "WARNING" "GNU Parallel is recommended for faster processing"

# Summary
echo ""
log "INFO" "==== Dependency Check Summary ===="

if [ $error_count -eq 0 ]; then
  log "SUCCESS" "All required dependencies are installed!"
else
  log "ERROR" "$error_count required dependencies are missing."
  log "INFO" "Please install the missing dependencies before running the processing pipeline."
  exit 1
fi

# Create directories
mkdir -p "$EXTRACT_DIR"
mkdir -p "$RESULTS_DIR"

# Check for required dependencies
if ! command -v fslstats &> /dev/null || ! command -v fslroi &> /dev/null; then
    echo "Error: FSL is not installed or not in your PATH."
    exit 1
fi

NUM_SRC_DICOM_FILES=`find ${SRC_DIR} -name Image"*"  | wc -l`

echo "There are ${NUM_SRC_DICOM_FILES} in ${SRC_DIR}. You have 5 seconds to cancel the script if that's wrong. Going to extract to ${EXTRACT_DIR}"
sleep 5 

# Using -no-exit-on-error -auto-runseq here, it means you should probably check the output.txt after the script runs & the console output
#echo "Using dcmunpack to convert DICOM files from ${SRC_DIR} to ${EXTRACT_DIR} in NiFTi .nii.gz format"
#echo "Using -no-exit-on-error -auto-runseq here, it means you should probably check the output.txt after the script runs & the console output"
#dcmunpack -src "${SRC_DIR}" -targ "${EXTRACT_DIR}" -fsfast -no-exit-on-error -auto-runseq nii.gz

# Add this function to combine SAG/COR/AX versions of the same sequence type
combine_multiaxis_images() {
    local sequence_type="$1"
    local output_dir="$2"
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Find all matching sequence files
    sag_files=($(find "$EXTRACT_DIR" -name "*SAG*${sequence_type}*.nii.gz"))
    cor_files=($(find "$EXTRACT_DIR" -name "*COR*${sequence_type}*.nii.gz"))
    ax_files=($(find "$EXTRACT_DIR" -name "*AX*${sequence_type}*.nii.gz"))
    
    log "INFO" "Found ${#sag_files[@]} sagittal, ${#cor_files[@]} coronal, and ${#ax_files[@]} axial ${sequence_type} files"
    
    # Skip if no files found
    if [ ${#sag_files[@]} -eq 0 ] && [ ${#cor_files[@]} -eq 0 ] && [ ${#ax_files[@]} -eq 0 ]; then
        log "WARNING" "No ${sequence_type} files found to combine"
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

    # Process coronal files (similar code for coronal and axial)
    # ... (similar code for finding best_cor and best_ax)
    
    # Create output filename
    local output_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"
    
    # Register and combine the best files using ANTs
    log "INFO" "Combining best ${sequence_type} images to create high-resolution volume"
    
    if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
        # Use ANTs multivariate template creation to combine the three views
        antsMultivariateTemplateConstruction2.sh \
            -d 3 \
            -o "${output_dir}/${sequence_type}_template_" \
            -i 4 \
            -g 0.2 \
            -j ${ANTS_THREADS} \
            -f 6x4x2x1 \
            -s 3x2x1x0 \
            -q 100x70x50x10 \
            -t SyN \
            -m CC \
            -c 0 \
            "$best_sag" "$best_cor" "$best_ax"
        
        # Move the final template to our desired output
        mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$output_file"
        
        # Ensure INT16 output format
        standardize_datatype "$output_file" "$output_file" "$OUTPUT_DATATYPE"
        
        log "SUCCESS" "Created high-resolution ${sequence_type} volume: $output_file"
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
        
        log "INFO" "Only one orientation available for ${sequence_type}, using: $best_file"
        return 0
    else
        log "ERROR" "No suitable ${sequence_type} files found"
        return 1
    fi
}



# Get sequence-specific N4 parameters
get_n4_parameters() {
    local file="$1"
    
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
    
    echo "$iterations" "$convergence" "$bspline" "$shrink"
}


# Function for logging with timestamps
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$log_file"
}

# Step 1: Convert DICOM to NIfTI using dcm2niix with Siemens optimizations
log "==== Step 1: DICOM to NIfTI Conversion ===="
print "convert DICOM files from ${SRC_DIR} to ${EXTRACT_DIR} in NiFTi .nii.gz format using dcm2niix"
dcm2niix -b y -z y -f "%p_%s" -o "$EXTRACT_DIR" -m y -p y -s y "${SRC_DIR}"

# Check conversion success
if [ $(find "$EXTRACT_DIR" -name "*.nii.gz" | wc -l) -eq 0 ]; then
    log "⚠️ No NIfTI files created. DICOM conversion may have failed."
    exit 1
fi

sleep 5

find "${EXTRACT_DIR}" -name "*.nii.gz" -print0 | while IFS= read -r -d '' file; do
  echo "Checking ${file}..:"
  fslinfo "${file}"
  fslstats "${file}" -R -M -S
done

echo "Opening freeview with all the files in case you want to check"
nohup freeview ${EXTRACT_DIR}/*.nii.gz &

echo "Continuing anyway.. "

# Input directory
TRIMMED_OUTPUT_SUFFIX="${EXTRACT_DIR}_trimmed"

# Loop over all NIfTI files in the directory
for file in ${EXTRACT_DIR}/*.nii.gz; do
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
    xpad=5
    ypad=5
    zpad=5

    fslroi "$file" "$output_file" $((xmin-xpad)) $((xsize+2*xpad)) $((ymin-ypad)) $((ysize+2*ypad)) $((zmin-zpad)) $((zsize+2*zpad))

    echo "Saved trimmed file: ${output_file}"
    fslinfo "${output_file}"
done

echo "✅ All files processed to trim missing slices."


# Step 2: N4 Bias Field Correction with ANTs
log "==== Step 2: ANTs N4 Bias Field Correction ===="
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


find "$EXTRACT_DIR" -name "*.nii.gz" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"
    
    log "Performing bias correction on: $basename"
    
    # Create an initial brain mask for better bias correction
    antsBrainExtraction.sh -d 3 -a "$file" -o "${RESULTS_DIR}/bias_corrected/${basename}_" -e "$ANTSPATH/data/T_template0.nii.gz" -m "$ANTSPATH/data/T_template0_BrainCerebellumProbabilityMask.nii.gz" -f "$ANTSPATH/data/T_template0_BrainCerebellumRegistrationMask.nii.gz"
    n4_params=($(get_n4_parameters "$file"))
    N4BiasFieldCorrection -d 3 \
      -i "$file" \
      -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
      -o "$output_file" \
      -b [${n4_params[2]}] \
      -s ${n4_params[3]} \
      -c "[${n4_params[0]},${n4_params[1]}]"
        
    log "Saved bias-corrected image to: $output_file"
done

log "✅ Bias field correction complete."

# Step 3: ANTs-based motion correction and registration
log "==== Step 3: ANTs Motion Correction and Registration ===="
mkdir -p "${RESULTS_DIR}/registered"

# First identify a T1w reference image if available
reference_image=""
t1_files=($(find "$RESULTS_DIR/bias_corrected" -name "*T1*n4.nii.gz" -o -name "*T1*n4.nii.gz"))

if [ ${#t1_files[@]} -gt 0 ]; then
    reference_image="${t1_files[0]}"
    log "Using ${reference_image} as reference for registration"
else
    # If no T1w found, use the first file
    reference_image=$(find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" | head -1)
    log "No T1w reference found. Using ${reference_image} as reference"
fi

# Process all images - register to the reference
find "$RESULTS_DIR/bias_corrected" -name "*n4.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/registered/${basename}_"
    
    log "Registering: $basename to reference using ANTs"
    
    # For FLAIR or T2 to T1 registration, use mutual information metric
    # This handles cross-modality registration better
    if [[ "$file" == *"FLAIR"* || "$file" == *"T2"* ]]; then
        antsRegistrationSyN.sh -d 3 \
            -f "$reference_image" \
            -m "$file" \
            -o "$output_prefix" \
            -t r \
            -n 4 \
            -p f \
            -j 1
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
    
    log "Saved registered image to: ${output_prefix}Warped.nii.gz"
    
    # Create a symlink with a more intuitive name
    ln -sf "${output_prefix}Warped.nii.gz" "${RESULTS_DIR}/registered/${basename}_reg.nii.gz"
done

log "✅ ANTs registration complete."

# Step 4: ANTs-based quality assessment 
log "==== Step 4: ANTs-based Quality Assessment ===="
mkdir -p "${RESULTS_DIR}/quality_checks"

# Process each registered file
find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_prefix="${RESULTS_DIR}/quality_checks/${basename}_"
    
    log "Performing quality checks on: $basename"
    
    # Extract brain with ANTs for more accurate SNR calculation
    antsBrainExtraction.sh -d 3 \
        -a "$file" \
        -o "$output_prefix" \
        -e "$ANTSPATH/data/T_template0.nii.gz" \
        -m "$ANTSPATH/data/T_template0_BrainCerebellumProbabilityMask.nii.gz" \
        -f "$ANTSPATH/data/T_template0_BrainCerebellumRegistrationMask.nii.gz"
    
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
    log "SNR for $basename: $snr"
    
    # For qualitative assessment, generate a check image
    CreateTiledMosaic -i "$file" -r "$reference_image" -o "${output_prefix}check.png" -a 0.3 -t -1x-1 -p mask -m "${output_prefix}BrainExtractionMask.nii.gz"
done

log "✅ Quality assessment complete."

# Step 5: ANTs-based intensity normalization for FLAIR
log "==== Step 5: ANTs-based Intensity Normalization ===="
mkdir -p "${RESULTS_DIR}/intensity_normalized"

# Find all FLAIR images after registration
flair_files=($(find "$RESULTS_DIR/registered" -name "*FLAIR*reg.nii.gz"))

if [ ${#flair_files[@]} -gt 0 ]; then
    log "Found ${#flair_files[@]} FLAIR images to normalize"
    
    for file in "${flair_files[@]}"; do
        basename=$(basename "$file" .nii.gz)
        output_file="${RESULTS_DIR}/intensity_normalized/${basename}_norm.nii.gz"
        
        log "Normalizing: $basename"
        
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
        
        log "Saved intensity-normalized image to: $output_file"
    done
    
    log "✅ Intensity normalization complete for FLAIR images."
else
    log "⚠️ No FLAIR images found for intensity normalization."
fi

# Step 6: Hyperintensity detection for FLAIR (using ANTs tools)
if [ ${#flair_files[@]} -gt 0 ]; then
    log "==== Step 6: Hyperintensity Detection on FLAIR ===="
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
        
        log "Detecting hyperintensities on: $basename"
        
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
            log "Using $t1_reg for tissue segmentation"
            
            # Run ANTs segmentation on T1
            Atropos -d 3 \
                -a "$input_file" \
                -x "${output_prefix}brain_mask.nii.gz" \
                -o [${output_prefix}atropos_segmentation.nii.gz,${output_prefix}atropos_prob%d.nii.gz] \
                -c [${ATROPOS_CONVERGENCE}] \
                -m ${ATROPOS_MRF} \
                -i ${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}] \
                -k Gaussian
            
                        
            # Extract WM (label 3) and GM (label 2)
            ThresholdImage 3 "${output_prefix}segmentation.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            ThresholdImage 3 "${output_prefix}segmentation.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2
            
            log "T1-based tissue segmentation complete."
        else
            # Fallback to intensity-based segmentation on FLAIR
            log "No T1 found. Using intensity-based segmentation on FLAIR."
            
            # Use Otsu thresholding to create rough tissue classes
            ThresholdImage 3 "$input_file" "${output_prefix}otsu.nii.gz" Otsu 3 "${output_prefix}brain_mask.nii.gz"
            
            # Extract approximate WM (highest intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}wm_mask.nii.gz" 3 3
            
            # Extract approximate GM (middle intensity class in Otsu)
            ThresholdImage 3 "${output_prefix}otsu.nii.gz" "${output_prefix}gm_mask.nii.gz" 2 2
        fi
        
        # Method 1: Simple threshold-based hyperintensity detection
        # First get WM statistics
        wm_mean=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 2 | awk '{print $2}')
        wm_sd=$(ImageStats "$input_file" "${output_prefix}wm_mask.nii.gz" 5 | awk '{print $2}')
        
        # Define threshold (mean + 2.5 SD is common for hyperintensities)
        threshold=$(echo "$wm_mean + 2.5 * $wm_sd" | bc -l)
        log "WM mean: $wm_mean, WM SD: $wm_sd, Threshold: $threshold"
        
        # Apply threshold to create hyperintensity mask
        ThresholdImage 3 "$input_file" "${output_prefix}hyperintensities_threshold.nii.gz" $threshold 99999 "${output_prefix}brain_mask.nii.gz"
        
        # Clean up small islands (less than 5 voxels)
        ImageMath 3 "${output_prefix}hyperintensities_clean.nii.gz" GetLargestComponents "${output_prefix}hyperintensities_threshold.nii.gz" 5
        
        log "✅ Threshold-based hyperintensity detection complete."
        
        # Method 2: Advanced hyperintensity detection using Atropos
        log "Performing advanced hyperintensity detection using Atropos..."
        
        # Use Atropos directly on FLAIR with prior knowledge of hyperintensities
        Atropos -d 3 \
            -a "$input_file" \
            -x "${output_prefix}brain_mask.nii.gz" \
            -o [${output_prefix}atropos_segmentation.nii.gz,${output_prefix}atropos_prob%d.nii.gz] \
            -c [5,0.0] \
            -m [0.1,1x1x1] \
            -i kmeans[4] \
            -k Gaussian
        
        # The highest intensity class should be hyperintensities
        ThresholdImage 3 "${output_prefix}atropos_segmentation.nii.gz" "${output_prefix}hyperintensities_atropos.nii.gz" 4 4
        
        # Also get probability map for the highest class
        cp "${output_prefix}atropos_prob4.nii.gz" "${output_prefix}hyperintensities_prob.nii.gz"
        
        log "✅ Advanced hyperintensity detection complete."
        
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
        
        log "Converted results to .mgz format for Freeview."
        
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
log "==== Creating Cropped Versions with Padding ===="
mkdir -p "${RESULTS_DIR}/cropped"

find "${RESULTS_DIR}/registered" -name "*reg.nii.gz" -print0 | while IFS= read -r -d '' file; do
    basename=$(basename "$file" .nii.gz)
    output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"
    
    log "Creating cropped version with padding for: $basename"
    
    # Use ExtractRegionFromImageByMask from ANTs
    # This provides better cropping with customizable padding
    c3d "$file" -as S "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" -push S -thresh 0.1 1 1 0 -trim 5mm -o "$output_file"
    
    log "Saved cropped file: $output_file"
done

log "✅ All processing steps complete!"

# Create a summary report
log "==== Creating Summary Report ===="

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

log "Summary report created at ${RESULTS_DIR}/hyperintensity_report.txt"

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
    echo "Running: \$cmd"
    eval \$cmd
else
    echo "No FLAIR files found. Cannot open freeview."
fi
EOL
chmod +x "${RESULTS_DIR}/view_all_results.sh"

log "Created comprehensive freeview script at ${RESULTS_DIR}/view_all_results.sh"
log "==== Processing Pipeline Complete! ===="

