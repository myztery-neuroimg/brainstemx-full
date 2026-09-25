#!/usr/bin/env bash
#
# test_detection_engine_unit.sh - DETECTION_ENGINE dispatch in analysis.sh:
#   - posterior engine (default) runs lesion_posterior.py per region via uv,
#     writes the mask under the legacy output name + params file keys the
#     figures/report read, and apply_connectivity_weighting passes it through;
#   - DETECTION_ENGINE=legacy keeps the GMM chain (mocked python path);
#   - engine failure falls back to the legacy chain (non-fatal).
# Real rendering of the engine needs uv + numpy/scipy/nibabel; otherwise the
# dispatch/fallback logic is verified with the engine unavailable.
#
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
init_test_suite "detection engine dispatch Unit Tests"
setup_test_environment
create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true
create_mock_fslinfo  >/dev/null 2>&1 || true
export RESULTS_DIR="$TEMP_TEST_DIR/results"; mkdir -p "$RESULTS_DIR"
load_environment_module
set +e
source "$PROJECT_ROOT/src/modules/analysis.sh" 2>/dev/null || true

begin_test_group "1. Dispatch functions defined"
assert_function_exists "_apply_posterior_engine" "_apply_posterior_engine defined"
assert_function_exists "apply_gaussian_mixture_thresholding" "apply_gaussian_mixture_thresholding defined"

if command -v uv >/dev/null 2>&1 && uv run --no-sync python -c "import numpy, scipy, nibabel" >/dev/null 2>&1; then
    begin_test_group "2. Posterior engine end-to-end (uv present)"
    uv run --no-sync python - "$TEMP_TEST_DIR" <<'PYEOF'
import sys, numpy as np, nibabel as nib
d = sys.argv[1]; rng = np.random.default_rng(0)
R = np.zeros((28, 28, 28), bool); R[3:25, 3:25, 3:25] = True
z = rng.normal(0, 1, R.shape).astype(np.float32); z[~R] = 0
z[10:13, 10:13, 10:13] += 5.0
nib.save(nib.Nifti1Image(z, np.eye(4)), f"{d}/zscore.nii.gz")
nib.save(nib.Nifti1Image(R.astype(np.uint8), np.eye(4)), f"{d}/region_pons.nii.gz")
PYEOF
    work="$TEMP_TEST_DIR/work"; mkdir -p "$work"
    export DETECTION_ENGINE=posterior
    apply_gaussian_mixture_thresholding "$TEMP_TEST_DIR/zscore.nii.gz" "$TEMP_TEST_DIR/region_pons.nii.gz" "$work/pons_gmm_params.txt" "$work/pons_upper_tail.nii.gz" "$work" >/dev/null 2>&1
    assert_exit_code 0 $? "posterior engine returns 0"
    assert_file_exists "$work/pons_upper_tail.nii.gz" "mask written under the legacy output name"
    assert_file_exists "$work/pons_posterior.nii.gz" "posterior map written next to the mask"
    assert_file_exists "$work/pons_gmm_params.txt" "params file written"
    p="$(cat "$work/pons_gmm_params.txt")"
    assert_contains "$p" "ENGINE=posterior" "params: ENGINE=posterior"
    assert_contains "$p" "NULL_MEAN=" "params: NULL_MEAN (figure/report key)"
    assert_contains "$p" "PI0=" "params: PI0"
    assert_contains "$p" "THRESHOLD=" "params: THRESHOLD (legacy key kept for the report)"
    nfin=$(printf '%s\n' "$p" | awk -F= '$1=="N_FINAL"{print $2}')
    assert_equals "true" "$([ "${nfin:-0}" -ge 20 ] && echo true || echo false)" "the 27-voxel z=5 lesion is detected (N_FINAL>=20, got ${nfin:-0})"
    apply_connectivity_weighting "$work/pons_upper_tail.nii.gz" "$TEMP_TEST_DIR/zscore.nii.gz" "$work/pons_connectivity.nii.gz" >/dev/null 2>&1
    assert_exit_code 0 $? "connectivity weighting passes the engine mask through"
    assert_file_exists "$work/pons_connectivity.nii.gz" "…producing the connectivity-named output"
else
    echo "  (uv/numpy unavailable — posterior end-to-end skipped)"
fi

begin_test_group "3. Fallback + legacy dispatch"
# Engine unavailable (no uv on PATH) -> legacy chain; mock python3 for the legacy GMM script.
saved="$PATH"; export PATH="$TEMP_TEST_DIR/mock_bin:/usr/bin:/bin"
printf '#!/usr/bin/env bash\necho "THRESHOLD=2.000000"; echo "GMM_COMPONENTS=2"; echo "N_VOXELS=500"; echo "UPPER_MEAN=2.5"; echo "UPPER_STD=0.3"; echo "UPPER_WEIGHT=0.1"\n' > "$TEMP_TEST_DIR/mock_bin/python3"; chmod +x "$TEMP_TEST_DIR/mock_bin/python3"
create_fake_nifti "$TEMP_TEST_DIR/z2.nii.gz"; create_fake_nifti "$TEMP_TEST_DIR/r2.nii.gz"
work2="$TEMP_TEST_DIR/work2"; mkdir -p "$work2"
export DETECTION_ENGINE=posterior
out=$(apply_gaussian_mixture_thresholding "$TEMP_TEST_DIR/z2.nii.gz" "$TEMP_TEST_DIR/r2.nii.gz" "$work2/r_params.txt" "$work2/r_upper_tail.nii.gz" "$work2" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "legacy GMM" "engine unavailable -> WARNING and legacy fallback"
assert_contains "$(cat "$work2/r_params.txt" 2>/dev/null)" "GMM_COMPONENTS=2" "legacy params written by the fallback"
export DETECTION_ENGINE=legacy
out=$(apply_gaussian_mixture_thresholding "$TEMP_TEST_DIR/z2.nii.gz" "$TEMP_TEST_DIR/r2.nii.gz" "$work2/l_params.txt" "$work2/l_upper_tail.nii.gz" "$work2" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$out" "posterior engine" "DETECTION_ENGINE=legacy never calls the posterior engine"
export PATH="$saved"

cleanup_test_environment
print_test_summary
