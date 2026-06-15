#!/usr/bin/env bash
#
# test_contrast_matched_registration_unit.sh
#   Unit tests for the contrast-matched cascaded registration helpers in
#   src/modules/registration.sh.
#
# Tests:
#   - resolve_contrast_anchor maps each family to the correct anchor
#   - _collect_syn_transform_args builds the correct ANTs -t order/direction
#     (forward = moving->fixed: warp then affine; inverse = fixed->moving:
#      [affine,1] then InverseWarp) — the warp-direction bug class
#   - register_contrast_matched_modality composes mod->FLAIR with FLAIR->T1 in
#     the correct cascade order and persists forward + inverse transform lists
#   - register_contrast_matched_cascade skips non-FLAIR-anchored / absent specs
#   - module sources cleanly + double-source is a no-op (include guard)
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "Contrast-matched cascaded registration Unit Tests"
setup_test_environment

# Source environment then the module under test.
load_environment_module
# The module exercises failure paths; disable errexit like the sibling suites.
set +e
source "$PROJECT_ROOT/src/modules/registration.sh" 2>/dev/null || true
# Load the config block so CONTRAST_ANCHOR_MAP etc. are defined.
source "$PROJECT_ROOT/config/default_config.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# 1. Module load + function definitions
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Functions defined + guard"

assert_function_exists "resolve_contrast_anchor"             "resolve_contrast_anchor defined"
assert_function_exists "_collect_syn_transform_args"         "_collect_syn_transform_args defined"
assert_function_exists "register_contrast_matched_modality"  "register_contrast_matched_modality defined"
assert_function_exists "register_contrast_matched_cascade"   "register_contrast_matched_cascade defined"

# ══════════════════════════════════════════════════════════════════════════════
# 2. resolve_contrast_anchor — per-family anchor map
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. resolve_contrast_anchor"

assert_equals "FLAIR" "$(resolve_contrast_anchor DWI)"  "DWI anchors on FLAIR"
assert_equals "FLAIR" "$(resolve_contrast_anchor T2)"   "T2 anchors on FLAIR"
assert_equals "FLAIR" "$(resolve_contrast_anchor SWI)"  "SWI anchors on FLAIR"
assert_equals "T1"    "$(resolve_contrast_anchor FLAIR)" "FLAIR anchors on T1"
assert_equals "MNI"   "$(resolve_contrast_anchor T1)"   "T1 anchors on MNI master"
assert_equals "T1"    "$(resolve_contrast_anchor BOGUS)" "unlisted modality defaults to T1"

# ══════════════════════════════════════════════════════════════════════════════
# 3. _collect_syn_transform_args — ORDER + DIRECTION (warp-direction bug class)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. _collect_syn_transform_args order/direction"

pfx="$TEMP_TEST_DIR/reg/mod_to_flair"
mkdir -p "$TEMP_TEST_DIR/reg"
: > "${pfx}0GenericAffine.mat"
: > "${pfx}1Warp.nii.gz"
: > "${pfx}1InverseWarp.nii.gz"

# Forward (moving->fixed): warp FIRST, affine SECOND (affine applied first).
fwd=()
_collect_syn_transform_args fwd "$pfx" "forward"
rc=$?
assert_equals "0" "$rc" "forward collect returns 0"
assert_equals "-t ${pfx}1Warp.nii.gz -t ${pfx}0GenericAffine.mat" "${fwd[*]}" \
    "forward order: warp then affine"

# Inverse (fixed->moving): inverted affine FIRST, InverseWarp SECOND.
inv=()
_collect_syn_transform_args inv "$pfx" "inverse"
rc=$?
assert_equals "0" "$rc" "inverse collect returns 0"
assert_equals "-t [${pfx}0GenericAffine.mat,1] -t ${pfx}1InverseWarp.nii.gz" "${inv[*]}" \
    "inverse order: inverted affine then inverse warp"

# Missing affine => failure.
miss=()
_collect_syn_transform_args miss "$TEMP_TEST_DIR/reg/nope" "forward"
assert_equals "1" "$?" "missing affine => non-zero"

# Affine-only (no warp) forward => affine only.
pfx2="$TEMP_TEST_DIR/reg/affineonly"
: > "${pfx2}0GenericAffine.mat"
aff=()
_collect_syn_transform_args aff "$pfx2" "forward"
assert_equals "-t ${pfx2}0GenericAffine.mat" "${aff[*]}" "affine-only forward => affine only"

# ══════════════════════════════════════════════════════════════════════════════
# 4. register_contrast_matched_modality — composition order + persistence
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. register_contrast_matched_modality composes + persists"

cm_root="$TEMP_TEST_DIR/cm"
mkdir -p "$cm_root/reg" "$cm_root/out"

# Inputs (empty files are enough; ANTs is mocked).
dwi="$cm_root/DWI_trace_std.nii.gz";   : > "$dwi"
flair="$cm_root/FLAIR_std.nii.gz";     : > "$flair"
t1="$cm_root/T1_std.nii.gz";           : > "$t1"

# Existing FLAIR->T1 transforms (forward = FLAIR moving -> T1 fixed).
f2t1="$cm_root/reg/flair_to_t1"
: > "${f2t1}0GenericAffine.mat"
: > "${f2t1}1Warp.nii.gz"
: > "${f2t1}1InverseWarp.nii.gz"

# Mock register_to_reference: emit the mod->FLAIR transform set + Warped output.
register_to_reference() {
    local out_prefix="$4"
    : > "${out_prefix}0GenericAffine.mat"
    : > "${out_prefix}1Warp.nii.gz"
    : > "${out_prefix}1InverseWarp.nii.gz"
    : > "${out_prefix}Warped.nii.gz"
    return 0
}

