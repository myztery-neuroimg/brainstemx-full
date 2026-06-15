#!/usr/bin/env bash
#
# test_fp_filter_unit.sh - Unit + functional tests for src/modules/fp_filter.sh
#
# Module-load tests (always run, no FSL required):
#   - all public functions are defined after sourcing
#   - double-sourcing is a no-op (include guard)
#   - missing input mask -> ERR_DATA_MISSING
#   - missing CSF / brain map -> graceful skip (mask unchanged)
#   - SegAE disabled -> pass-through
#   - run_fp_filter disabled (FP_FILTER_ENABLED=false) -> pass-through
#
# Functional tests (run only when REAL FSL is available):
#   - min-cluster removes a tiny component (and logs the loss) but keeps a large one
#   - brain-mask erosion drops edge voxels
#   - CSF-distance drops the cluster near CSF, keeps the far one
#   - run_fp_filter no-op config passes mask through unchanged
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
init_test_suite "fp_filter.sh Unit + Functional Tests"
setup_test_environment

# Load environment (provides log_*, ERR_* codes, safe_fslmaths).
load_environment_module

# Detect whether REAL FSL is available BEFORE we install any mocks.
HAVE_REAL_FSL=false
if command -v fslmaths >/dev/null 2>&1 \
   && command -v fslstats >/dev/null 2>&1 \
   && command -v fslcreatehd >/dev/null 2>&1 \
   && command -v cluster >/dev/null 2>&1 \
   && command -v fslinfo >/dev/null 2>&1; then
    HAVE_REAL_FSL=true
fi

if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    echo "Real FSL detected - functional tests will run."
else
    echo "Real FSL not available - installing mocks; functional tests will be skipped."
    # Mocks let the module load and the validation/skip paths run without FSL.
    create_mock_fslinfo
    create_mock_fslstats
    create_mock_fslmaths
fi

# Source the module under test.
if [[ -f "$PROJECT_ROOT/src/modules/fp_filter.sh" ]]; then
    source "$PROJECT_ROOT/src/modules/fp_filter.sh" 2>/dev/null || true
    echo "Loaded fp_filter.sh"
else
    echo -e "${RED}ERROR: fp_filter.sh not found${NC}"
    exit 1
fi

# ── Helpers for functional tests ──────────────────────────────────────────────
# Make an empty float NIfTI of fixed geometry, then set individual voxels via ROI
# fills.  Uses only fslcreatehd + fslmaths so it works on any FSL install.
fp_make_empty() {
    # $1 = output path
    local out="$1"
    # 40x40x40, 1mm isotropic, datatype 16 (FLOAT32)
    fslcreatehd 40 40 40 1 1 1 1 1 0 0 0 16 "$out" 2>/dev/null
    # Zero it out to be safe.
    fslmaths "$out" -mul 0 "$out" 2>/dev/null
}

