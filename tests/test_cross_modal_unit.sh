#!/usr/bin/env bash
#
# test_cross_modal_unit.sh - Unit tests for the MULTI-MODAL additions:
#   - scan_selection.sh secondary-modality discovery (SWI/DWI-trace/ADC/T2),
#     incl. the T2-vs-FLAIR and DWI-trace-vs-ADC contamination filters
#   - registration.sh resolve_contrast_anchor() now maps ADC -> FLAIR
#   - cross_modal_analysis.sh module load + include guard + graceful no-op
#   - cross_modal_analysis.sh _cross_modal_find_coregistered discovery
#
# These are pure-logic / filesystem tests; no FSL/ANTs/Python required (the
# Python sampler is exercised separately end-to-end). The graceful no-op path is
# the load-bearing guarantee that T1+FLAIR-only studies are unaffected.
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "Multi-modal (cross-modal) Unit Tests"
setup_test_environment

# Mocks for FSL tools any sourced module might touch at load time.
create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true
create_mock_fslinfo  >/dev/null 2>&1 || true

load_environment_module
# Tests deliberately exercise graceful-failure paths; disable errexit (matches
# the set +e convention used by the other unit suites).
set +e

# Load config defaults so MULTIMODAL_*/CONTRAST_ANCHOR_MAP/CROSS_MODAL_* exist.
source "$PROJECT_ROOT/config/default_config.sh" 2>/dev/null || true
source "$PROJECT_ROOT/src/modules/scan_selection.sh" 2>/dev/null || true
source "$PROJECT_ROOT/src/modules/registration.sh" 2>/dev/null || true
source "$PROJECT_ROOT/src/modules/cross_modal_analysis.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# 1. Config defaults reflect the multi-modal enablement
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Multi-modal config defaults"

assert_equals "true" "${CONTRAST_MATCHED_REGISTRATION:-}" "CONTRAST_MATCHED_REGISTRATION defaults true"
assert_equals "true" "${AUTO_REGISTER_ALL_MODALITIES:-}" "AUTO_REGISTER_ALL_MODALITIES defaults true"
assert_equals "true" "${CROSS_MODAL_ANALYSIS_ENABLED:-}" "CROSS_MODAL_ANALYSIS_ENABLED defaults true"
assert_var_set "MULTIMODAL_SECONDARY_MODALITIES" "MULTIMODAL_SECONDARY_MODALITIES is set"
assert_var_set "CROSS_MODAL_DWI_TRACE_Z" "CROSS_MODAL_DWI_TRACE_Z is set"

# ══════════════════════════════════════════════════════════════════════════════
# 2. Module load + function definitions + include guard
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. Module load + guards"

assert_function_exists "select_secondary_modality_scan"     "select_secondary_modality_scan defined"
assert_function_exists "discover_secondary_modality_specs"  "discover_secondary_modality_specs defined"
assert_function_exists "_secondary_modality_patterns"       "_secondary_modality_patterns defined"
assert_function_exists "resolve_contrast_anchor"            "resolve_contrast_anchor defined"
assert_function_exists "run_cross_modal_analysis"           "run_cross_modal_analysis defined"
assert_function_exists "_cross_modal_find_coregistered"     "_cross_modal_find_coregistered defined"

_before="${_CROSS_MODAL_ANALYSIS_LOADED:-}"
source "$PROJECT_ROOT/src/modules/cross_modal_analysis.sh" 2>/dev/null || true
assert_equals "$_before" "${_CROSS_MODAL_ANALYSIS_LOADED:-}" "cross_modal double-source is a no-op (guard holds)"

# ══════════════════════════════════════════════════════════════════════════════
# 3. resolve_contrast_anchor: T2-family anchors on FLAIR, incl. ADC
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. Contrast anchor resolution"

assert_equals "FLAIR" "$(resolve_contrast_anchor T2)"  "T2 anchors on FLAIR"
assert_equals "FLAIR" "$(resolve_contrast_anchor SWI)" "SWI anchors on FLAIR"
assert_equals "FLAIR" "$(resolve_contrast_anchor DWI)" "DWI anchors on FLAIR"
assert_equals "FLAIR" "$(resolve_contrast_anchor ADC)" "ADC anchors on FLAIR (multi-modal addition)"
assert_equals "T1"    "$(resolve_contrast_anchor FLAIR)" "FLAIR anchors on T1"

# ══════════════════════════════════════════════════════════════════════════════
# 4. Secondary-modality scan selection + contamination filters
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. Secondary-modality discovery"

EXDIR="$TEMP_TEST_DIR/extract"
mkdir -p "$EXDIR"
# Realistic Siemens-style filenames. T2_SPACE_FLAIR must NOT be picked as T2,
# and the DWI ADC map must NOT be picked as the DWI trace.
create_fake_nifti "$EXDIR/T1_MPRAGE_SAG_12.nii.gz"
create_fake_nifti "$EXDIR/T2_SPACE_5.nii.gz"
create_fake_nifti "$EXDIR/T2_SPACE_FLAIR_Sag_CS_17.nii.gz"
create_fake_nifti "$EXDIR/T2_SWI_AX_8.nii.gz"
create_fake_nifti "$EXDIR/EPI_DWI_trace_b1000_5.nii.gz"
create_fake_nifti "$EXDIR/EPI_DWI_ADC_6.nii.gz"

specs="$(discover_secondary_modality_specs "$EXDIR" "" 2>/dev/null)"

t2_spec="$(echo "$specs"  | grep '^T2=')"
swi_spec="$(echo "$specs" | grep '^SWI=')"
dwi_spec="$(echo "$specs" | grep '^DWI=')"
adc_spec="$(echo "$specs" | grep '^ADC=')"

