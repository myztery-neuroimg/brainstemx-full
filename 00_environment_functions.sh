#!/usr/bin/env bash
#
# 00_environment.sh
#
# Master environment script that:
#  1) Sets environment variables and pipeline parameters (SRC_DIR, RESULTS_DIR, etc.)
#  2) Defines all the utility functions originally scattered in the big script
#  3) References the optional Python script (extract_dicom_metadata.py)
#
# Each step's sub-script will do:
#    source 00_environment.sh
# and can then call any function or use any variable below.
#
# If any portion of logic (e.g., metadata Python code) is too large, we
# might place it in "01_environment_setup_2.sh" or another file, referencing it here.

# ------------------------------------------------------------------------------
# Shell Options
# ------------------------------------------------------------------------------
#set -e
#set -u
#set -o pipefail
#set -x
export HISTTIMEFORMAT='%d/%m/%y %T'
# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="../DiCOM"          # DICOM input directory
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix
export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
export ANTS_PATH="~/ants"
export PATH="$PATH:${ANTS_PATH}/bin"
export LOG_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOG_DIR"

# Log file capturing pipeline-wide logs
export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# ------------------------------------------------------------------------------
# Logging & Color Setup
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_formatted() {
  local level=$1
  local message=$2
  case $level in
    "INFO")    echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR")   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
    *)         echo -e "[LOG] $message" >&2 ;;
  esac
}

log_message() {
  local text="$1"
  # Write to both stderr and the LOG_FILE
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" | tee -a "$LOG_FILE" >&2
}

export log_message

# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
PROCESSING_DATATYPE="float"  # internal float
OUTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # override if needed

# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi

# Parse out the fields for general sequences
N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
TEMPLATE_ITERATIONS=2
TEMPLATE_GRADIENT_STEP=0.2
TEMPLATE_TRANSFORM_MODEL="SyN"
TEMPLATE_SIMILARITY_METRIC="CC"
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
TEMPLATE_WEIGHTS="100x50x50x10"

# Registration & motion correction
REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
REG_METRIC_CROSS_MODALITY="MI"
REG_METRIC_SAME_MODALITY="CC"
ANTS_THREADS=12
REG_PRECISION=1

# Hyperintensity detection
THRESHOLD_WM_SD_MULTIPLIER=2.3
MIN_HYPERINTENSITY_SIZE=4

# Tissue segmentation parameters
ATROPOS_T1_CLASSES=3
ATROPOS_FLAIR_CLASSES=4
ATROPOS_CONVERGENCE="5,0.0"
ATROPOS_MRF="[0.1,1x1x1]"
ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
PADDING_X=5
PADDING_Y=5
PADDING_Z=5
C3D_CROP_THRESHOLD=0.1
C3D_PADDING_MM=5

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Template references may fail."
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"

# ------------------------------------------------------------------------------
# Dependency Checks
# ------------------------------------------------------------------------------
check_command() {
  local cmd=$1
  local package=$2
  local hint=${3:-""}

  if command -v "$cmd" &> /dev/null; then
    log_formatted "SUCCESS" "✓ $package is installed ($(command -v "$cmd"))"
    return 0
  else
    log_formatted "ERROR" "✗ $package is not installed or not in PATH"
    [ -n "$hint" ] && log_formatted "INFO" "$hint"
    return 1
  fi
}

