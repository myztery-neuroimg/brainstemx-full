#!/usr/bin/env bash
#
# test_multi_atlas_unit.sh - Unit tests for src/modules/multi_atlas.sh
#
# Tests:
#   - parse_atlas_lut across the three real LUT formats (AAL3 / CIT168 / Bianciardi)
#   - parse_atlas_lut tolerance: comments, blank lines, CRLF, trailing fields
#   - Module sources cleanly (functions defined) + double-source is a no-op
#   - _lut_image_offset detects 0-indexed (CIT168) vs 1-indexed LUTs
#   - run_multi_atlas_brainstem degrades gracefully when atlases are missing
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "multi_atlas.sh Unit Tests"
setup_test_environment

# Mocks for FSL tools the module may touch.
create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true

# Source environment then the module under test.
load_environment_module
# environment.sh sets errexit/nounset; tests deliberately exercise failure paths,
# so disable errexit for the suite (matches the set +e style used elsewhere).
set +e
source "$PROJECT_ROOT/src/modules/multi_atlas.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# 1. Module loads and exports its public functions
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Module load + function definitions"

assert_function_exists "parse_atlas_lut"            "parse_atlas_lut defined"
assert_function_exists "build_bianciardi_dseg"      "build_bianciardi_dseg defined"
assert_function_exists "normalize_aal3_to_fsl_mni"  "normalize_aal3_to_fsl_mni defined"
assert_function_exists "warp_atlas_dseg_to_subject" "warp_atlas_dseg_to_subject defined"
assert_function_exists "split_dseg_to_region_masks" "split_dseg_to_region_masks defined"
assert_function_exists "run_multi_atlas_brainstem"  "run_multi_atlas_brainstem defined"

# Double-source must be a no-op (include guard).
_before="$_MULTI_ATLAS_LOADED"
source "$PROJECT_ROOT/src/modules/multi_atlas.sh" 2>/dev/null || true
assert_equals "$_before" "$_MULTI_ATLAS_LOADED" "double-source is a no-op (guard holds)"

# ══════════════════════════════════════════════════════════════════════════════
# 2. parse_atlas_lut — the three real LUT formats
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. parse_atlas_lut formats"

# --- AAL3 format: "idx name color..." (1-indexed) ---
aal_lut="$TEMP_TEST_DIR/aal3.txt"
cat > "$aal_lut" <<'EOF'
1 Precentral_L 1
2 Precentral_R 2
3 Frontal_Sup_2_L 3
EOF
aal_out=$(parse_atlas_lut "$aal_lut")
assert_equals "1	Precentral_L" "$(echo "$aal_out" | sed -n '1p')" "AAL3: idx 1 -> Precentral_L (trailing color dropped)"
assert_equals "3" "$(echo "$aal_out" | wc -l | tr -d ' ')" "AAL3: 3 rows parsed"

# --- CIT168 format: "idx name" (0-indexed) ---
cit_lut="$TEMP_TEST_DIR/cit168.txt"
cat > "$cit_lut" <<'EOF'
0   Pu
1   Ca
15  STH
EOF
cit_out=$(parse_atlas_lut "$cit_lut")
assert_equals "0	Pu" "$(echo "$cit_out" | sed -n '1p')" "CIT168: idx 0 -> Pu (0-indexed kept)"
assert_equals "15	STH" "$(echo "$cit_out" | sed -n '3p')" "CIT168: idx 15 -> STH"

# --- Bianciardi generated format: "idx name owned_voxels" with comment header ---
bianc_lut="$TEMP_TEST_DIR/bianc.txt"
printf '# index\tname\towned_voxels\n1\tCLi_RLi\t167\n2\tCnF_l\t51\n' > "$bianc_lut"
bianc_out=$(parse_atlas_lut "$bianc_lut")
assert_equals "1	CLi_RLi" "$(echo "$bianc_out" | sed -n '1p')" "Bianciardi: idx 1 -> CLi_RLi (owned_voxels dropped)"
assert_equals "2" "$(echo "$bianc_out" | wc -l | tr -d ' ')" "Bianciardi: comment header skipped, 2 rows"

# ══════════════════════════════════════════════════════════════════════════════
# 3. parse_atlas_lut — tolerance (comments, blanks, CRLF, junk)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. parse_atlas_lut tolerance"

mixed_lut="$TEMP_TEST_DIR/mixed.txt"
printf '# a comment\n\n   \n7\tNuc7\tjunk\textra\r\nnotanint Name\n9 Nuc9\n' > "$mixed_lut"
mixed_out=$(parse_atlas_lut "$mixed_lut")
assert_equals "7	Nuc7" "$(echo "$mixed_out" | sed -n '1p')" "tolerance: CRLF stripped, trailing fields ignored"
assert_equals "9	Nuc9" "$(echo "$mixed_out" | sed -n '2p')" "tolerance: non-integer-idx line skipped"
assert_equals "2" "$(echo "$mixed_out" | wc -l | tr -d ' ')" "tolerance: only 2 valid rows"

# Missing file -> non-zero, no crash.
parse_atlas_lut "$TEMP_TEST_DIR/does_not_exist.txt" >/dev/null 2>&1
assert_exit_code 1 $? "parse_atlas_lut returns non-zero on missing file"

# ══════════════════════════════════════════════════════════════════════════════
# 4. _lut_image_offset — 0-indexed vs 1-indexed detection
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. _lut_image_offset"

assert_equals "1" "$(_lut_image_offset "$cit_lut")"  "CIT168 (min idx 0) -> offset 1"
assert_equals "0" "$(_lut_image_offset "$aal_lut")"  "AAL3 (min idx 1) -> offset 0"
assert_equals "0" "$(_lut_image_offset "$bianc_lut")" "Bianciardi (min idx 1) -> offset 0"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Graceful degradation when atlases are absent
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. Graceful degradation (atlas missing)"

# Point ATLAS_DIR at an empty dir; build/normalize must WARNING + return 0.
export ATLAS_DIR="$TEMP_TEST_DIR/empty_atlases"
mkdir -p "$ATLAS_DIR"

build_bianciardi_dseg >/dev/null 2>&1
assert_exit_code 0 $? "build_bianciardi_dseg returns 0 (graceful) when subdirs missing"

# run_multi_atlas_brainstem on a missing T1 -> non-zero (data missing), no crash.
run_multi_atlas_brainstem "$TEMP_TEST_DIR/no_such_t1.nii.gz" "subj" >/dev/null 2>&1
rc=$?
assert_equals "false" "$([ "$rc" -eq 0 ] && echo true || echo false)" \
    "run_multi_atlas_brainstem returns non-zero on missing subject T1"

# ── Summary ───────────────────────────────────────────────────────────────────
cleanup_test_environment
print_test_summary