# Add a solid cube of value 1 into a mask, in-place.
# args: file x y z size
fp_add_cube() {
    local file="$1" x="$2" y="$3" z="$4" size="$5"
    local tmp="${file%.nii.gz}.cube_$$.nii.gz"
    fslmaths "$file" -mul 0 -add 1 \
        -roi "$x" "$size" "$y" "$size" "$z" "$size" 0 1 "$tmp" 2>/dev/null
    fslmaths "$file" -add "$tmp" -bin "$file" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Module load: functions defined"
# ══════════════════════════════════════════════════════════════════════════════
assert_function_exists "fp_filter_min_cluster"        "fp_filter_min_cluster defined"
assert_function_exists "fp_filter_brainmask_erosion"  "fp_filter_brainmask_erosion defined"
assert_function_exists "fp_filter_csf_distance"       "fp_filter_csf_distance defined"
assert_function_exists "fp_filter_segae_pulsation"    "fp_filter_segae_pulsation defined"
assert_function_exists "run_fp_filter"                "run_fp_filter dispatcher defined"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. Include guard: double-source is a no-op"
# ══════════════════════════════════════════════════════════════════════════════
assert_equals "1" "${_FP_FILTER_LOADED:-}" "_FP_FILTER_LOADED set after first source"
# Re-source: guard should make it return immediately without error.
source "$PROJECT_ROOT/src/modules/fp_filter.sh" 2>/dev/null
src_ec=$?
assert_exit_code 0 "$src_ec" "re-sourcing fp_filter.sh returns 0 (guard no-op)"
assert_equals "1" "${_FP_FILTER_LOADED:-}" "_FP_FILTER_LOADED still set after re-source"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. Config defaults present"
# ══════════════════════════════════════════════════════════════════════════════
# Source config in a subshell-safe way (it has its own include guard, so source
# directly to read the values).
source "$PROJECT_ROOT/config/default_config.sh" 2>/dev/null || true
assert_equals "false" "${FP_FILTER_ENABLED:-unset}" "FP_FILTER_ENABLED defaults to false (OFF)"
assert_var_set "FP_MIN_CLUSTER_VOXELS"   "FP_MIN_CLUSTER_VOXELS defined"
assert_var_set "FP_BRAINMASK_EROSION_MM" "FP_BRAINMASK_EROSION_MM defined"
assert_var_set "FP_CSF_DISTANCE_MM"      "FP_CSF_DISTANCE_MM defined"
assert_equals "false" "${FP_SEGAE_ENABLED:-unset}" "FP_SEGAE_ENABLED defaults to false (OFF)"
assert_var_set "FP_CLUSTER_CONNECTIVITY" "FP_CLUSTER_CONNECTIVITY defined"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. Input validation: missing mask -> ERR_DATA_MISSING"
# ══════════════════════════════════════════════════════════════════════════════
set +e
fp_filter_min_cluster "$TEMP_TEST_DIR/does_not_exist.nii.gz" "$TEMP_TEST_DIR/out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code "${ERR_DATA_MISSING:-31}" "$ec" "fp_filter_min_cluster returns ERR_DATA_MISSING on missing input"

set +e
run_fp_filter "$TEMP_TEST_DIR/does_not_exist.nii.gz" "$TEMP_TEST_DIR/out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code "${ERR_DATA_MISSING:-31}" "$ec" "run_fp_filter returns ERR_DATA_MISSING on missing input"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. Graceful degradation: missing CSF / brain maps -> skip"
# ══════════════════════════════════════════════════════════════════════════════
# Build a minimal valid input mask (real or mocked).
fp_in="$TEMP_TEST_DIR/lesion_in.nii.gz"
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    fp_make_empty "$fp_in"
    fp_add_cube "$fp_in" 18 18 18 4   # one solid 4^3 cube
else
    create_fake_nifti "$fp_in" 20
fi

# Missing brain mask -> pass-through (returns 0, output exists).
set +e
fp_filter_brainmask_erosion "$fp_in" "$TEMP_TEST_DIR/no_brain.nii.gz" "$TEMP_TEST_DIR/be_out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code 0 "$ec" "fp_filter_brainmask_erosion returns 0 when brain mask missing (graceful skip)"
assert_file_exists "$TEMP_TEST_DIR/be_out.nii.gz" "brain-erosion produced pass-through output when brain mask missing"

# Missing CSF map -> pass-through.
set +e
fp_filter_csf_distance "$fp_in" "$TEMP_TEST_DIR/no_csf.nii.gz" "$TEMP_TEST_DIR/csf_out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code 0 "$ec" "fp_filter_csf_distance returns 0 when CSF map missing (graceful skip)"
assert_file_exists "$TEMP_TEST_DIR/csf_out.nii.gz" "CSF-distance produced pass-through output when CSF map missing"

# SegAE: disabled (default) -> pass-through even with no CSF map.
set +e
FP_SEGAE_ENABLED=false fp_filter_segae_pulsation "$fp_in" "$TEMP_TEST_DIR/no_csf.nii.gz" "$TEMP_TEST_DIR/segae_out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code 0 "$ec" "fp_filter_segae_pulsation returns 0 when disabled (graceful skip)"
assert_file_exists "$TEMP_TEST_DIR/segae_out.nii.gz" "SegAE produced pass-through output when disabled"

# SegAE: enabled but CSF prob map absent -> graceful skip (still returns 0).
set +e
FP_SEGAE_ENABLED=true fp_filter_segae_pulsation "$fp_in" "$TEMP_TEST_DIR/no_csf.nii.gz" "$TEMP_TEST_DIR/segae_out2.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code 0 "$ec" "fp_filter_segae_pulsation returns 0 when enabled but CSF prob map absent"
assert_file_exists "$TEMP_TEST_DIR/segae_out2.nii.gz" "SegAE produced pass-through output when CSF prob absent"

# run_fp_filter master switch OFF -> pass-through.
set +e
FP_FILTER_ENABLED=false run_fp_filter "$fp_in" "$TEMP_TEST_DIR/disp_off.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
assert_exit_code 0 "$ec" "run_fp_filter returns 0 when FP_FILTER_ENABLED=false"
assert_file_exists "$TEMP_TEST_DIR/disp_off.nii.gz" "run_fp_filter produced pass-through output when disabled"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "6. Functional: min-cluster removes tiny, keeps large (FSL only)"
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    mc_in="$TEMP_TEST_DIR/mc_in.nii.gz"
    mc_out="$TEMP_TEST_DIR/mc_out.nii.gz"
    fp_make_empty "$mc_in"
    fp_add_cube "$mc_in" 10 10 10 5    # large component: 5^3 = 125 voxels
    fp_add_cube "$mc_in" 30 30 30 1    # tiny component: 1 voxel

    vox_before=$(fslstats "$mc_in" -V | awk '{print $1}')
    # Capture log output to verify the loss is reported at WARNING level.
    log_out=$(fp_filter_min_cluster "$mc_in" "$mc_out" 2 26 2>&1)
    vox_after=$(fslstats "$mc_out" -V | awk '{print $1}')

    assert_equals "126" "$vox_before"  "min-cluster input has 126 voxels (125 + 1)"
    assert_equals "125" "$vox_after"   "min-cluster removed the 1-voxel component, kept the 125-voxel one"
    assert_contains "$log_out" "REMOVED" "min-cluster logs the voxel loss (REMOVED ...)"
    assert_contains "$log_out" "Molchanova" "min-cluster log references the Molchanova 2024 caveat"
else
    echo -e "${YELLOW}  SKIP${NC}: min-cluster functional test (FSL not available)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "7. Functional: brain-mask erosion drops edge voxels (FSL only)"
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    be_in="$TEMP_TEST_DIR/be2_in.nii.gz"
    be_brain="$TEMP_TEST_DIR/be2_brain.nii.gz"
    be_out="$TEMP_TEST_DIR/be2_out.nii.gz"

    # Brain mask: solid central cube 8..32 (24^3).  After 1mm erosion the surface
    # shell is removed.
    fp_make_empty "$be_brain"
    fp_add_cube "$be_brain" 8 8 8 24

    # Lesion mask: one voxel ON the brain surface (x=8, an edge plane) plus one
    # deep-interior voxel (x=20).  Erosion should drop the edge voxel, keep deep.
    fp_make_empty "$be_in"
    fp_add_cube "$be_in" 8 20 20 1     # edge voxel (on surface plane x=8)
    fp_add_cube "$be_in" 20 20 20 1    # deep interior voxel

    vox_before=$(fslstats "$be_in" -V | awk '{print $1}')
    fp_filter_brainmask_erosion "$be_in" "$be_brain" "$be_out" 1 >/dev/null 2>&1
    vox_after=$(fslstats "$be_out" -V | awk '{print $1}')

    assert_equals "2" "$vox_before" "brain-erosion input has 2 voxels (edge + deep)"
    assert_equals "1" "$vox_after"  "brain-erosion dropped the surface/edge voxel, kept the deep one"
else
    echo -e "${YELLOW}  SKIP${NC}: brain-erosion functional test (FSL not available)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "8. Functional: CSF-distance drops near-CSF cluster (FSL only)"
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    cd_in="$TEMP_TEST_DIR/cd_in.nii.gz"
    cd_csf="$TEMP_TEST_DIR/cd_csf.nii.gz"
    cd_out="$TEMP_TEST_DIR/cd_out.nii.gz"

    # CSF mask: a cube at 5..9 (5^3).
    fp_make_empty "$cd_csf"
    fp_add_cube "$cd_csf" 5 5 5 5

    # Lesion mask: NEAR cluster adjacent to CSF (at x=10, immediately next to the
    # CSF cube that ends at x=9) and a FAR cluster (at x=30).
    fp_make_empty "$cd_in"
    fp_add_cube "$cd_in" 10 6 6 2     # near CSF (within 1mm of the CSF band)
    fp_add_cube "$cd_in" 30 30 30 3   # far from CSF

    near_vox=8     # 2^3
    far_vox=27     # 3^3
    vox_before=$(fslstats "$cd_in" -V | awk '{print $1}')
    log_out=$(fp_filter_csf_distance "$cd_in" "$cd_csf" "$cd_out" 1 0.5 26 2>&1)
    vox_after=$(fslstats "$cd_out" -V | awk '{print $1}')

    assert_equals "$((near_vox + far_vox))" "$vox_before" "CSF-distance input has near(8)+far(27)=35 voxels"
    assert_equals "$far_vox" "$vox_after" "CSF-distance dropped the near-CSF cluster, kept the far one (27 voxels)"
    assert_contains "$log_out" "REMOVED" "CSF-distance logs the cluster removal"
else
    echo -e "${YELLOW}  SKIP${NC}: CSF-distance functional test (FSL not available)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "9. Functional: no-op config passes mask through unchanged (FSL only)"
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    np_in="$TEMP_TEST_DIR/np_in.nii.gz"
    np_out="$TEMP_TEST_DIR/np_out.nii.gz"
    fp_make_empty "$np_in"
    fp_add_cube "$np_in" 10 10 10 5
    fp_add_cube "$np_in" 30 30 30 1   # include a tiny cluster too

    vox_before=$(fslstats "$np_in" -V | awk '{print $1}')
    # Master switch OFF: dispatcher must NOT alter the mask.
    FP_FILTER_ENABLED=false run_fp_filter "$np_in" "$np_out" >/dev/null 2>&1
    vox_after=$(fslstats "$np_out" -V | awk '{print $1}')
    assert_equals "$vox_before" "$vox_after" "run_fp_filter (disabled) leaves voxel count unchanged"

    # Also: enabled but with all stages individually disabled AND no support maps
    # -> still a pass-through (no stage applies, min-cluster off).
    np_out2="$TEMP_TEST_DIR/np_out2.nii.gz"
    FP_FILTER_ENABLED=true \
    FP_MIN_CLUSTER_ENABLED=false \
    FP_BRAINMASK_EROSION_ENABLED=false \
    FP_CSF_DISTANCE_ENABLED=false \
    FP_SEGAE_ENABLED=false \
        run_fp_filter "$np_in" "$np_out2" >/dev/null 2>&1
    vox_after2=$(fslstats "$np_out2" -V | awk '{print $1}')
    assert_equals "$vox_before" "$vox_after2" "run_fp_filter (all stages off) leaves voxel count unchanged"
else
    echo -e "${YELLOW}  SKIP${NC}: no-op dispatcher functional test (FSL not available)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "10. Functional: empty input mask handled without spurious error (FSL only)"
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    em_in="$TEMP_TEST_DIR/em_in.nii.gz"
    em_out="$TEMP_TEST_DIR/em_out.nii.gz"
    fp_make_empty "$em_in"   # zero voxels - common for lesion-free ROIs

    set +e
    log_out=$(fp_filter_min_cluster "$em_in" "$em_out" 2 26 2>&1)
    ec=$?
    set -e 2>/dev/null || true
    assert_exit_code 0 "$ec" "min-cluster returns 0 on an empty mask"
    assert_file_exists "$em_out" "min-cluster produced output for empty mask"
    vox_after=$(fslstats "$em_out" -V | awk '{print $1}')
    assert_equals "0" "$vox_after" "min-cluster output is still empty"
    assert_not_contains "$log_out" "FSL cluster failed" "min-cluster does NOT report a spurious cluster failure on empty input"
else
    echo -e "${YELLOW}  SKIP${NC}: empty-mask functional test (FSL not available)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "11. Dispatcher surfaces output-write failure"
# ══════════════════════════════════════════════════════════════════════════════
# A non-writable output directory must make run_fp_filter (disabled passthrough)
# return an I/O error code instead of a misleading 0.
ro_in="$TEMP_TEST_DIR/ro_in.nii.gz"
if [[ "$HAVE_REAL_FSL" == "true" ]]; then
    fp_make_empty "$ro_in"; fp_add_cube "$ro_in" 10 10 10 4
else
    create_fake_nifti "$ro_in" 20
fi
ro_dir="$TEMP_TEST_DIR/readonly_out"
mkdir -p "$ro_dir"
chmod 0555 "$ro_dir"   # read+execute only: no writes
set +e
FP_FILTER_ENABLED=false run_fp_filter "$ro_in" "$ro_dir/out.nii.gz" 2>/dev/null
ec=$?
set -e 2>/dev/null || true
chmod 0755 "$ro_dir" 2>/dev/null || true   # restore so cleanup can remove it
# Only assert when running as a non-root user (root bypasses dir perms).
if [[ "$(id -u)" -ne 0 ]]; then
    assert_exit_code "${ERR_IO_ERROR:-5}" "$ec" "run_fp_filter returns ERR_IO_ERROR when output dir is not writable"
else
    echo -e "${YELLOW}  SKIP${NC}: write-failure test (running as root bypasses dir permissions)"
fi

# ── Summary & cleanup ─────────────────────────────────────────────────────────
cleanup_test_environment
print_test_summary