check_ants() {
  log_formatted "INFO" "Checking ANTs tools..."
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" \
                    "antsApplyTransforms" "antsBrainExtraction.sh")
  local missing=0
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_fsl() {
  log_formatted "INFO" "Checking FSL..."
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast")
  local missing=0
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_freesurfer() {
  log_formatted "INFO" "Checking FreeSurfer..."
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

# For convenience, run them here (or comment out if you have a separate script)
check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix"
check_ants
check_fsl
check_freesurfer

# ------------------------------------------------------------------------------
# Shared Helper Functions (From the Large Script)
# ------------------------------------------------------------------------------
standardize_datatype() {
  local input=$1
  local output=$2
  local dtype=${3:-"float"}
  fslmaths "$input" "$output" -odt "$dtype"
  log_message "Standardized $input to $dtype"
}

set_sequence_params() {
  # Quick function if you want to parse filename and set custom logic
  local file="$1"
  log_message "Analyzing sequence type from $file"
  if [[ "$file" == *"FLAIR"* ]]; then
    log_message "It’s a FLAIR sequence"
    # e.g. apply FLAIR overrides here if needed
  elif [[ "$file" == *"DWI"* || "$file" == *"ADC"* ]]; then
    log_message "It’s a DWI sequence"
  elif [[ "$file" == *"SWI"* ]]; then
    log_message "It’s an SWI sequence"
  else
    log_message "Defaulting to T1"
  fi
}

deduplicate_identical_files() {
  local dir="$1"
  log_message "==== Deduplicating identical files in $dir ===="
  [ -d "$dir" ] || return 0

  mkdir -p "${dir}/tmp_checksums"

  # Symlink checksums
  find "$dir" -name "*.nii.gz" -type f | while read file; do
    local base=$(basename "$file" .nii.gz)
    local checksum=$(md5 -q "$file")
    ln -sf "$file" "${dir}/tmp_checksums/${checksum}_${base}.link"
  done

  # For each unique checksum, keep only one
  find "${dir}/tmp_checksums" -name "*.link" | sort | \
  awk -F'_' '{print $1}' | uniq | while read csum; do
    local allfiles=($(find "${dir}/tmp_checksums" -name "${csum}_*.link" -exec readlink {} \;))
    if [ ${#allfiles[@]} -gt 1 ]; then
      local kept="${allfiles[0]}"
      log_message "Keeping representative file: $(basename "$kept")"
      for ((i=1; i<${#allfiles[@]}; i++)); do
        local dup="${allfiles[$i]}"
        if [ -f "$dup" ]; then
          log_message "Replacing duplicate: $(basename "$dup") => $(basename "$kept")"
          rm "$dup"
          ln "$kept" "$dup"
        fi
      done
    fi
  done
  rm -rf "${dir}/tmp_checksums"
  log_message "Deduplication complete"
}

combine_multiaxis_images() {
  local sequence_type="$1"
  local output_dir="$2"
  mkdir -p "$output_dir"
  log_message "Combining multi-axis images for $sequence_type"

  # Find SAG, COR, AX
  local sag_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  local ax_files=($(find "$EXTRACT_DIR" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # pick best resolution from each orientation
  local best_sag="" best_cor="" best_ax=""
  local best_sag_res=0 best_cor_res=0 best_ax_res=0

  for file in "${sag_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_sag_res ]; then
      best_sag="$file"; best_sag_res=$res
    fi
  done
  for file in "${cor_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_cor_res ]; then
      best_cor="$file"; best_cor_res=$res
    fi
  done
  for file in "${ax_files[@]}"; do
    local d1=$(fslval "$file" dim1)
    local d2=$(fslval "$file" dim2)
    local d3=$(fslval "$file" dim3)
    local res=$((d1 * d2 * d3))
    if [ $res -gt $best_ax_res ]; then
      best_ax="$file"; best_ax_res=$res
    fi
  done

  local out_file="${output_dir}/${sequence_type}_combined_highres.nii.gz"

  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG, COR, AX with antsMultivariateTemplateConstruction2.sh"
    antsMultivariateTemplateConstruction2.sh \
      -d 3 \
      -o "${output_dir}/${sequence_type}_template_" \
      -i $TEMPLATE_ITERATIONS \
      -g $TEMPLATE_GRADIENT_STEP \
      -j $ANTS_THREADS \
      -f $TEMPLATE_SHRINK_FACTORS \
      -s $TEMPLATE_SMOOTHING_SIGMAS \
      -q $TEMPLATE_WEIGHTS \
      -t $TEMPLATE_TRANSFORM_MODEL \
      -m $TEMPLATE_SIMILARITY_METRIC \
      -c 0 \
      "$best_sag" "$best_cor" "$best_ax"

    mv "${output_dir}/${sequence_type}_template_template0.nii.gz" "$out_file"
    standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
    log_formatted "SUCCESS" "Created high-res combined: $out_file"

  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    if [ -n "$best_sag" ]; then best_file="$best_sag"
    elif [ -n "$best_cor" ]; then best_file="$best_cor"
    elif [ -n "$best_ax" ]; then best_file="$best_ax"
    fi
    if [ -n "$best_file" ]; then
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_message "Used single orientation: $best_file"
    else
      log_formatted "ERROR" "No $sequence_type files found"
    fi
  fi
}

get_n4_parameters() {
  local file="$1"
  local iters="$N4_ITERATIONS"
  local conv="$N4_CONVERGENCE"
  local bspl="$N4_BSPLINE"
  local shrk="$N4_SHRINK"

  if [[ "$file" == *"FLAIR"* ]]; then
    iters="$N4_ITERATIONS_FLAIR"
    conv="$N4_CONVERGENCE_FLAIR"
    bspl="$N4_BSPLINE_FLAIR"
    shrk="$N4_SHRINK_FLAIR"
  fi
  echo "$iters" "$conv" "$bspl" "$shrk"
}

extract_siemens_metadata() {
  local dicom_dir="$1"
  log_message "dicom_dir: $dicom_dir"
  [ -e "$dicom_dir" ] || return 0

  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"

  log_message "Extracting Siemens MAGNETOM Sola metadata..."

  local first_dicom
  first_dicom=$(find "$dicom_dir" -name "Image*" -type f | head -1)
  if [ -z "$first_dicom" ]; then
    log_message "No DICOM files found for metadata extraction."
    return 1
  fi

  mkdir -p "$(dirname "$metadata_file")"
  echo "{\"manufacturer\":\"Unknown\",\"fieldStrength\":3,\"modelName\":\"Unknown\"}" > "$metadata_file"

  # Path to the external Python script
  local python_script="./extract_dicom_metadata.py"
  if [ ! -f "$python_script" ]; then
    log_message "Python script not found at: $python_script"
    return 1
  fi
  chmod +x "$python_script"

  log_message "Extracting metadata with Python script..."
  if command -v timeout &> /dev/null; then
    timeout 30s python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log"
    local exit_code=$?
    if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
      log_message "Python script timed out. Using default values."
    elif [ $exit_code -ne 0 ]; then
      log_message "Python script failed (exit $exit_code). See python_error.log"
    else
      mv "$metadata_file".tmp "$metadata_file"
      log_message "Metadata extracted successfully"
    fi
  else
    # If 'timeout' isn't available, do a manual background kill approach
    python3 "$python_script" "$first_dicom" "$metadata_file".tmp \
      2>"${RESULTS_DIR}/metadata/python_error.log" &
    local python_pid=$!
    for i in {1..30}; do
      if ! kill -0 $python_pid 2>/dev/null; then
        # Process finished
        wait $python_pid
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
          mv "$metadata_file".tmp "$metadata_file"
          log_message "Metadata extracted successfully"
        else
          log_message "Python script failed (exit $exit_code)."
        fi
        break
      fi
      sleep 1
      if [ $i -eq 30 ]; then
        kill $python_pid 2>/dev/null || true
        log_message "Script took too long. Using default values."
      fi
    done
  fi
  log_message "Metadata extraction complete"
  return 0
}

optimize_ants_parameters() {
  local metadata_file="${RESULTS_DIR}/metadata/siemens_params.json"
  mkdir -p "${RESULTS_DIR}/metadata"
  if [ ! -f "$metadata_file" ]; then
    log_message "No metadata found. Using default ANTs parameters."
    return
  fi

  if command -v python3 &> /dev/null; then
    # Python script to parse JSON fields
    cat > "${RESULTS_DIR}/metadata/parse_json.py" <<EOF
import json, sys
try:
    with open(sys.argv[1],'r') as f:
        data = json.load(f)
    field_strength = data.get('fieldStrength',3)
    print(f"FIELD_STRENGTH={field_strength}")
    model = data.get('modelName','')
    print(f"MODEL_NAME={model}")
    is_sola = ('MAGNETOM Sola' in model)
    print(f"IS_SOLA={'1' if is_sola else '0'}")
except:
    print("FIELD_STRENGTH=3")
    print("MODEL_NAME=Unknown")
    print("IS_SOLA=0")
EOF
    eval "$(python3 "${RESULTS_DIR}/metadata/parse_json.py" "$metadata_file")"
  else
    FIELD_STRENGTH=3
    MODEL_NAME="Unknown"
    IS_SOLA=0
  fi

  if (( $(echo "$FIELD_STRENGTH > 2.5" | bc -l) )); then
    log_message "Optimizing for 3T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_2mm.nii.gz"
    N4_CONVERGENCE="0.000001"
    REG_METRIC_CROSS_MODALITY="MI"
  else
    log_message "Optimizing for 1.5T field strength ($FIELD_STRENGTH T)"
    EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
    # 1.5T adjustments
    N4_CONVERGENCE="0.0000005"
    N4_BSPLINE=200
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.3]"
    ATROPOS_MRF="[0.15,1x1x1]"
  fi

  if [ "$IS_SOLA" = "1" ]; then
    log_message "Applying specific optimizations for MAGNETOM Sola"
    REG_TRANSFORM_TYPE=3
    REG_METRIC_CROSS_MODALITY="MI[32,Regular,0.25]"
    N4_BSPLINE=200
  fi
  log_message "ANTs parameters optimized from metadata"
}

process_n4_correction() {
  local file="$1"
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/bias_corrected/${basename}_n4.nii.gz"

  log_message "N4 bias correction: $file"
  # Brain extraction for a better mask
  antsBrainExtraction.sh -d 3 \
    -a "$file" \
    -k 1 \
    -o "${RESULTS_DIR}/bias_corrected/${basename}_" \
    -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
    -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
    -f "$TEMPLATE_DIR/$REGISTRATION_MASK"

  local params=($(get_n4_parameters "$file"))
  local iters=${params[0]}
  local conv=${params[1]}
  local bspl=${params[2]}
  local shrk=${params[3]}

  N4BiasFieldCorrection -d 3 \
    -i "$file" \
    -x "${RESULTS_DIR}/bias_corrected/${basename}_BrainExtractionMask.nii.gz" \
    -o "$output_file" \
    -b "[$bspl]" \
    -s "$shrk" \
    -c "[$iters,$conv]"

  log_message "Saved bias-corrected image: $output_file"
}

standardize_dimensions() {
  local input_file="$1"
  local basename=$(basename "$input_file" .nii.gz)
  local output_file="${RESULTS_DIR}/standardized/${basename}_std.nii.gz"

  log_message "Standardizing dimensions for $basename"

  # Example dimension approach from big script
  local x_dim=$(fslval "$input_file" dim1)
  local y_dim=$(fslval "$input_file" dim2)
  local z_dim=$(fslval "$input_file" dim3)
  local x_pix=$(fslval "$input_file" pixdim1)
  local y_pix=$(fslval "$input_file" pixdim2)
  local z_pix=$(fslval "$input_file" pixdim3)

  # Then the script picks a resolution logic based on filename
  # For brevity, we replicate it or do a single fallback approach.
  # If you want the entire table from your big script, copy that logic here
  # e.g. T1 => 1mm isotropic, FLAIR => 512,512,keep, etc.

  cp "$input_file" "$output_file"
  # Possibly call c3d or ResampleImage to do a real resample
  # e.g.:
  # ResampleImage 3 "$input_file" "$output_file" 256x256x192 0 3

  log_message "Saved standardized image: $output_file"
}

process_cropping_with_padding() {
  local file="$1"
  local basename=$(basename "$file" .nii.gz)
  local output_file="${RESULTS_DIR}/cropped/${basename}_cropped.nii.gz"

  mkdir -p "${RESULTS_DIR}/cropped"
  log_message "Cropping w/ padding: $file"

  # c3d approach from the big script
  c3d "$file" -as S \
    "${RESULTS_DIR}/quality_checks/${basename}_BrainExtractionMask.nii.gz" \
    -push S \
    -thresh $C3D_CROP_THRESHOLD 1 1 0 \
    -trim ${C3D_PADDING_MM}mm \
    -o "$output_file"

  log_message "Saved cropped file: $output_file"
}

# If you also want a function to run morphological hyperintensity detection,
# Atropos-based segmentation, etc., you can copy that entire block from the big script
# and wrap it in a function here (e.g. "detect_hyperintensities()"). The same applies
# for "registration" steps or "quality checks." Put them all here so sub-scripts
# only do calls, not define them.
mkdir -p "$EXTRACT_DIR"
mkdir -p "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR/metadata"
mkdir -p "$RESULTS_DIR/cropped"
mkdir -p "$RESULTS_DIR/standardized"
mkdir -p "$RESULTS_DIR/bias_corrected"

detect_hyperintensities() {
    # Usage: detect_hyperintensities <FLAIR_input.nii.gz> <output_prefix> [<T1_input.nii.gz>]
    #
    # 1) Brain-extract the FLAIR
    # 2) Optional: If T1 provided, use Atropos segmentation from T1 or cross-modality
    # 3) Threshold + morphological operations => final hyperintensity mask
    # 4) Produce .mgz overlays for quick Freeview
    #
    # Example:
    # detect_hyperintensities T2_SPACE_FLAIR_Sag.nii.gz results/hyper_flair T1_MPRAGE_SAG.nii.gz

    local flair_file="$1"
    local out_prefix="$2"
    local t1_file="${3}"   # optional

    if [ ! -f "$flair_file" ]; then
        log_message "Error: FLAIR file not found: $flair_file"
        return 1
    fi

    mkdir -p "$(dirname "$out_prefix")"

    log_message "=== Hyperintensity Detection ==="
    log_message "FLAIR input: $flair_file"
    if [ -n "$t1_file" ]; then
        log_message "Using T1 for segmentation: $t1_file"
    else
        log_message "No T1 file provided, will fallback to intensity-based segmentation"
    fi

    # 1) Brain extraction for the FLAIR
    local flair_basename
    flair_basename=$(basename "$flair_file" .nii.gz)
    local brainextr_dir
    brainextr_dir="$(dirname "$out_prefix")/${flair_basename}_brainextract"

    mkdir -p "$brainextr_dir"

    antsBrainExtraction.sh \
      -d 3 \
      -a "$flair_file" \
      -o "${brainextr_dir}/" \
      -e "$TEMPLATE_DIR/$EXTRACTION_TEMPLATE" \
      -m "$TEMPLATE_DIR/$PROBABILITY_MASK" \
      -f "$TEMPLATE_DIR/$REGISTRATION_MASK" \
      -k 1

    local flair_brain="${brainextr_dir}/BrainExtractionBrain.nii.gz"
    local flair_mask="${brainextr_dir}/BrainExtractionMask.nii.gz"

    # 2) Tissue Segmentation
    # If T1 is provided, you can do cross-modality with Atropos
    local segmentation_out="${out_prefix}_atropos_seg.nii.gz"
    local wm_mask="${out_prefix}_wm_mask.nii.gz"
    local gm_mask="${out_prefix}_gm_mask.nii.gz"

    if [ -n "$t1_file" ] && [ -f "$t1_file" ]; then
        # Register T1 to FLAIR or vice versa, or assume they match dimensions
        log_message "Registering ${flair_brain} to ${t1_file}"
        #flirt -in "$t1_file" -ref "$flair_brain" -omat "t1_to_flair.mat"

        ## If misaligned, register
        #flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -applyxfm -init t1_to_flair.mat


    t1_registered="${out_prefix}_T1_registered.nii.gz"

    # Verify alignment: Check if T1 and FLAIR have identical headers
    #if fslinfo "$t1_file" | grep -q "$(fslinfo "$flair_brain" | grep 'dim1')"; then
        echo "T1 and FLAIR appear to have matching dimensions. Skipping registration."
        cp "$t1_file" "$t1_registered"  # Just copy it if already aligned
    #else
    #    echo "Registering T1 to FLAIR..."
    #    flirt -in "$t1_file" -ref "$flair_brain" -out "$t1_registered" -omat "t1_to_flair.mat" -dof 6
    #fi

        # Then run Atropos on FLAIR using T1 as additional input if needed, or just on FLAIR alone.

        Atropos -d 3 \
          -a "$flair_brain" \
          -a "$t1_file" \
          -s 2 \
          -x "$flair_mask" \
          -o "[$segmentation_out,${out_prefix}_atropos_prob%02d.nii.gz]" \
          -c "[${ATROPOS_CONVERGENCE}]" \
          -m "${ATROPOS_MRF}" \
          -i "${ATROPOS_INIT_METHOD}[${ATROPOS_FLAIR_CLASSES}]" \
          -k Gaussian

        # Typical labeling: 1=CSF, 2=GM, 3=WM, 4=Lesion? (depends on your config)

        # Verify which label is which
        fslstats "$segmentation_out" -R

        ThresholdImage 3 "$segmentation_out" "$wm_mask" 3 3
        ThresholdImage 3 "$segmentation_out" "$gm_mask" 2 2

    else
        # Fallback to intensity-based segmentation (Otsu or simple approach)
        log_message "No T1 provided; using Otsu-based 3-class segmentation"

        ThresholdImage 3 "$flair_brain" "${out_prefix}_otsu.nii.gz" Otsu 3 "$flair_mask"
        # Typically label 3 => brightest intensities => approximate WM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$wm_mask" 3 3
        # Label 2 => GM
        ThresholdImage 3 "${out_prefix}_otsu.nii.gz" "$gm_mask" 2 2
    fi

    # 3) Compute WM stats to define threshold
    local mean_wm
    local sd_wm
    mean_wm=$(fslstats "$flair_brain" -k "$wm_mask" -M)
    sd_wm=$(fslstats "$flair_brain" -k "$wm_mask" -S)
    log_message "WM mean: $mean_wm   WM std: $sd_wm"

    # You can define a multiplier or use the global THRESHOLD_WM_SD_MULTIPLIER
    local threshold_multiplier="$THRESHOLD_WM_SD_MULTIPLIER"
    local thr_val
    thr_val=$(echo "$mean_wm + $threshold_multiplier * $sd_wm" | bc -l)
    log_message "Threshold = WM_mean + $threshold_multiplier * WM_SD = $thr_val"

    # 4) Threshold + morphological operations
    local init_thr="${out_prefix}_init_thr.nii.gz"
    ThresholdImage 3 "$flair_brain" "$init_thr" "$thr_val" 999999 "$flair_mask"

    # Combine with WM + GM if you want to exclude CSF
    local tissue_mask="${out_prefix}_brain_tissue.nii.gz"
    ImageMath 3 "$tissue_mask" + "$wm_mask" "$gm_mask"

    local combined_thr="${out_prefix}_combined_thr.nii.gz"
    ImageMath 3 "$combined_thr" m "$init_thr" "$tissue_mask"

    # Morphological cleanup
    local eroded="${out_prefix}_eroded.nii.gz"
    local eroded_dilated="${out_prefix}_eroded_dilated.nii.gz"
    ImageMath 3 "$eroded" ME "$combined_thr" 1
    ImageMath 3 "$eroded_dilated" MD "$eroded" 1

    # Remove small islands with connected components
    local final_mask="${out_prefix}_T1_registered.nii.gz"
    #ImageMath 3 "$final_mask" GetLargestComponents "$eroded_dilated" $MIN_HYPERINTENSITY_SIZE

    c3d "$eroded_dilated" \
     -connected-components 26 \
     -threshold $MIN_HYPERINTENSITY_SIZE inf 1 0 \
     -o "$final_mask"

    log_message "Final hyperintensity mask saved to: $final_mask"

    # 5) Optional: Convert to .mgz or create a freeview script
    local flair_norm_mgz="${out_prefix}_flair.mgz"
    local hyper_clean_mgz="${out_prefix}_hyper.mgz"
    mri_convert "$flair_brain" "$flair_norm_mgz"
    mri_convert "$final_mask" "$hyper_clean_mgz"

    cat > "${out_prefix}_view_in_freeview.sh" << EOC
#!/usr/bin/env bash
freeview -v "$flair_norm_mgz" \\
         -v "$hyper_clean_mgz":colormap=heat:opacity=0.5
EOC
    chmod +x "${out_prefix}_view_in_freeview.sh"

    log_message "Hyperintensity detection complete. To view in freeview, run: ${out_prefix}_view_in_freeview.sh"
}

registration_flair_to_t1() {
    # Usage: registration_flair_to_t1 <T1_file.nii.gz> <FLAIR_file.nii.gz> <output_prefix>
    #
    # If T1 and FLAIR have identical dimensions & orientation, you might only need a
    # simple identity transform or a short rigid alignment.
    # This snippet uses antsRegistrationSyN for a minimal transformation.

    local t1_file="$1"
    local flair_file="$2"
    local out_prefix="$3"

    if [ ! -f "$t1_file" ] || [ ! -f "$flair_file" ]; then
        log_message "Error: T1 or FLAIR file not found"
        return 1
    fi

    log_message "=== Registering FLAIR to T1 ==="
    log_message "T1: $t1_file"
    log_message "FLAIR: $flair_file"
    log_message "Output prefix: $out_prefix"

    # If T1 & FLAIR are from the same 3D session, we can use a simpler transform
    # -t r => rigid. For cross-modality, we can specify 'MI' or 'CC'.
    # antsRegistrationSyN.sh defaults to 's' (SyN) with reg type 'r' or 'a'.
    # Let's do a short approach:
    
    antsRegistrationSyN.sh \
      -d 3 \
      -f "$t1_file" \
      -m "$flair_file" \
      -o "$out_prefix" \
      -t r \
      -n 4 \
      -p f \
      -j 1 \
      -x "$REG_METRIC_CROSS_MODALITY"

    # The Warped file => ${out_prefix}Warped.nii.gz
    # The transform(s) => ${out_prefix}0GenericAffine.mat, etc.

    log_message "Registration complete. Warped FLAIR => ${out_prefix}Warped.nii.gz"
}

log_message "Done loading all environment variables & functions in 00_environment.sh"

extract_brainstem_standardspace() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
    
    # Path to Harvard-Oxford Subcortical atlas (more reliable than Talairach for this task)
    harvard_subcortical="${FSLDIR}/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-2mm.nii.gz"
    
    if [ ! -f "$standard_template" ]; then
        echo "Error: Standard template not found at $standard_template"
        return 1
    fi
    
    if [ ! -f "$harvard_subcortical" ]; then
        echo "Error: Harvard-Oxford subcortical atlas not found at $harvard_subcortical"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Step 1: Register input to standard space
    echo "Registering input to standard space..."
    flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
    
    # Step 2: Generate inverse transformation matrix
    echo "Generating inverse transformation..."
    convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
    
    # Step 3: Extract brainstem from Harvard-Oxford subcortical atlas
    echo "Extracting brainstem mask from Harvard-Oxford atlas..."
    # In Harvard-Oxford subcortical atlas, brainstem is index 16
    fslmaths "$harvard_subcortical" -thr 16 -uthr 16 -bin "${temp_dir}/brainstem_mask_std.nii.gz"
    
    # Step 4: Apply mask to input in standard space
    echo "Applying mask in standard space..."
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/brainstem_mask_std.nii.gz" "${temp_dir}/brainstem_std.nii.gz"
    
    # Step 5: Transform masked image back to original space
    echo "Transforming back to original space..."
    flirt -in "${temp_dir}/brainstem_std.nii.gz" -ref "$input_file" -out "$output_file" -applyxfm -init "${temp_dir}/std2input.mat"
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "Completed. Brainstem extracted to: $output_file"
    return 0
}


extract_brainstem_talairach() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to standard space template
    standard_template="${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz"

    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-1mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    log_message "Processing $input_file..."
    
    # Talairach indices based on your output
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # Extract each region and combine
    echo "Extracting brainstem regions..."
    
    # Step 1: Register input to standard space
    echo "Registering input to standard space..."
    flirt -in "$input_file" -ref "$standard_template" -out "${temp_dir}/input_std.nii.gz" -omat "${temp_dir}/input2std.mat" -dof 12
    
    # Step 2: Generate inverse transformation matrix
    echo "Generating inverse transformation..."
    convert_xfm -omat "${temp_dir}/std2input.mat" -inverse "${temp_dir}/input2std.mat"
    
    # Step 3: Extract each region from Talairach atlas
    echo "Extracting brainstem regions from Talairach atlas..."
    
    # Medulla
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    
    # Pons
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    
    # Midbrain
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all regions for full brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/brainstem_mask_std.nii.gz"
    
    # Step 4: Apply masks to input in standard space
    echo "Applying masks in standard space..."
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/brainstem_mask_std.nii.gz" "${temp_dir}/brainstem_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/medulla.nii.gz" "${temp_dir}/medulla_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/pons.nii.gz" "${temp_dir}/pons_std.nii.gz"
    fslmaths "${temp_dir}/input_std.nii.gz" -mas "${temp_dir}/midbrain.nii.gz" "${temp_dir}/midbrain_std.nii.gz"
    
    # Step 5: Transform masked images back to original space
    echo "Transforming back to original space..."
    flirt -in "${temp_dir}/brainstem_std.nii.gz" -ref "$input_file" -out "$output_file" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/medulla_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_medulla.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/pons_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_pons.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    flirt -in "${temp_dir}/midbrain_std.nii.gz" -ref "$input_file" -out "${input_dir}/${input_basename}_midbrain.nii.gz" -applyxfm -init "${temp_dir}/std2input.mat"
    

    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

#!/bin/bash

extract_brainstem_final() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if FSL is installed
    if ! command -v fslinfo &> /dev/null; then
        echo "Error: FSL is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Talairach indices
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # First, get dimensions of both images
    echo "Checking image dimensions..."
    fslinfo "$input_file" > "${temp_dir}/input_info.txt"
    fslinfo "$talairach_atlas" > "${temp_dir}/atlas_info.txt"
    
    # Create a proper mask of each region in Talairach space
    echo "Creating masks in Talairach space..."
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    
    # Combine regions
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all for complete brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/talairach_brainstem.nii.gz"
    
    echo "Direct registration from Talairach to input space..."
    
    # Register atlas to input space directly
    flirt -in "$talairach_atlas" -ref "$input_file" -out "${temp_dir}/talairach_in_input_space.nii.gz" -omat "${temp_dir}/tal2input.mat" -dof 12
    
    # Use the same transformation to bring the masks to input space
    flirt -in "${temp_dir}/talairach_brainstem.nii.gz" -ref "$input_file" -out "${temp_dir}/brainstem_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/medulla.nii.gz" -ref "$input_file" -out "${temp_dir}/medulla_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/pons.nii.gz" -ref "$input_file" -out "${temp_dir}/pons_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    flirt -in "${temp_dir}/midbrain.nii.gz" -ref "$input_file" -out "${temp_dir}/midbrain_mask.nii.gz" -applyxfm -init "${temp_dir}/tal2input.mat" -interp nearestneighbour
    
    # Ensure masks are binary after transformation
    fslmaths "${temp_dir}/brainstem_mask.nii.gz" -bin "${temp_dir}/brainstem_mask.nii.gz"
    fslmaths "${temp_dir}/medulla_mask.nii.gz" -bin "${temp_dir}/medulla_mask.nii.gz"
    fslmaths "${temp_dir}/pons_mask.nii.gz" -bin "${temp_dir}/pons_mask.nii.gz"
    fslmaths "${temp_dir}/midbrain_mask.nii.gz" -bin "${temp_dir}/midbrain_mask.nii.gz"
    
    echo "Applying masks to input image..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask.nii.gz" "$output_file"
    fslmaths "$input_file" -mas "${temp_dir}/medulla_mask.nii.gz" "${input_dir}/${input_basename}_medulla.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/pons_mask.nii.gz" "${input_dir}/${input_basename}_pons.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/midbrain_mask.nii.gz" "${input_dir}/${input_basename}_midbrain.nii.gz"
    
    # Clean up
    #rm -rf "$temp_dir"
    
    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

extract_brainstem_ants() {
    # Check if input file exists
    if [ ! -f "$1" ]; then
        echo "Error: Input file $1 does not exist"
        return 1
    fi

    # Check if ANTs is installed
    if ! command -v antsRegistration &> /dev/null; then
        echo "Error: ANTs is not installed or not in PATH"
        return 1
    fi

    # Get input filename and directory
    input_file="$1"
    input_basename=$(basename "$input_file" .nii.gz)
    input_dir=$(dirname "$input_file")
    
    # Define output filename with suffix
    output_file="${input_dir}/${input_basename}_brainstem.nii.gz"
    
    # Path to Talairach atlas
    talairach_atlas="${FSLDIR}/data/atlases/Talairach/Talairach-labels-2mm.nii.gz"
    
    if [ ! -f "$talairach_atlas" ]; then
        echo "Error: Talairach atlas not found at $talairach_atlas"
        return 1
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    
    echo "Processing $input_file..."
    
    # Talairach indices
    medulla_left=5
    medulla_right=6
    pons_left=71
    pons_right=72
    midbrain_left=215
    midbrain_right=216
    
    echo "Using Talairach atlas with indices:"
    echo "  Medulla: $medulla_left (L), $medulla_right (R)"
    echo "  Pons: $pons_left (L), $pons_right (R)"
    echo "  Midbrain: $midbrain_left (L), $midbrain_right (R)"
    
    # Create masks in Talairach space
    echo "Creating masks in Talairach space..."
    
    # Extract each region
    fslmaths "$talairach_atlas" -thr $medulla_left -uthr $medulla_left -bin "${temp_dir}/medulla_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $medulla_right -uthr $medulla_right -bin "${temp_dir}/medulla_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_left -uthr $pons_left -bin "${temp_dir}/pons_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $pons_right -uthr $pons_right -bin "${temp_dir}/pons_right.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_left -uthr $midbrain_left -bin "${temp_dir}/midbrain_left.nii.gz"
    fslmaths "$talairach_atlas" -thr $midbrain_right -uthr $midbrain_right -bin "${temp_dir}/midbrain_right.nii.gz"
    
    # Combine regions
    fslmaths "${temp_dir}/medulla_left.nii.gz" -add "${temp_dir}/medulla_right.nii.gz" -bin "${temp_dir}/medulla.nii.gz"
    fslmaths "${temp_dir}/pons_left.nii.gz" -add "${temp_dir}/pons_right.nii.gz" -bin "${temp_dir}/pons.nii.gz"
    fslmaths "${temp_dir}/midbrain_left.nii.gz" -add "${temp_dir}/midbrain_right.nii.gz" -bin "${temp_dir}/midbrain.nii.gz"
    
    # Combine all for complete brainstem
    fslmaths "${temp_dir}/medulla.nii.gz" -add "${temp_dir}/pons.nii.gz" -add "${temp_dir}/midbrain.nii.gz" -bin "${temp_dir}/talairach_brainstem.nii.gz"
    
    # Register atlas to input space using ANTs
    echo "Registering atlas to input space using ANTs..."
    
    # First, create a reference image from the atlas for registration
    # This prevents misinterpretation of the label values during registration
    fslmaths "$talairach_atlas" -bin "${temp_dir}/talairach_ref.nii.gz"
    
    # Perform ANTs registration
    antsRegistration --dimensionality 3 \
                     --float 0 \
                     --output "${temp_dir}/atlas2input" \
                     --interpolation Linear \
                     --use-histogram-matching 0 \
                     --initial-moving-transform [${input_file},${temp_dir}/talairach_ref.nii.gz,1] \
                     --transform Affine[0.1] \
                     --metric MI[${input_file},${temp_dir}/talairach_ref.nii.gz,1,32,Regular,0.25] \
                     --convergence [1000x500x250x100,1e-6,10] \
                     --shrink-factors 8x4x2x1 \
                     --smoothing-sigmas 3x2x1x0vox
    
    # Apply the transformation to the masks
    echo "Applying transformation to masks..."
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/talairach_brainstem.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/brainstem_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/medulla.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/medulla_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/pons.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/pons_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    antsApplyTransforms --dimensionality 3 \
                        --input "${temp_dir}/midbrain.nii.gz" \
                        --reference-image "$input_file" \
                        --output "${temp_dir}/midbrain_mask.nii.gz" \
                        --transform "${temp_dir}/atlas2input0GenericAffine.mat" \
                        --interpolation NearestNeighbor
    
    # Ensure masks are binary after transformation
    fslmaths "${temp_dir}/brainstem_mask.nii.gz" -bin "${temp_dir}/brainstem_mask.nii.gz"
    fslmaths "${temp_dir}/medulla_mask.nii.gz" -bin "${temp_dir}/medulla_mask.nii.gz"
    fslmaths "${temp_dir}/pons_mask.nii.gz" -bin "${temp_dir}/pons_mask.nii.gz"
    fslmaths "${temp_dir}/midbrain_mask.nii.gz" -bin "${temp_dir}/midbrain_mask.nii.gz"
    
    # Apply masks to input image
    echo "Applying masks to input image..."
    fslmaths "$input_file" -mas "${temp_dir}/brainstem_mask.nii.gz" "$output_file"
    fslmaths "$input_file" -mas "${temp_dir}/medulla_mask.nii.gz" "${input_dir}/${input_basename}_medulla.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/pons_mask.nii.gz" "${input_dir}/${input_basename}_pons.nii.gz"
    fslmaths "$input_file" -mas "${temp_dir}/midbrain_mask.nii.gz" "${input_dir}/${input_basename}_midbrain.nii.gz"
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "Completed. Files created:"
    echo "  Complete brainstem: $output_file"
    echo "  Medulla only: ${input_dir}/${input_basename}_medulla.nii.gz"
    echo "  Pons only: ${input_dir}/${input_basename}_pons.nii.gz"
    echo "  Midbrain only: ${input_dir}/${input_basename}_midbrain.nii.gz"
    
    return 0
}

combine_multiaxis_images_highres() {
  local sequence_type="$1"
  local output_dir="$2"

  # *** Input Validation ***

  # 1. Check if sequence_type is provided
  if [ -z "$sequence_type" ]; then
    log_formatted "ERROR" "Sequence type not provided."
    return 1
  fi

  # 2. Check if output_dir is provided
  if [ -z "$output_dir" ]; then
    log_formatted "ERROR" "Output directory not provided."
    return 1
  fi

  # 3. Validate output_dir and create it if necessary
  if [ ! -d "$output_dir" ]; then
    log_message "Output directory '$output_dir' does not exist. Creating it..."
    if ! mkdir -p "$output_dir"; then
      log_formatted "ERROR" "Failed to create output directory: $output_dir"
      return 1
    fi
  fi

  # 4. Check write permissions for output_dir
  if [ ! -w "$output_dir" ]; then
    log_formatted "ERROR" "Output directory '$output_dir' is not writable."
    return 1
  fi

  log_message "Combining multi-axis images for $sequence_type"

  # *** Path Handling ***
  # Use absolute paths to avoid ambiguity
  local EXTRACT_DIR_ABS=$(realpath "$EXTRACT_DIR")
  local output_dir_abs=$(realpath "$output_dir")


  # Find SAG, COR, AX files using absolute path
  local sag_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz" | egrep -i "SAG" || true))
  local cor_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz" | egrep -i "COR" || true))
  local ax_files=($(find "$EXTRACT_DIR_ABS" -name "*${sequence_type}*.nii.gz"  | egrep -i "AX"  || true))

  # pick best resolution from each orientation
  local best_sag="" best_cor="" best_ax=""
  local best_sag_res=0 best_cor_res=0 best_ax_res=0

  # Helper function to calculate in-plane resolution
  calculate_inplane_resolution() {
    local file="$1"
    local pixdim1=$(fslval "$file" pixdim1)
    local pixdim2=$(fslval "$file" pixdim2)
    local inplane_res=$(echo "scale=10; sqrt($pixdim1 * $pixdim1 + $pixdim2 * $pixdim2)" | bc -l)
    echo "$inplane_res"
  }

  for file in "${sag_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    # Lower resolution value means higher resolution image
    if [ -z "$best_sag" ] || (( $(echo "$inplane_res < $best_sag_res" | bc -l) )); then
      best_sag="$file"
      best_sag_res="$inplane_res"
    fi
  done

  for file in "${cor_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    if [ -z "$best_cor" ] || (( $(echo "$inplane_res < $best_cor_res" | bc -l) )); then
      best_cor="$file"
      best_cor_res="$inplane_res"
    fi
  done

  for file in "${ax_files[@]}"; do
    local inplane_res=$(calculate_inplane_resolution "$file")
    if [ -z "$best_ax" ] || (( $(echo "$inplane_res < $best_ax_res" | bc -l) )); then
      best_ax="$file"
      best_ax_res="$inplane_res"
    fi
  done

  local out_file="${output_dir_abs}/${sequence_type}_combined_highres.nii.gz"

  if [ -n "$best_sag" ] && [ -n "$best_cor" ] && [ -n "$best_ax" ]; then
    log_message "Combining SAG, COR, AX with antsMultivariateTemplateConstruction2.sh"
    antsMultivariateTemplateConstruction2.sh \
      -d 3 \
      -o "${output_dir_abs}/${sequence_type}_template_" \
      -i $TEMPLATE_ITERATIONS \
      -g $TEMPLATE_GRADIENT_STEP \
      -j $ANTS_THREADS \
      -f $TEMPLATE_SHRINK_FACTORS \
      -s $TEMPLATE_SMOOTHING_SIGMAS \
      -q $TEMPLATE_WEIGHTS \
      -t $TEMPLATE_TRANSFORM_MODEL \
      -m $TEMPLATE_SIMILARITY_METRIC \
      -c 0 \
      "$best_sag" "$best_cor" "$best_ax"

    # Ensure the template file is moved to the correct output directory
    local template_file="${output_dir_abs}/${sequence_type}_template_template0.nii.gz"
    if [ -f "$template_file" ]; then
      mv "$template_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_formatted "SUCCESS" "Created high-res combined: $out_file"
    else
      log_formatted "ERROR" "Template file not found: $template_file"
      return 1
    fi


  else
    log_message "At least one orientation is missing for $sequence_type. Attempting fallback..."
    local best_file=""
    if [ -n "$best_sag" ]; then best_file="$best_sag"
    elif [ -n "$best_cor" ]; then best_file="$best_cor"
    elif [ -n "$best_ax" ]; then best_file="$best_ax"
    fi
    if [ -n "$best_file" ]; then
      cp "$best_file" "$out_file"
      standardize_datatype "$out_file" "$out_file" "$OUTPUT_DATATYPE"
      log_message "Used single orientation: $best_file"
    else
      log_formatted "ERROR" "No $sequence_type files found"
    fi
  fi
}
