#!/usr/bin/env bash
#
# test_reporting_unit.sh - Unit tests for the reporting / aggregation layer:
#   - reporting.sh module load + include guard + function definitions
#   - _reporting_source_for_mask provenance classification
#   - build_segmentation_volume_sidecar discovery + fslstats-driven volume rows
#   - generate_summary_report end-to-end on a synthetic results dir (tables +
#     top-level HTML/MD render; absent sections skipped cleanly)
#   - visualization.sh new report-viz functions are defined and graceful
#
# Pure-logic / filesystem tests; FSL tools are mocked. The end-to-end report
# build uses whichever python is on PATH (the aggregator is stdlib only).
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "Reporting / aggregation Unit Tests"
setup_test_environment

create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true
create_mock_fslinfo  >/dev/null 2>&1 || true

load_environment_module
set +e

source "$PROJECT_ROOT/config/default_config.sh" 2>/dev/null || true
source "$PROJECT_ROOT/src/modules/reporting.sh" 2>/dev/null || true
source "$PROJECT_ROOT/src/modules/visualization.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# 1. Config + module load + guards
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Config defaults + module load + guards"

assert_equals "true" "${REPORTING_ENABLED:-}" "REPORTING_ENABLED defaults true"

assert_function_exists "generate_summary_report"          "generate_summary_report defined"
assert_function_exists "build_segmentation_volume_sidecar" "build_segmentation_volume_sidecar defined"
assert_function_exists "build_per_region_stats_sidecar"    "build_per_region_stats_sidecar defined"
assert_function_exists "_reporting_source_for_mask"        "_reporting_source_for_mask defined"
assert_function_exists "_reporting_mask_volume"            "_reporting_mask_volume defined"

_before="${_REPORTING_LOADED:-}"
source "$PROJECT_ROOT/src/modules/reporting.sh" 2>/dev/null || true
assert_equals "$_before" "${_REPORTING_LOADED:-}" "reporting double-source is a no-op (guard holds)"

# ══════════════════════════════════════════════════════════════════════════════
# 2. Provenance classification from filename
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. _reporting_source_for_mask"

assert_equals "bianciardi" "$(_reporting_source_for_mask /x/bianciardi_LC_label5.nii.gz)" "bianciardi_ -> bianciardi"
assert_equals "cit168"     "$(_reporting_source_for_mask /x/cit168_Pu_label1.nii.gz)"     "cit168_ -> cit168"
assert_equals "aal3"       "$(_reporting_source_for_mask /x/aal3_Precentral_R.nii.gz)"     "aal3_ -> aal3"
assert_equals "synthseg"   "$(_reporting_source_for_mask /x/synthseg_seg.nii.gz)"          "synthseg_ -> synthseg"
assert_equals "aseg"       "$(_reporting_source_for_mask /x/aseg_csf.nii.gz)"              "aseg_ -> aseg"
assert_equals "freesurfer" "$(_reporting_source_for_mask /x/sub_pons.nii.gz)"             "no prefix -> freesurfer"

# ══════════════════════════════════════════════════════════════════════════════
# 3. Segmentation volume sidecar discovery
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. build_segmentation_volume_sidecar"

RD="$TEMP_TEST_DIR/seg_results"
mkdir -p "$RD/segmentation/brainstem" "$RD/segmentation/detailed_brainstem"
touch "$RD/segmentation/brainstem/sub_brainstem.nii.gz"
touch "$RD/segmentation/detailed_brainstem/sub_pons.nii.gz"
touch "$RD/segmentation/detailed_brainstem/bianciardi_LC_label5.nii.gz"
# decoys that must be excluded
touch "$RD/segmentation/detailed_brainstem/sub_pons_intensity.nii.gz"
touch "$RD/segmentation/detailed_brainstem/sub_brainstemSsLabels.nii.gz"

SIDE="$TEMP_TEST_DIR/seg_vol.tsv"
build_segmentation_volume_sidecar "$RD" "$SIDE" >/dev/null 2>&1

assert_file_exists "$SIDE" "sidecar written"
assert_contains "$(cat "$SIDE")" "region	source	volume_mm3	n_voxels" "sidecar has header"
assert_contains "$(cat "$SIDE")" "harvard_oxford" "HO gross row present"
assert_contains "$(cat "$SIDE")" "bianciardi" "bianciardi nucleus row present"
assert_not_contains "$(cat "$SIDE")" "intensity" "intensity decoy excluded"
assert_not_contains "$(cat "$SIDE")" "SsLabels" "SsLabels decoy excluded"
# region name has source prefix stripped
assert_contains "$(cat "$SIDE")" "LC_label5	bianciardi" "bianciardi prefix stripped from region"

# ══════════════════════════════════════════════════════════════════════════════
# 4. End-to-end report build (synthetic results dir, two methods present)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. generate_summary_report end-to-end"

ER="$TEMP_TEST_DIR/e2e_results"
mkdir -p "$ER/per_region_analysis" \
         "$ER/analysis/wmh/bianca" \
         "$ER/analysis/cross_modal" \
         "$ER/segmentation/brainstem" \
         "$ER/segmentation/detailed_brainstem"

