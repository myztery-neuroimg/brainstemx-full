#!/usr/bin/env bash
#
# test_viz_unit.sh - Unit tests for the python-renderer hooks in
# src/modules/visualization.sh (viz_render / viz_figure / viz_stage_dir /
# viz_gallery / _viz_snapshot preference) and src/modules/viz_render.py.
#
# Renders REAL figures when `uv` + numpy/nibabel/matplotlib are available
# (synthetic volumes made with nibabel); otherwise verifies the graceful skip.
#

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
init_test_suite "visualization renderer hooks Unit Tests"
setup_test_environment

export RESULTS_DIR="$TEMP_TEST_DIR/results"; mkdir -p "$RESULTS_DIR"
export SUBJECT_ID="unit"
load_environment_module
set +e
source "$PROJECT_ROOT/src/modules/visualization.sh" 2>/dev/null || true

begin_test_group "1. Helpers defined"
assert_function_exists "viz_render"    "viz_render defined"
assert_function_exists "viz_figure"    "viz_figure defined"
assert_function_exists "viz_stage_dir" "viz_stage_dir defined"
assert_function_exists "viz_gallery"   "viz_gallery defined"
assert_equals "$RESULTS_DIR/visualizations/registration" "$(viz_stage_dir registration)" "viz_stage_dir -> visualizations/<stage>"
assert_dir_exists "$RESULTS_DIR/visualizations/registration" "stage dir created"

begin_test_group "2. Gates"
SKIP_VISUALIZATION=true viz_render overlay --bg x --out y >/dev/null 2>&1
assert_exit_code 1 $? "SKIP_VISUALIZATION=true -> viz_render returns 1 (no work)"
_VIZ_PY_CACHE=""; VIZ_PYTHON_RENDERER=false _viz_py >/dev/null 2>&1
assert_exit_code 1 $? "VIZ_PYTHON_RENDERER=false -> python renderer disabled"
_VIZ_PY_CACHE=""
saved_path="$PATH"; export PATH="/usr/bin:/bin"
_VIZ_PY_CACHE=""; viz_render overlay --bg x --out y >/dev/null 2>&1
assert_exit_code 1 $? "no uv on PATH -> graceful skip (returns 1, no crash)"
export PATH="$saved_path"; _VIZ_PY_CACHE=""

if _viz_py >/dev/null 2>&1; then
    begin_test_group "3. Real rendering (uv + numpy/nibabel/matplotlib present)"
    uv run --no-sync python - "$TEMP_TEST_DIR" <<'PYEOF'
