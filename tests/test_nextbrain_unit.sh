#!/usr/bin/env bash
#
# test_nextbrain_unit.sh - Unit tests for src/modules/brainstem_nextbrain.sh
# (FreeSurfer NextBrain histological-atlas brainstem nuclei wrapper).
#
# Tests (tool + FSL mocked):
#   - module load + include guard + exports
#   - _nextbrain_parse_lut: FreeSurfer LUT parsing, multi-word names, brainstem
#     regex filter, side suffix
#   - gating: disabled / tool absent / license absent / input missing -> return 0
#   - end-to-end with a mocked mri_histo_atlas_segment_fireants writing
#     seg.<side>.nii.gz + lut.txt: per-side region masks nextbrain_<name>_<l|r>_label<v>
#     land in detailed_brainstem, caching on re-run, provenance sidecar
#   - tool failure (rc!=0) -> WARNING, non-fatal
#

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
init_test_suite "brainstem_nextbrain.sh Unit Tests"
setup_test_environment

create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true
create_mock_fslinfo  >/dev/null 2>&1 || true   # safe_fslmaths validates its output with fslinfo
mock_dir="$TEMP_TEST_DIR/mock_bin"
# mri_convert: copy input to output (args: -rl ref -rt nearest in out)
cat > "$mock_dir/mri_convert" <<'MOCK'
#!/usr/bin/env bash
args=("$@"); n=${#args[@]}; cp "${args[$((n-2))]}" "${args[$((n-1))]}"; exit 0
MOCK
# mocked NextBrain: writes seg.<side>.nii.gz + lut.txt + vols into --o
cat > "$mock_dir/mri_histo_atlas_segment_fireants" <<'MOCK'
#!/usr/bin/env bash
out=""; side=""
while [ $# -gt 0 ]; do case "$1" in --o) out="$2"; shift;; --side) side="$2"; shift;; esac; shift; done
[ -n "${NEXTBRAIN_MOCK_FAIL:-}" ] && { echo "simulated failure" >&2; exit 3; }
# Simulate the first-run prompt: refuse when stdin is a terminal.
[ -t 0 ] && { echo "Download atlas? [y/n]"; exit 4; }
mkdir -p "$out"
dd if=/dev/zero of="$out/seg.$side.nii.gz" bs=1024 count=8 2>/dev/null
printf '0 Unknown 0 0 0 0\n12 Pontine nuclei 255 0 0 0\n34 Locus coeruleus 0 255 0 0\n56 Superior frontal gyrus 0 0 255 0\n78 Red nucleus 10 10 10 0\n' > "$out/lut.txt"
printf 'label,volume\n12,120.5\n' > "$out/vols.$side.csv"
echo "mock nextbrain $side done"
MOCK
chmod +x "$mock_dir"/*

export RESULTS_DIR="$TEMP_TEST_DIR/results"; mkdir -p "$RESULTS_DIR"
export FREESURFER_HOME="$TEMP_TEST_DIR/fs"; mkdir -p "$FREESURFER_HOME"; : > "$FREESURFER_HOME/license.txt"
create_fake_nifti "$TEMP_TEST_DIR/t1.nii.gz"

load_environment_module
set +e
source "$PROJECT_ROOT/src/modules/multi_atlas.sh" 2>/dev/null || true   # split_dseg_to_region_masks
source "$PROJECT_ROOT/src/modules/brainstem_nextbrain.sh" 2>/dev/null || true

begin_test_group "1. Module load"
assert_function_exists "run_nextbrain_brainstem" "run_nextbrain_brainstem defined"
assert_function_exists "_nextbrain_parse_lut"    "_nextbrain_parse_lut defined"
_b="$_BRAINSTEM_NEXTBRAIN_LOADED"; source "$PROJECT_ROOT/src/modules/brainstem_nextbrain.sh" 2>/dev/null || true
assert_equals "$_b" "$_BRAINSTEM_NEXTBRAIN_LOADED" "double-source is a no-op"

begin_test_group "2. LUT parsing + brainstem filter"
lut="$TEMP_TEST_DIR/lut.txt"
printf '# comment\n0 Unknown 0 0 0 0\n12 Pontine nuclei 255 0 0 0\n34 Locus coeruleus 0 255 0 0\n56 Superior frontal gyrus 0 0 255 0\n78 Red nucleus 10 10 10 0\n' > "$lut"
rows=$(_nextbrain_parse_lut "$lut" l)
assert_contains "$rows" "12	Pontine_nuclei_l" "multi-word name joined with _ and side suffix"
assert_contains "$rows" "34	Locus_coeruleus_l" "LC kept"
assert_contains "$rows" "78	Red_nucleus_l" "midbrain nucleus kept"
assert_not_contains "$rows" "Superior_frontal" "cortical label filtered out by the brainstem regex"
assert_not_contains "$rows" "Unknown" "label 0 dropped"
assert_equals "3" "$(echo "$rows" | wc -l | tr -d ' ')" "3 brainstem rows"
rows_r=$(_nextbrain_parse_lut "$lut" r "locus")
assert_equals "34	Locus_coeruleus_r" "$rows_r" "custom regex + right suffix"

begin_test_group "3. Gating"
BRAINSTEM_NEXTBRAIN_ENABLED=false run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 >/dev/null 2>&1
assert_exit_code 0 $? "disabled -> 0"
run_nextbrain_brainstem "$TEMP_TEST_DIR/missing.nii.gz" t1 >/dev/null 2>&1
assert_exit_code 0 $? "missing input -> 0 (non-fatal)"
saved_path="$PATH"; export PATH="/usr/bin:/bin"
run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 >/dev/null 2>&1
assert_exit_code 0 $? "tool absent -> 0 (non-fatal)"
export PATH="$saved_path"
saved_fs="$FREESURFER_HOME"; export FREESURFER_HOME="$TEMP_TEST_DIR/nofs"; unset FS_LICENSE
run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 >/dev/null 2>&1
assert_exit_code 0 $? "no license -> 0 (non-fatal)"
export FREESURFER_HOME="$saved_fs"

begin_test_group "4. End-to-end (mocked tool)"
export BRAINSTEM_NEXTBRAIN_ENABLED=true
out=$(run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
rc=$?
nb="$RESULTS_DIR/segmentation/nextbrain"; det="$RESULTS_DIR/segmentation/detailed_brainstem"
assert_file_exists "$nb/seg.left.nii.gz"  "left segmentation produced by the tool"
assert_file_exists "$nb/seg.right.nii.gz" "right segmentation produced by the tool"
assert_file_exists "$nb/nextbrain_brainstem_labels_left.txt" "filtered left LUT written"
assert_file_exists "$det/nextbrain_pontine_nuclei_l_label12.nii.gz" "region mask nextbrain_<name>_l_label<v> (left)"
assert_file_exists "$det/nextbrain_locus_coeruleus_r_label34.nii.gz" "region mask nextbrain_<name>_r_label<v> (right)"
assert_file_not_exists "$det/nextbrain_superior_frontal_gyrus_l_label56.nii.gz" "cortical label not split"
assert_file_exists "$nb/nextbrain_provenance.tsv" "provenance sidecar"
assert_contains "$(cat "$nb/nextbrain_provenance.tsv")" "citation	Casamitjana" "provenance cites the atlas"
assert_file_exists "$nb/nextbrain_left.log" "tool log captured"
out2=$(run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out2" "reusing cached" "second run reuses the cached segmentation"

begin_test_group "5. Tool failure is non-fatal"
rm -rf "$RESULTS_DIR/segmentation/nextbrain"
out3=$(NEXTBRAIN_MOCK_FAIL=1 run_nextbrain_brainstem "$TEMP_TEST_DIR/t1.nii.gz" t1 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); rc3=${PIPESTATUS[0]}
assert_contains "$out3" "NextBrain left failed (rc=3" "failure surfaced as WARNING with rc + log path"
assert_contains "$out3" "execute" "hint to run once interactively (atlas download)"

cleanup_test_environment
print_test_summary
