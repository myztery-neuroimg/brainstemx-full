#!/usr/local/bin/bash
set -e
set -u
set -o pipefail

# Process DiCOM MRI images from Siemens MRI machines into NiFTi files appropriate for use in FSL/freeview
# My intention is to try to use the `ants` library as well where it can optimise conversions etc.. this is a second attempt only

SRC_DIR="../DiCOM"
EXTRACT_DIR="../extracted"

# Check for required dependencies
if ! command -v fslstats &> /dev/null || ! command -v fslroi &> /dev/null; then
    echo "Error: FSL is not installed or not in your PATH."
    exit 1
fi

NUM_SRC_DICOM_FILES=`find ${SRC_DIR} -name Image"*"  | wc -l`

echo "There are ${NUM_SRC_DICOM_FILES} in ${SRC_DIR}. You have 5 seconds to cancel the script if that's wrong. Going to extract to ${EXTRACT_DIR}"
sleep 5 

# Using -no-exit-on-error -auto-runseq here, it means you should probably check the output.txt after the script runs & the console output
echo "Using dcmunpack to convert DICOM files from ${SRC_DIR} to ${EXTRACT_DIR} in NiFTi .nii.gz format"
echo "Using -no-exit-on-error -auto-runseq here, it means you should probably check the output.txt after the script runs & the console output"
dcmunpack -src "${SRC_DIR}" -targ "${EXTRACT_DIR}" -fsfast -no-exit-on-error -auto-runseq nii.gz

echo "Command completed with status $? -5 seconds to stop now if something went wrong.."
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
    base=$(basename "$file" .nii.gz)

    # Get smallest bounding box of nonzero voxels
    bbox=($(fslstats "$file" -w))

    xmin=${bbox[0]}
    xsize=${bbox[1]}
    ymin=${bbox[2]}
    ysize=${bbox[3]}
    zmin=${bbox[4]}
    zsize=${bbox[5]}

    echo "Cropping region: X=($xmin, $xsize) Y=($ymin, $ysize) Z=($zmin, $zsize)"

    # Output filename
    output_file="${EXTRACT_DIR}/${base}${TRIMMED_OUTPUT_SUFFIX}.nii.gz"

    # Apply the cropping
    fslroi "$file" "$output_file" $xmin $xsize $ymin $ysize $zmin $zsize

    echo "Saved trimmed file: $output_file"
done

echo "✅ All files processed to trim missing slices."