printf 'region_tag\tregion_base\tsource\tmask_path\n%s\n' \
  "freesurfer_pons	pons	freesurfer	/x/pons.nii.gz" \
  > "$ER/per_region_analysis/region_provenance.tsv"

cat > "$ER/analysis/wmh/bianca/bianca_wmh_summary.txt" <<'EOF'
tool=bianca
whole_brain_wmh_mm3=2500.0
whole_brain_wmh_clusters=12
brainstem_wmh_mm3=40.0
brainstem_wmh_clusters=2
EOF

cat > "$ER/analysis/cross_modal/cross_modal_clusters.csv" <<'EOF'
cluster_id,n_voxels,flair_z,DWI_z,corroboration,n_corroborating
1,50,2.1,1.4,RESTRICTION,1
EOF

touch "$ER/segmentation/brainstem/sub_brainstem.nii.gz"
touch "$ER/segmentation/detailed_brainstem/sub_pons.nii.gz"

if _reporting_python >/dev/null 2>&1; then
    generate_summary_report "subE2E" "$ER" >/dev/null 2>&1

    assert_file_exists "$ER/reports/tables/hyperintensity_per_region.tsv" "per-region TSV written"
    assert_file_exists "$ER/reports/tables/hyperintensity_per_region.html" "per-region HTML written"
    assert_file_exists "$ER/reports/tables/wmh_tool_volumes.tsv" "WMH TSV written"
    assert_file_exists "$ER/reports/tables/cross_modal.tsv" "cross-modal TSV written"
    assert_file_exists "$ER/reports/tables/run_manifest.tsv" "run manifest TSV written"
    assert_file_exists "$ER/reports/tables/manifest.json" "manifest.json written"
    assert_file_exists "$ER/reports/brainstemx_report.html" "top-level HTML report written"
    assert_file_exists "$ER/reports/brainstemx_report.md" "markdown fallback written"

    assert_contains "$(cat "$ER/reports/tables/wmh_tool_volumes.tsv")" "BIANCA" "BIANCA row in WMH table"
    assert_contains "$(cat "$ER/reports/tables/cross_modal.tsv")" "RESTRICTION" "cross-modal corroboration preserved"
    assert_contains "$(cat "$ER/reports/brainstemx_report.html")" "BrainStemX-Full results report" "report has title"
    # absent section (no FS stats) skipped cleanly
    assert_contains "$(cat "$ER/reports/tables/freesurfer_morphometry.html")" "No data for this section" "absent FS section skipped"
else
    echo "  SKIP: no python available for end-to-end aggregation"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4b. WMH summary backfill (BIANCA leaves a mask but no summary)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4b. backfill_wmh_summaries"

assert_function_exists "backfill_wmh_summaries" "backfill_wmh_summaries defined"

BF="$TEMP_TEST_DIR/backfill_results"
mkdir -p "$BF/analysis/wmh/bianca"
touch "$BF/analysis/wmh/bianca/bianca_wmh_thr0.9_bin.nii.gz"
touch "$BF/analysis/wmh/bianca/bianca_wmh_brainstem.nii.gz"
backfill_wmh_summaries "$BF" >/dev/null 2>&1
assert_file_exists "$BF/analysis/wmh/bianca/bianca_wmh_summary.txt" "BIANCA summary synthesized from mask"
assert_contains "$(cat "$BF/analysis/wmh/bianca/bianca_wmh_summary.txt" 2>/dev/null)" "whole_brain_wmh_mm3=" "synthesized summary has whole-brain volume"

# Idempotent: an existing summary is NOT clobbered.
echo "tool=bianca
whole_brain_wmh_mm3=999.0" > "$BF/analysis/wmh/bianca/bianca_wmh_summary.txt"
backfill_wmh_summaries "$BF" >/dev/null 2>&1
assert_contains "$(cat "$BF/analysis/wmh/bianca/bianca_wmh_summary.txt")" "999.0" "existing summary preserved (idempotent)"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Visualization report functions defined + graceful with no inputs
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. report visualization functions"

assert_function_exists "generate_report_visualizations"   "generate_report_visualizations defined"
assert_function_exists "generate_segmentation_overlays"   "generate_segmentation_overlays defined"
assert_function_exists "generate_hyperintensity_overlays" "generate_hyperintensity_overlays defined"
assert_function_exists "generate_multimodal_montage"      "generate_multimodal_montage defined"
assert_function_exists "_viz_find_base_image"             "_viz_find_base_image defined"

VR="$TEMP_TEST_DIR/viz_results"
mkdir -p "$VR"
generate_report_visualizations "subViz" "$VR" "" >/dev/null 2>&1
assert_exit_code 0 $? "generate_report_visualizations graceful with no inputs"
assert_dir_exists "$VR/visualizations" "visualizations dir created"

print_test_summary
RESULT=$?
cleanup_test_environment
exit $RESULT
