#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATASET_DIR="${DATASET_DIR:-${ROOT_DIR}/mri-brain-examples-ds004199-1.0.6}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${ROOT_DIR}/validation_runs/ds004199}"
START_STAGE="${START_STAGE:-preprocess}"
QUALITY="${QUALITY:-LOW}"

if [ ! -d "$DATASET_DIR" ]; then
  echo "Dataset not found: $DATASET_DIR" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- sub-00006 sub-00001 sub-00005 sub-00014 sub-00048
fi

mkdir -p "$OUTPUT_ROOT"

run_subject() {
  local subject="$1"
  local anat_dir="${DATASET_DIR}/${subject}/anat"
  local subject_dir="${OUTPUT_ROOT}/${subject}"
  local extract_dir="${subject_dir}/extracted"
  local results_dir="${subject_dir}/results"
  local config_file="${subject_dir}/ds004199_config.sh"

  if [ ! -d "$anat_dir" ]; then
    echo "Missing anat directory for ${subject}: $anat_dir" >&2
    return 1
  fi

  local t1_file
  local flair_file
  t1_file="$(find "$anat_dir" -maxdepth 1 -name "*_T1w.nii.gz" | head -1)"
  flair_file="$(find "$anat_dir" -maxdepth 1 -name "*_FLAIR.nii.gz" ! -name "*_roi.nii.gz" | head -1)"

  if [ -z "$t1_file" ] || [ -z "$flair_file" ]; then
    echo "Missing T1/FLAIR for ${subject}" >&2
    return 1
  fi

  mkdir -p "$extract_dir" "$results_dir"
  ln -sf "$t1_file" "${extract_dir}/$(basename "$t1_file")"
  ln -sf "$flair_file" "${extract_dir}/$(basename "$flair_file")"

  cat > "$config_file" <<EOF
source "${ROOT_DIR}/config/default_config.sh"
export EXTRACT_DIR="${extract_dir}"
export RESULTS_DIR="${results_dir}"
export SRC_DIR="${anat_dir}"
export QUALITY_PRESET="${QUALITY}"
export PIPELINE_REFERENCE_MODALITY="\${PIPELINE_REFERENCE_MODALITY:-T1}"
export FLAIR_PRIORITY_PATTERN="*FLAIR.nii.gz"
export T1_PRIORITY_PATTERN="*T1w.nii.gz"
EOF

  echo "=== ${subject} ==="
  echo "T1:    $(basename "$t1_file")"
  echo "FLAIR: $(basename "$flair_file")"
  echo "Out:   $results_dir"

  (
    cd "$ROOT_DIR"
    bash src/pipeline.sh \
      -c "$config_file" \
      -i "$anat_dir" \
      -o "$results_dir" \
      -s "$subject" \
      -q "$QUALITY" \
      -t "$START_STAGE"
  )
}

failed=0
for subject in "$@"; do
  if ! run_subject "$subject"; then
    echo "FAILED: $subject" >&2
    failed=$((failed + 1))
  fi
done

echo "Completed with ${failed} failed subject(s)."
exit "$failed"
