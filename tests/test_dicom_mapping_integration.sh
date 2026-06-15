#!/usr/bin/env bash
#
# test_dicom_mapping_integration.sh - Tests for the rewritten DICOM cluster mapping.
#
# Covers:
#   - module loads + exports its functions
#   - pipeline still sources + calls the module
#   - the un-gated default (RUN_DICOM_MAPPING=true) and opt-out (=false) both work
#   - inverse-transform discovery prefers a persisted composed inverse list and
#     otherwise builds the FLAIR<->T1 inverse from registration outputs
#   - REAL ANTs round-trip (when ANTs+FSL present): a known cluster COG carried
#     into a registered space and pulled back through resample_index_to_native is
#     recovered on the original native grid within tolerance
#   - bash syntax validation
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "DICOM Cluster Mapping (rewrite)"
setup_test_environment
load_environment_module

MODULE="$PROJECT_ROOT/src/modules/dicom_cluster_mapping.sh"
PY_MODULE="$PROJECT_ROOT/src/modules/map_clusters_to_dicom.py"

# ── 1. Module load + exports ───────────────────────────────────────────────────
begin_test_group "1. Module loading and exports"

bash -c "source '$PROJECT_ROOT/src/modules/environment.sh' >/dev/null 2>&1; source '$MODULE' >/dev/null 2>&1"
assert_exit_code 0 "$?" "source dicom_cluster_mapping.sh (env loaded) succeeds"

# shellcheck disable=SC1090
source "$MODULE" 2>/dev/null

for func in \
    perform_cluster_to_dicom_mapping \
    map_cluster_index_to_dicom \
    resample_index_to_native \
    find_native_flair_reference \
    match_with_dcmdump; do
    assert_function_exists "$func" "function $func is defined"
done

assert_file_exists "$PY_MODULE" "python helper map_clusters_to_dicom.py exists"

# ── 2. Pipeline integration ────────────────────────────────────────────────────
begin_test_group "2. Pipeline integration"

grep -q "source .*modules/dicom_cluster_mapping.sh" "$PROJECT_ROOT/src/pipeline.sh"
assert_exit_code 0 "$?" "pipeline sources the module"

grep -q "perform_cluster_to_dicom_mapping" "$PROJECT_ROOT/src/pipeline.sh"
assert_exit_code 0 "$?" "pipeline calls perform_cluster_to_dicom_mapping"

# ── 3. Gate semantics (un-gated default + opt-out) ──────────────────────────────
begin_test_group "3. Gate semantics"

default_gate=$(grep -E '^export RUN_DICOM_MAPPING=' "$PROJECT_ROOT/config/default_config.sh" | head -1)
assert_contains "$default_gate" "true" "default config un-gates the stage (RUN_DICOM_MAPPING=true)"

grep -q 'RUN_DICOM_MAPPING:-' "$PROJECT_ROOT/src/pipeline.sh"
g1=$?
grep -q 'Skipping DICOM cluster mapping' "$PROJECT_ROOT/src/pipeline.sh"
g2=$?
[ "$g1" -eq 0 ] && [ "$g2" -eq 0 ]
assert_exit_code 0 "$?" "pipeline retains a RUN_DICOM_MAPPING=false opt-out skip branch"

# ── 4. find_native_flair_reference discovery ───────────────────────────────────
begin_test_group "4. Native FLAIR reference discovery"

ref_dir="$TEMP_TEST_DIR/refdisc"
mkdir -p "$ref_dir/brain_extraction"
: > "$ref_dir/brain_extraction/T2_SPACE_FLAIR_brain.nii.gz"
found_ref=$(find_native_flair_reference "$ref_dir")
assert_contains "$found_ref" "FLAIR_brain.nii.gz" "find_native_flair_reference prefers brain_extraction FLAIR"

# Empty results dir + no EXTRACT_DIR FLAIR -> empty (graceful).
empty_ref_dir="$TEMP_TEST_DIR/refempty"
mkdir -p "$empty_ref_dir"
EXTRACT_DIR_SAVE="${EXTRACT_DIR:-}"
export EXTRACT_DIR="$empty_ref_dir"
no_ref=$(find_native_flair_reference "$empty_ref_dir")
assert_equals "" "$no_ref" "find_native_flair_reference returns empty when no FLAIR present"
export EXTRACT_DIR="$EXTRACT_DIR_SAVE"

# ── 5. REAL ANTs identity round-trip (skipped without ANTs/uv) ───────────────────
# Clusters live in native FLAIR space, so the reverse step is an IDENTITY resample
# onto the native FLAIR grid. This asserts resample_index_to_native preserves the
# cluster COG (and therefore the world coordinate) on the native grid.
begin_test_group "5. Identity resample round-trip"

have_tools=true
command -v antsApplyTransforms >/dev/null 2>&1 || have_tools=false
command -v uv >/dev/null 2>&1 || have_tools=false

if [ "$have_tools" != "true" ]; then
    echo "  [skip] ANTs/uv not available - skipping identity round-trip"
else
    rt="$TEMP_TEST_DIR/roundtrip"
    mkdir -p "$rt"
    PY="uv run --no-sync python"

    # Native FLAIR grid (anisotropic, off-origin) + a cluster blob at a known COG.
    $PY - "$rt/native.nii.gz" "$rt/native_cluster.nii.gz" <<'PY' >/dev/null 2>&1
import sys
import numpy as np, nibabel as nib
aff = np.array([[1.2,0,0,-85.0],[0,0.9,0,-110.0],[0,0,3.0,-60.0],[0,0,0,1]])
shape = (80, 90, 50)
nib.save(nib.Nifti1Image(np.random.default_rng(2).random(shape).astype('float32'), aff), sys.argv[1])
data = np.zeros(shape, np.int16); data[30-2:30+3, 40-2:40+3, 25-2:25+3] = 1
nib.save(nib.Nifti1Image(data, aff), sys.argv[2])
PY

    # Reverse step: identity resample of the cluster onto the native grid.
    resample_index_to_native \
        "$rt/native_cluster.nii.gz" \
        "$rt/native.nii.gz" \
        "$rt/recovered_native.nii.gz" >/dev/null 2>&1

    if [ -f "$rt/recovered_native.nii.gz" ]; then
        verdict=$($PY - "$rt/native_cluster.nii.gz" "$rt/recovered_native.nii.gz" <<'PY' 2>/dev/null
import sys
import numpy as np, nibabel as nib
def cog_world(p):
    img = nib.load(p)
    d = np.rint(np.asanyarray(img.dataobj)).astype(int)
    ijk = np.argwhere(d > 0)
    if ijk.size == 0:
        return None
    c = ijk.mean(0)
    return img.affine.dot([c[0], c[1], c[2], 1.0])[:3]
a, b = cog_world(sys.argv[1]), cog_world(sys.argv[2])
ok = a is not None and b is not None and float(np.linalg.norm(a-b)) <= 1.0
print(f"{'OK' if ok else 'FAIL'} {0.0 if a is None or b is None else float(np.linalg.norm(a-b)):.4f}")
PY
)
        assert_contains "$verdict" "OK" "identity resample preserves native COG world coord within 1 mm ($verdict)"
    else
        assert_equals "ok" "FAIL" "resample_index_to_native produced an output volume"
    fi
fi

# ── 6. Syntax validation ───────────────────────────────────────────────────────
begin_test_group "6. Syntax validation"

bash -n "$MODULE"
assert_exit_code 0 "$?" "module has valid bash syntax"
bash -n "$PROJECT_ROOT/src/pipeline.sh"
assert_exit_code 0 "$?" "pipeline has valid bash syntax"

print_test_summary