import sys, numpy as np, nibabel as nib
d = sys.argv[1]
rng = np.random.default_rng(1)
bg = rng.normal(100, 8, (24, 28, 26)).astype(np.float32)
zz, yy, xx = np.mgrid[0:24, 0:28, 0:26]
sph = ((zz-12)**2 + (yy-14)**2 + (xx-13)**2) <= 25
bg[sph] += 60
nib.save(nib.Nifti1Image(bg, np.eye(4)), f"{d}/bg.nii.gz")
nib.save(nib.Nifti1Image(sph.astype(np.uint8), np.eye(4)), f"{d}/mask.nii.gz")
nib.save(nib.Nifti1Image((bg*1.05).astype(np.float32), np.eye(4)), f"{d}/after.nii.gz")
PYEOF
    out=$(viz_figure segmentation test_overlay overlay --bg "$TEMP_TEST_DIR/bg.nii.gz" --mask "$TEMP_TEST_DIR/mask.nii.gz:name=pons" --slices 2 --planes axial 2>/dev/null)
    assert_exit_code 0 $? "viz_figure overlay succeeds"
    assert_file_exists "$RESULTS_DIR/visualizations/segmentation/test_overlay.png" "PNG written under visualizations/segmentation"
    assert_file_exists "$RESULTS_DIR/visualizations/segmentation/test_overlay.caption.txt" "caption sidecar written"
    viz_figure preprocess n4 diff --before "$TEMP_TEST_DIR/bg.nii.gz" --after "$TEMP_TEST_DIR/after.nii.gz" --slices 1 >/dev/null 2>&1
    assert_exit_code 0 $? "viz_figure diff succeeds"
    viz_figure registration cb checkerboard --fixed "$TEMP_TEST_DIR/bg.nii.gz" --moving "$TEMP_TEST_DIR/after.nii.gz" --slices 1 --planes axial >/dev/null 2>&1
    assert_exit_code 0 $? "viz_figure checkerboard succeeds"
    viz_figure analysis hist hist --image "$TEMP_TEST_DIR/bg.nii.gz" --mask "$TEMP_TEST_DIR/mask.nii.gz" --components "1,160,10" --threshold 175 >/dev/null 2>&1
    assert_exit_code 0 $? "viz_figure hist succeeds"
    # _viz_snapshot prefers the python renderer (no slicer on PATH here)
    _viz_snapshot "$TEMP_TEST_DIR/bg.nii.gz" "$TEMP_TEST_DIR/mask.nii.gz" "$RESULTS_DIR/visualizations/seg_snapshot.png" >/dev/null 2>&1
    assert_exit_code 0 $? "_viz_snapshot succeeds without FSL slicer (python renderer)"
    assert_file_exists "$RESULTS_DIR/visualizations/seg_snapshot.png" "snapshot PNG written"
    viz_gallery >/dev/null 2>&1
    assert_exit_code 0 $? "viz_gallery builds the index"
    assert_file_exists "$RESULTS_DIR/visualizations/index.html" "visualizations/index.html written"
    assert_contains "$(cat "$RESULTS_DIR/visualizations/index.html")" "segmentation/test_overlay.png" "index lists the stage figure"
    assert_file_exists "$RESULTS_DIR/visualizations/manifest.json" "manifest.json written"
    # ── Stage figure functions on a synthetic results tree ──
    begin_test_group "4. Per-stage figure functions (synthetic results tree)"
    R="$RESULTS_DIR"; mkdir -p "$R/standardized" "$R/segmentation/brainstem" "$R/segmentation/detailed_brainstem" "$R/segmentation/multi_atlas" "$R/registered/contrast_matched"
    cp "$TEMP_TEST_DIR/bg.nii.gz" "$R/standardized/T1_std.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$R/segmentation/brainstem/subj_brainstem.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$R/segmentation/detailed_brainstem/subj_pons.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$R/segmentation/detailed_brainstem/bianciardi_pons.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$R/segmentation/detailed_brainstem/subj_midbrain.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$R/segmentation/multi_atlas/jhu_in_subject.nii.gz"
    printf '# value\tname\n1\tMiddle_cerebellar_peduncle\n' > "$TEMP_TEST_DIR/jhu_lut.txt"
    printf 'key\tjhu\nlut\t%s\n' "$TEMP_TEST_DIR/jhu_lut.txt" > "$R/segmentation/multi_atlas/jhu_provenance.tsv"
    cp "$TEMP_TEST_DIR/after.nii.gz" "$R/registered/contrast_matched/T2_SPACE_to_flairWarped.nii.gz"
    source "$PROJECT_ROOT/src/modules/reporting.sh" 2>/dev/null || true   # _reporting_source_for_mask
    viz_preprocess_figures subj "$TEMP_TEST_DIR/bg.nii.gz" "$TEMP_TEST_DIR/after.nii.gz" "$TEMP_TEST_DIR/bg.nii.gz" >/dev/null 2>&1
    assert_file_exists "$R/visualizations/preprocess/subj_denoise.png" "preprocess: denoise before/after figure"
    assert_file_exists "$R/visualizations/preprocess/subj_n4.png"      "preprocess: N4 before/after figure"
    viz_brain_extraction_figures "$TEMP_TEST_DIR/bg.nii.gz" "$TEMP_TEST_DIR/mask.nii.gz" synthstrip >/dev/null 2>&1
    assert_file_exists "$R/visualizations/brain_extraction/bg_mask.png"                 "brain extraction: mask contour figure"
    assert_file_exists "$R/visualizations/brain_extraction/bg_mask_posterior_fossa.png" "brain extraction: posterior-fossa figure"
    viz_registration_stage_figures "$R" "$TEMP_TEST_DIR/bg.nii.gz" "$TEMP_TEST_DIR/after.nii.gz" "$TEMP_TEST_DIR/mask.nii.gz" >/dev/null 2>&1
    assert_file_exists "$R/visualizations/registration/flair_to_t1_checkerboard.png"            "registration: FLAIR->T1 checkerboard"
    assert_file_exists "$R/visualizations/registration/T2_SPACE_to_flairWarped_checkerboard.png" "registration: contrast-matched secondary checkerboard"
    viz_segmentation_stage_figures "$R" >/dev/null 2>&1
    assert_file_exists "$R/visualizations/segmentation/labels_jhu.png"            "segmentation: per-source label figure (LUT from provenance)"
    assert_file_exists "$R/visualizations/segmentation/pons_focus.png"            "segmentation: pons focus figure"
    assert_file_exists "$R/visualizations/segmentation/brainstem_subdivisions.png" "segmentation: gross + subdivisions figure"
    # detection stage: per-region work dirs + agreement maps
    pr="$R/per_region_analysis"; mkdir -p "$pr/freesurfer_pons_FLAIR_analysis/gmm_analysis" "$pr/agreement"
    cp "$TEMP_TEST_DIR/bg.nii.gz" "$pr/freesurfer_pons_FLAIR_analysis/pons_zscore.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$pr/freesurfer_pons_FLAIR_analysis/pons_resampled.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$pr/freesurfer_pons_FLAIR_analysis/pons_connectivity.nii.gz"
    printf 'THRESHOLD=2.5\nUPPER_MEAN=2.0\nUPPER_STD=0.5\nUPPER_WEIGHT=0.1\n' > "$pr/freesurfer_pons_FLAIR_analysis/gmm_analysis/pons_gmm_params.txt"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$pr/agreement/source_atlas_detect.nii.gz"
    cp "$TEMP_TEST_DIR/mask.nii.gz" "$pr/agreement/source_freesurfer_detect.nii.gz"
    viz_detection_stage_figures "$R" "$TEMP_TEST_DIR/bg.nii.gz" "$TEMP_TEST_DIR/mask.nii.gz" "$TEMP_TEST_DIR/mask.nii.gz" "$pr" >/dev/null 2>&1
    assert_file_exists "$R/visualizations/detection/lesion_union_agreement.png"   "detection: union + agreement figure"
    assert_file_exists "$R/visualizations/detection/lesion_by_source.png"         "detection: per-vote-unit figure"
    assert_file_exists "$R/visualizations/detection/region_freesurfer_pons_zscore.png" "detection: per-region z-score figure"
    assert_file_exists "$R/visualizations/detection/region_freesurfer_pons_hist.png"   "detection: per-region histogram with fit + threshold"
    VIZ_SEGMENTATION_ENABLED=false viz_segmentation_stage_figures "$R" >/dev/null 2>&1
    assert_exit_code 0 $? "stage figures honour their VIZ_<STAGE>_ENABLED gate"
    viz_gallery >/dev/null 2>&1
    assert_contains "$(cat "$R/visualizations/index.html")" "pons_focus.png" "gallery picks up the stage figures"

    # failure path: bad input -> WARNING + return 1, never a crash
    msg=$(viz_render overlay --bg "$TEMP_TEST_DIR/missing.nii.gz" --out "$RESULTS_DIR/x.png" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); rc=${PIPESTATUS[0]}
    assert_exit_code 1 "$rc" "bad input -> returns 1"
    assert_contains "$msg" "viz: overlay failed (non-fatal)" "…with a WARNING naming the sub-command"
else
    echo "  (python renderer unavailable — real-render tests skipped)"
fi

cleanup_test_environment
print_test_summary