assert_contains "$t2_spec"  "T2_SPACE_5.nii.gz"          "T2 selected (the true T2 SPACE)"
assert_not_contains "$t2_spec" "FLAIR"                   "T2 selection excludes the T2_SPACE_FLAIR contaminant"
assert_contains "$swi_spec" "T2_SWI_AX_8.nii.gz"         "SWI selected"
assert_contains "$dwi_spec" "trace"                      "DWI selects the trace volume"
assert_not_contains "$dwi_spec" "ADC"                    "DWI selection excludes the ADC map"
assert_contains "$adc_spec" "EPI_DWI_ADC_6.nii.gz"       "ADC selected separately"

# T1+FLAIR-only directory => no secondary specs (graceful).
EXDIR2="$TEMP_TEST_DIR/extract_t1flair"
mkdir -p "$EXDIR2"
create_fake_nifti "$EXDIR2/T1_MPRAGE_SAG_12.nii.gz"
create_fake_nifti "$EXDIR2/T2_SPACE_FLAIR_Sag_CS_17.nii.gz"
specs2="$(discover_secondary_modality_specs "$EXDIR2" "" 2>/dev/null)"
assert_equals "" "$(echo "$specs2" | tr -d '[:space:]')" "T1+FLAIR-only yields NO secondary specs (graceful)"

# ══════════════════════════════════════════════════════════════════════════════
# 5. _cross_modal_find_coregistered: cascade-output discovery
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. Co-registered modality discovery"

REGDIR="$TEMP_TEST_DIR/registered"
CMDIR="$REGDIR/${CONTRAST_MATCHED_SUBDIR:-contrast_matched}"
mkdir -p "$CMDIR"
create_fake_nifti "$CMDIR/T2_SPACE_5_to_flairWarped.nii.gz"
create_fake_nifti "$CMDIR/T2_SWI_AX_8_to_flairWarped.nii.gz"
create_fake_nifti "$CMDIR/EPI_DWI_trace_b1000_to_flairWarped.nii.gz"
create_fake_nifti "$CMDIR/EPI_DWI_ADC_to_flairWarped.nii.gz"

found_t2="$(_cross_modal_find_coregistered T2 "$REGDIR" 2>/dev/null)"
found_swi="$(_cross_modal_find_coregistered SWI "$REGDIR" 2>/dev/null)"
found_dwi="$(_cross_modal_find_coregistered DWI "$REGDIR" 2>/dev/null)"
found_adc="$(_cross_modal_find_coregistered ADC "$REGDIR" 2>/dev/null)"

assert_contains "$found_t2"  "T2_SPACE_5_to_flairWarped"            "T2 co-registered volume found"
assert_contains "$found_swi" "T2_SWI_AX_8_to_flairWarped"           "SWI co-registered volume found"
assert_contains "$found_dwi" "trace"                                "DWI co-registered trace found"
assert_not_contains "$found_dwi" "ADC"                              "DWI discovery excludes ADC"
assert_contains "$found_adc" "EPI_DWI_ADC_to_flairWarped"           "ADC co-registered volume found"

# Empty cascade dir => nothing found.
REGDIR_EMPTY="$TEMP_TEST_DIR/registered_empty"
mkdir -p "$REGDIR_EMPTY/${CONTRAST_MATCHED_SUBDIR:-contrast_matched}"
assert_equals "" "$(_cross_modal_find_coregistered T2 "$REGDIR_EMPTY" 2>/dev/null)" "no co-registered T2 in empty cascade dir"

# ══════════════════════════════════════════════════════════════════════════════
# 6. run_cross_modal_analysis graceful no-op (T1+FLAIR-only)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "6. Graceful no-op (no secondaries co-registered)"

NOOP_RES="$TEMP_TEST_DIR/noop_results"
mkdir -p "$NOOP_RES/registered/${CONTRAST_MATCHED_SUBDIR:-contrast_matched}"
create_fake_nifti "$NOOP_RES/clusters.nii.gz"
create_fake_nifti "$NOOP_RES/brainstem.nii.gz"
create_fake_nifti "$NOOP_RES/flair.nii.gz"

( run_cross_modal_analysis \
    "$NOOP_RES/clusters.nii.gz" "$NOOP_RES/brainstem.nii.gz" "$NOOP_RES/flair.nii.gz" \
    "$NOOP_RES/registered" "$NOOP_RES/cross_modal" ) >/dev/null 2>&1
noop_rc=$?
assert_equals "0" "$noop_rc" "run_cross_modal_analysis returns 0 (graceful) with no secondaries"
assert_file_exists "$NOOP_RES/cross_modal/cross_modal_clusters.csv" "no-op writes a header-only table stub"

# Disabled toggle => immediate no-op success.
( CROSS_MODAL_ANALYSIS_ENABLED=false run_cross_modal_analysis \
    "$NOOP_RES/clusters.nii.gz" "$NOOP_RES/brainstem.nii.gz" "$NOOP_RES/flair.nii.gz" \
    "$NOOP_RES/registered" "$NOOP_RES/cross_modal_off" ) >/dev/null 2>&1
off_rc=$?
assert_equals "0" "$off_rc" "disabled toggle returns 0 without doing work"

# Missing cluster index => graceful skip (returns 0).
( run_cross_modal_analysis \
    "$NOOP_RES/does_not_exist.nii.gz" "$NOOP_RES/brainstem.nii.gz" "$NOOP_RES/flair.nii.gz" \
    "$NOOP_RES/registered" "$NOOP_RES/cross_modal_missing" ) >/dev/null 2>&1
miss_rc=$?
assert_equals "0" "$miss_rc" "missing cluster index returns 0 (graceful skip)"

print_test_summary
cleanup_test_environment
