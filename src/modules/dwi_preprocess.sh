#!/usr/bin/env bash
#
# dwi_preprocess.sh - Diffusion-weighted imaging (DWI) preprocessing
#
# This module implements a proper, modality-appropriate DWI preprocessing path
# for the brainstem/pons pipeline.  Diffusion data must NOT be denoised with
# Rician non-local-means (NLM): NLM removes real signal and inflates the noise
# floor.  The correct approach (Veraart 2016; MRtrix dwidenoise/dwibiascorrect
# docs) is:
#
#   1. MP-PCA denoising         (dwidenoise)        -- FIRST, before anything else
#   2. Gibbs ringing removal    (mrdegibbs)         -- optional
#   3. Eddy/motion/topup        (dwifslpreproc)     -- OPTIONAL: needs acq params
#   4. Bias-field correction    (dwibiascorrect ants / N4 on mean b0)
#   5. Derived volumes          (mean b0 / mean DWI) for downstream brainstem use
#
# Every external tool (MRtrix / FSL) is detected at the point of use and a
# missing tool degrades gracefully (clear non-fatal log + skip), never a crash.
#

# Include guard
if [ -n "${_DWI_PREPROCESS_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_DWI_PREPROCESS_LOADED=1

# Environment guard (fast no-op when pipeline environment already loaded)
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ----------------------------------------------------------------------------
# Helper: locate the gradient table (bvec/bval) that accompanies a DWI image.
# Echoes the bvec path and the bval path on SEPARATE lines (newline-delimited)
# so that paths containing spaces survive; nothing is echoed if either is
# missing.  Returns 0 when both are found, 1 otherwise.
# ----------------------------------------------------------------------------
find_dwi_gradients() {
  local file="$1"
  local stem="${file%.nii.gz}"
  stem="${stem%.nii}"

  local bvec="" bval=""
  if [ -f "${stem}.bvec" ]; then bvec="${stem}.bvec"; fi
  if [ -f "${stem}.bval" ]; then bval="${stem}.bval"; fi

  if [ -n "$bvec" ] && [ -n "$bval" ]; then
    printf '%s\n%s\n' "$bvec" "$bval"
    return 0
  fi
  return 1
}

# ----------------------------------------------------------------------------
# Step 1: MP-PCA denoising (dwidenoise).
# Echoes the denoised file path on stdout; falls back to a pass-through link if
# dwidenoise is unavailable.  NEVER applies Rician NLM.
# ----------------------------------------------------------------------------
denoise_dwi_mppca() {
  local file="$1"

  if ! validate_nifti "$file" "Input DWI for MP-PCA denoising"; then
    log_formatted "ERROR" "Invalid input DWI for MP-PCA denoising: $file"
    return $ERR_DATA_CORRUPT
  fi

  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "denoised" >/dev/null
  local output_file
  output_file=$(get_output_path "denoised" "$basename" "_denoised")

  log_message "DWI MP-PCA denoising (dwidenoise): $file"

  if ! command -v dwidenoise &> /dev/null; then
    log_formatted "WARNING" "dwidenoise (MRtrix MP-PCA) not available - skipping DWI denoising (NLM is NOT a valid substitute for diffusion)"
    ln -sf "$(realpath "$file")" "$output_file"
    echo "$output_file"
    return 0
  fi

  # Optional noise map output (useful for QA); kept alongside the denoised image.
  local noise_map="${output_file%.nii.gz}_noise.nii.gz"

  # Redirect the tool's stdout to stderr: execute_with_logging does NOT redirect
  # command stdout, and this function's only stdout output must be the final
  # echoed path so callers capturing $(denoise_dwi_mppca ...) get a clean path.
  execute_with_logging \
    "dwidenoise -force \"$file\" \"$output_file\" -noise \"$noise_map\"" \
    "dwidenoise" >&2
  local status=$?

  if [ $status -ne 0 ] || [ ! -f "$output_file" ]; then
    log_formatted "ERROR" "dwidenoise failed (status $status) for: $file"
    log_formatted "WARNING" "Falling back to pass-through (no denoising) for DWI"
    ln -sf "$(realpath "$file")" "$output_file"
    echo "$output_file"
    return 0
  fi

  log_message "Saved MP-PCA denoised DWI: $output_file"
  echo "$output_file"
  return 0
}

# ----------------------------------------------------------------------------
# Step 2: Gibbs ringing removal (mrdegibbs) - optional, gated by DWI_DEGIBBS.
# Echoes the (possibly unchanged) file path on stdout.
# ----------------------------------------------------------------------------
degibbs_dwi() {
  local file="$1"

  if [ "${DWI_DEGIBBS:-true}" != "true" ]; then
    log_message "Gibbs unringing disabled (DWI_DEGIBBS=false) - skipping"
    echo "$file"
    return 0
  fi

  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "denoised" >/dev/null
  local output_file
  output_file=$(get_output_path "denoised" "$basename" "_degibbs")

  log_message "DWI Gibbs unringing (mrdegibbs): $file"

  if ! command -v mrdegibbs &> /dev/null; then
    log_formatted "WARNING" "mrdegibbs not available - skipping Gibbs unringing"
    echo "$file"
    return 0
  fi

  # Redirect tool stdout to stderr (see denoise_dwi_mppca note) so the only
  # stdout this function emits is the final echoed path.
  execute_with_logging \
    "mrdegibbs -force \"$file\" \"$output_file\"" \
    "mrdegibbs" >&2
  local status=$?

  if [ $status -ne 0 ] || [ ! -f "$output_file" ]; then
    log_formatted "WARNING" "mrdegibbs failed (status $status) - continuing with un-deringed image"
    echo "$file"
    return 0
  fi

  log_message "Saved Gibbs-unringed DWI: $output_file"
  echo "$output_file"
  return 0
}

# ----------------------------------------------------------------------------
# Step 3 (OPTIONAL): eddy/motion/topup via dwifslpreproc.
# This requires acquisition parameters (phase-encode direction, readout time)
# and gradient files.  Runs only if DWI_RUN_EDDY=true AND the needed inputs are
# present; otherwise logs a clear skip and returns the input unchanged.
# Echoes the (possibly unchanged) file path on stdout.
# ----------------------------------------------------------------------------
eddy_correct_dwi() {
  local file="$1"

  if [ "${DWI_RUN_EDDY:-false}" != "true" ]; then
    log_message "Eddy/motion/topup correction disabled (DWI_RUN_EDDY=false) - skipping"
    echo "$file"
    return 0
  fi

  log_message "DWI eddy/motion correction (dwifslpreproc): $file"

  if ! command -v dwifslpreproc &> /dev/null; then
    log_formatted "WARNING" "dwifslpreproc not available - skipping eddy/motion correction"
    echo "$file"
    return 0
  fi

  # Gradient table is mandatory for eddy.  Read bvec/bval on separate lines so
  # paths containing spaces are preserved.
  local bvec="" bval=""
  if ! { IFS= read -r bvec && IFS= read -r bval; } < <(find_dwi_gradients "$file"); then
    log_formatted "WARNING" "No bvec/bval found for $file - cannot run dwifslpreproc/eddy; skipping (see DWI_RUN_EDDY docs)"
    echo "$file"
    return 0
  fi

  # Phase-encode direction + readout time are required.  If not configured, skip
  # cleanly rather than guessing (a wrong PE direction corrupts the data).
  local pe_dir="${DWI_PE_DIR:-}"
  local readout="${DWI_READOUT_TIME:-}"
  if [ -z "$pe_dir" ] || [ -z "$readout" ]; then
    log_formatted "WARNING" "DWI_PE_DIR / DWI_READOUT_TIME not set - cannot run eddy safely; skipping. Set these in config to enable dwifslpreproc."
    echo "$file"
    return 0
  fi

  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "denoised" >/dev/null
  local output_file
  output_file=$(get_output_path "denoised" "$basename" "_eddy")

  # Redirect tool stdout to stderr (see denoise_dwi_mppca note).
  execute_with_logging \
    "dwifslpreproc \"$file\" \"$output_file\" -rpe_none -pe_dir \"$pe_dir\" -readout_time \"$readout\" -fslgrad \"$bvec\" \"$bval\"" \
    "dwifslpreproc" >&2
  local status=$?

  if [ $status -ne 0 ] || [ ! -f "$output_file" ]; then
    log_formatted "WARNING" "dwifslpreproc failed (status $status) - continuing without eddy correction"
    echo "$file"
    return 0
  fi

  log_message "Saved eddy/motion-corrected DWI: $output_file"
  echo "$output_file"
  return 0
}

# ----------------------------------------------------------------------------
# Step 4: bias-field correction appropriate to DWI.
# Prefers `dwibiascorrect ants` (needs gradients); otherwise falls back to N4 on
# the mean b0 / mean DWI volume.  Echoes the (possibly unchanged) file path.
# ----------------------------------------------------------------------------
biascorrect_dwi() {
  local file="$1"

  if [ "${DWI_BIAS_CORRECT:-true}" != "true" ]; then
    log_message "DWI bias correction disabled (DWI_BIAS_CORRECT=false) - skipping"
    echo "$file"
    return 0
  fi

  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "bias_corrected" >/dev/null
  local output_file
  output_file=$(get_output_path "bias_corrected" "$basename" "_n4")

  log_message "DWI bias-field correction: $file"

  # Preferred path: dwibiascorrect ants (operates on the 4D series with grads).
  # Read bvec/bval on separate lines so paths with spaces survive.
  local bvec="" bval="" have_grads=false
  if { IFS= read -r bvec && IFS= read -r bval; } < <(find_dwi_gradients "$file"); then
    have_grads=true
  fi
  if [ "${DWI_BIAS_METHOD:-ants}" = "ants" ] && command -v dwibiascorrect &> /dev/null && [ "$have_grads" = "true" ]; then
    # Redirect tool stdout to stderr so the only stdout is the final echoed path.
    execute_with_logging \
      "dwibiascorrect ants \"$file\" \"$output_file\" -force -fslgrad \"$bvec\" \"$bval\"" \
      "dwibiascorrect" >&2
    local status=$?
    if [ $status -eq 0 ] && [ -f "$output_file" ]; then
      log_message "Saved dwibiascorrect (ANTs) corrected DWI: $output_file"
      echo "$output_file"
      return 0
    fi
    log_formatted "WARNING" "dwibiascorrect failed (status $status) - falling back to N4 on mean b0"
  else
    log_message "dwibiascorrect unavailable or no gradients - using N4 on mean b0 fallback"
  fi

  # Fallback: N4 on the mean volume (a single-volume bias estimate is better
  # than none).  Requires N4BiasFieldCorrection + a mean volume.
  if ! command -v N4BiasFieldCorrection &> /dev/null; then
    log_formatted "WARNING" "N4BiasFieldCorrection not available - skipping DWI bias correction"
    echo "$file"
    return 0
  fi

  local mean_vol
  mean_vol=$(compute_dwi_mean "$file")
  if [ -z "$mean_vol" ] || [ ! -f "$mean_vol" ]; then
    log_formatted "WARNING" "Could not compute mean DWI volume - skipping bias correction"
    echo "$file"
    return 0
  fi

  # Estimate the bias field on the mean volume only (do not warp the 4D series
  # incorrectly); produce a corrected mean for downstream brainstem registration.
  local corrected_mean="${output_file%.nii.gz}_mean.nii.gz"
  execute_ants_command "dwi_n4_meanb0" "N4 bias correction on mean DWI/b0 volume" \
    N4BiasFieldCorrection \
    -d 3 \
    -i "$mean_vol" \
    -o "$corrected_mean" >&2
  local status=$?
  if [ $status -ne 0 ] || [ ! -f "$corrected_mean" ]; then
    log_formatted "WARNING" "N4 on mean DWI failed (status $status) - skipping bias correction"
    echo "$file"
    return 0
  fi

  log_message "Saved N4-corrected mean DWI volume: $corrected_mean"
  # The 4D series cannot be bias-corrected from a single-volume field here, so
  # the N4-corrected MEAN is the downstream-usable bias-corrected representation.
  # Return it (not the uncorrected 4D series) so callers actually use it.
  echo "$corrected_mean"
  return 0
}

# ----------------------------------------------------------------------------
# Compute a mean volume from the (4D) DWI series for downstream brainstem use.
# Echoes the path to the mean volume on stdout.
# ----------------------------------------------------------------------------
compute_dwi_mean() {
  local file="$1"
  local basename
  basename=$(basename "$file" .nii.gz)
  create_module_dir "bias_corrected" >/dev/null
  local mean_file
  mean_file=$(get_output_path "bias_corrected" "$basename" "_mean")

  # Resumability / avoid redundant -Tmean over multi-GB 4D data: reuse a mean
  # already produced for this exact input in a prior step or run.
  if [ -f "$mean_file" ]; then
    log_message "Reusing existing mean DWI volume: $mean_file"
    echo "$mean_file"
    return 0
  fi

  # Use the macOS-safe fslmaths wrapper for new mask/volume arithmetic.
  if command -v fslmaths &> /dev/null; then
    safe_fslmaths "Compute mean DWI volume" "$file" -Tmean "$mean_file" >/dev/null 2>&1 || {
      log_formatted "WARNING" "Failed to compute mean DWI volume for: $file"
      echo ""
      return 1
    }
    echo "$mean_file"
    return 0
  fi

  log_formatted "WARNING" "fslmaths not available - cannot compute mean DWI volume"
  echo ""
  return 1
}

# ----------------------------------------------------------------------------
# Top-level DWI preprocessing orchestrator.
# Order: MP-PCA -> Gibbs -> (optional) eddy -> bias correction -> mean volume.
# Returns 0 on success (graceful skips are not failures).
# ----------------------------------------------------------------------------
run_dwi_preprocessing() {
  local file="$1"

  log_formatted "INFO" "===== DWI PREPROCESSING (MP-PCA path) ====="
  log_message "Input DWI: $file"

  if ! validate_nifti "$file" "Input DWI"; then
    log_formatted "ERROR" "Invalid input DWI: $file"
    return $ERR_DATA_CORRUPT
  fi

  # Step 1: MP-PCA denoising FIRST (mandatory ordering for diffusion).
  local current
  current=$(denoise_dwi_mppca "$file")
  if [ -z "$current" ] || [ ! -f "$current" ]; then
    log_formatted "ERROR" "MP-PCA denoising produced no output for: $file"
    return $ERR_PREPROC
  fi

  # Step 2: Gibbs unringing (optional).
  current=$(degibbs_dwi "$current")

  # Step 3: eddy/motion/topup (optional; only if params present).
  current=$(eddy_correct_dwi "$current")

  # Step 5 (computed before bias correction): derived mean volume from the
  # denoised/eddy-corrected 4D series, for downstream brainstem registration.
  # Done here so the mean is taken from the diffusion series itself, and so it is
  # not re-derived from a 3D bias-corrected mean (which would double the suffix
  # and waste a -Tmean pass).
  local mean_vol
  mean_vol=$(compute_dwi_mean "$current")
  if [ -n "$mean_vol" ] && [ -f "$mean_vol" ]; then
    log_message "DWI mean volume for downstream use: $mean_vol"
  fi

  # Step 4: bias-field correction (dwibiascorrect ants on the 4D series, or N4
  # on the mean b0 fallback).  The returned path is the bias-corrected
  # representation usable downstream.
  local bias_corrected
  bias_corrected=$(biascorrect_dwi "$current")
  if [ -n "$bias_corrected" ] && [ -f "$bias_corrected" ]; then
    log_message "DWI bias-corrected output for downstream use: $bias_corrected"
    current="$bias_corrected"
  fi

  log_formatted "SUCCESS" "DWI preprocessing complete: $current"
  return 0
}

# Auto-detect DWI inputs in a directory and run the DWI path on each.
# Returns 0 if no DWI present (additive: never affects the T1/FLAIR flow).
run_dwi_preprocessing_auto() {
  local input_dir="${1:-$EXTRACT_DIR}"
  local max_depth="${2:-1}"

  if [ "${PROCESS_DWI:-false}" != "true" ]; then
    log_message "DWI preprocessing disabled (PROCESS_DWI=false) - skipping DWI auto-detection"
    return 0
  fi

  if [ ! -d "$input_dir" ]; then
    log_formatted "WARNING" "DWI auto-detect: input directory not found: $input_dir"
    return 0
  fi

  log_message "Auto-detecting DWI inputs in: $input_dir"

  # Collect candidate NIfTI files and route only the diffusion ones.
  local found=0
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local modality=""
    if declare -F detect_modality &> /dev/null; then
      modality=$(detect_modality "$f")
    fi
    if [ "$modality" = "DWI" ]; then
      found=$((found + 1))
      run_dwi_preprocessing "$f" || log_formatted "WARNING" "DWI preprocessing reported an issue for: $f"
    fi
  done < <(find "$input_dir" -maxdepth "$max_depth" -name "*.nii.gz" 2>/dev/null | sort)

  if [ "$found" -eq 0 ]; then
    log_message "No DWI inputs detected in $input_dir - nothing to do"
  else
    log_formatted "SUCCESS" "DWI auto-detection processed $found DWI input(s)"
  fi
  return 0
}

# Export functions
export -f find_dwi_gradients
export -f denoise_dwi_mppca
export -f degibbs_dwi
export -f eddy_correct_dwi
export -f biascorrect_dwi
export -f compute_dwi_mean
export -f run_dwi_preprocessing
export -f run_dwi_preprocessing_auto

log_message "DWI preprocessing module (MP-PCA + Gibbs + eddy + bias correction) loaded"