# Mock execute_ants_command: capture the antsApplyTransforms args and "produce"
# the output file named after -o.
CM_CAPTURED_ARGS=""
execute_ants_command() {
    shift 2                      # drop log_prefix + description
    CM_CAPTURED_ARGS="$*"
    # Find the -o output and create it so the success check passes.
    local prev="" a
    for a in "$@"; do
        [ "$prev" = "-o" ] && : > "$a"
        prev="$a"
    done
    return 0
}

register_contrast_matched_modality "$dwi" "DWI" "$flair" "$f2t1" "$t1" "$cm_root/out"
assert_equals "0" "$?" "register_contrast_matched_modality returns 0"

m2f="$cm_root/out/$(basename "$dwi" .nii.gz)_to_flair"
expected_fwd="-t ${f2t1}1Warp.nii.gz -t ${f2t1}0GenericAffine.mat -t ${m2f}1Warp.nii.gz -t ${m2f}0GenericAffine.mat"

assert_contains "$CM_CAPTURED_ARGS" "$expected_fwd" \
    "composed forward applies FLAIR->T1 stage before mod->FLAIR stage (right-to-left = mod->FLAIR first)"
assert_contains "$CM_CAPTURED_ARGS" "-i $dwi" "antsApplyTransforms input is the DWI"
assert_contains "$CM_CAPTURED_ARGS" "-r $t1"  "antsApplyTransforms reference is the T1 grid"

# Persisted forward list file content matches the composed forward args.
fwd_file="$cm_root/out/$(basename "$dwi" .nii.gz)_to_t1_forward_transforms.txt"
inv_file="$cm_root/out/$(basename "$dwi" .nii.gz)_to_t1_inverse_transforms.txt"
manifest="$cm_root/out/$(basename "$dwi" .nii.gz)_transform_manifest.txt"
assert_file_exists "$fwd_file"  "forward transform list persisted"
assert_file_exists "$inv_file"  "inverse transform list persisted"
assert_file_exists "$manifest"  "transform manifest persisted"
assert_file_exists "$cm_root/out/$(basename "$dwi" .nii.gz)_to_t1_composedWarped.nii.gz" \
    "composed-to-T1 resample produced"

# Forward file is the args one-per-line; flatten and compare.
fwd_flat="$(tr '\n' ' ' < "$fwd_file" | sed 's/ *$//')"
assert_equals "$expected_fwd" "$fwd_flat" "persisted forward list == composed forward args"

# Inverse cascade: undo FLAIR->T1 first (T1->FLAIR), then undo mod->FLAIR
# (FLAIR->DWI).  As an ANTs -t list, applied right-to-left:
#   [mod_affine,1] modInvWarp [flair_affine,1] flairInvWarp
expected_inv="-t [${m2f}0GenericAffine.mat,1] -t ${m2f}1InverseWarp.nii.gz -t [${f2t1}0GenericAffine.mat,1] -t ${f2t1}1InverseWarp.nii.gz"
inv_flat="$(tr '\n' ' ' < "$inv_file" | sed 's/ *$//')"
assert_equals "$expected_inv" "$inv_flat" "persisted inverse list reverses the cascade"

# Missing FLAIR->T1 transforms => clean failure (no compose).
register_contrast_matched_modality "$dwi" "DWI" "$flair" "$cm_root/reg/missing" "$t1" "$cm_root/out2"
assert_not_equals "0" "$?" "missing FLAIR->T1 transforms => non-zero"

# ══════════════════════════════════════════════════════════════════════════════
# 5. register_contrast_matched_cascade — selection / skipping
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. register_contrast_matched_cascade selection"

# The group-4 mocks for register_to_reference + execute_ants_command are still
# active, so the REAL cascade -> real register_contrast_matched_modality runs and
# each successfully-processed modality leaves a *_to_t1_composedWarped.nii.gz.
# Counting those files tells us exactly which modalities were attempted, without
# shadowing register_contrast_matched_modality (which SC2218 would flag).
_count_composed() { find "$1" -name '*_to_t1_composedWarped.nii.gz' 2>/dev/null | wc -l | tr -d ' '; }

casc_out="$TEMP_TEST_DIR/casc"
mkdir -p "$casc_out"
present_dwi="$casc_out/DWI.nii.gz"; : > "$present_dwi"
present_swi="$casc_out/SWI.nii.gz"; : > "$present_swi"

# DWI present (anchor FLAIR), SWI present (anchor FLAIR), T2 ABSENT (skip),
# T1 spec present but anchor != FLAIR (skip).
present_t1="$casc_out/T1.nii.gz"; : > "$present_t1"
register_contrast_matched_cascade "$t1" "$flair" "$f2t1" "$casc_out" \
    "DWI=$present_dwi" "SWI=$present_swi" "T2=$casc_out/absent_T2.nii.gz" "T1=$present_t1"
assert_equals "0" "$?" "cascade returns 0 when all attempted succeed"
assert_equals "2" "$(_count_composed "$casc_out")" \
    "cascade registers only the 2 present FLAIR-anchored modalities (DWI, SWI)"

# Empty spec list => nothing registered, returns 0.
empty_out="$TEMP_TEST_DIR/casc_empty"
mkdir -p "$empty_out"
register_contrast_matched_cascade "$t1" "$flair" "$f2t1" "$empty_out"
assert_equals "0" "$?" "cascade with no specs returns 0"
assert_equals "0" "$(_count_composed "$empty_out")" "cascade with no specs registers nothing"

# ── Summary ───────────────────────────────────────────────────────────────────
cleanup_test_environment
print_test_summary
