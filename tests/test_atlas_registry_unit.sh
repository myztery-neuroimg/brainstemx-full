#!/usr/bin/env bash
#
# test_atlas_registry_unit.sh - Unit tests for src/modules/atlas_registry.sh
# (registry-driven extra MNI atlases: JHU / XTRACT / AAN / LC / ...).
#
# Tests (FSL/ANTs mocked; no atlases needed):
#   - module load via multi_atlas.sh + include guard + exports
#   - registry accessors (_atlas_cfg / _atlas_enabled / source tags)
#   - parse_fsl_xml_lut on FSL atlas XML; LUT offset rules (Label=0, Probabilistic=1,
#     explicit override); atlas_lut_to_tsv subset + value = index + offset
#   - space handling: 2009c atlas is SKIPPED without the TemplateFlow transform and
#     converted when it is present
#   - prepare_registry_atlas: cache build, brainstem restriction requires HO
#   - run_registry_atlases end-to-end with fake transforms -> per-region masks,
#     subject-space dseg, provenance sidecar, subdivision aggregates, dilation
#   - probmap builder; prob4d / probdir builders (skipped when numpy/nibabel absent)
#   - analysis.sh / reporting.sh source-tag helpers honour MULTI_ATLAS_SOURCE_TAGS
#   - graceful degradation when atlases are missing
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

init_test_suite "atlas_registry.sh Unit Tests"
setup_test_environment

# ── Mocks ─────────────────────────────────────────────────────────────────────
create_mock_fslmaths >/dev/null 2>&1 || true
create_mock_fslstats >/dev/null 2>&1 || true
create_mock_fslinfo  >/dev/null 2>&1 || true
mock_dir="$TEMP_TEST_DIR/mock_bin"
# fslval: every image reports the FSL MNI152 1mm grid.
cat > "$mock_dir/fslval" <<'MOCK'
#!/usr/bin/env bash
case "$2" in
  dim1) echo 182 ;; dim2) echo 218 ;; dim3) echo 182 ;;
  pixdim1|pixdim2|pixdim3) echo 1.000000 ;;
  *) echo 1 ;;
esac
MOCK
# flirt / antsApplyTransforms: copy input to output.
cat > "$mock_dir/flirt" <<'MOCK'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do case "$1" in -in) in="$2"; shift;; -out) out="$2"; shift;; esac; shift; done
[ -n "$in" ] && [ -n "$out" ] && cp "$in" "$out"
exit 0
MOCK
cat > "$mock_dir/antsApplyTransforms" <<'MOCK'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do case "$1" in -i) in="$2"; shift;; -o) out="$2"; shift;; esac; shift; done
[ -n "$in" ] && [ -n "$out" ] && cp "$in" "$out"
exit 0
MOCK
chmod +x "$mock_dir"/*

# ── Fake FSL + atlas tree ─────────────────────────────────────────────────────
export FSLDIR="$TEMP_TEST_DIR/fsl"
export ATLAS_DIR="$FSLDIR/data/atlases"
export MULTI_ATLAS_CACHE_DIR="$ATLAS_DIR"
export RESULTS_DIR="$TEMP_TEST_DIR/results"
mkdir -p "$FSLDIR/data/standard" "$ATLAS_DIR/JHU" "$ATLAS_DIR/HarvardOxford" "$RESULTS_DIR"
create_fake_nifti "$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz"
create_fake_nifti "$ATLAS_DIR/JHU/JHU-ICBM-labels-1mm.nii.gz"
create_fake_nifti "$ATLAS_DIR/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1mm.nii.gz"
cat > "$ATLAS_DIR/JHU-labels.xml" <<'XML'
<?xml version="1.0" encoding="ISO-8859-1"?>
<atlas version="1.0">
  <header>
    <name>JHU ICBM-DTI-81 White-Matter Labels</name>
    <type>Label</type>
  </header>
  <data>
    <label index="0" x="98" y="107" z="71">Unclassified</label>
    <label index="1" x="94" y="63" z="52">Middle cerebellar peduncle</label>
    <label index="2" x="89" y="70" z="58">Pontine crossing tract (a part of MCP)</label>
    <label index="3" x="90" y="152" z="82">Genu of corpus callosum</label>
    <label index="7" x="82" y="94" z="66">Corticospinal tract R</label>
    <label index="8" x="98" y="94" z="66">Corticospinal tract L</label>
  </data>
</atlas>
XML
cat > "$ATLAS_DIR/XTRACT.xml" <<'XML'
<atlas version="1.0">
  <header><name>XTRACT HCP Probabilistic Tract Atlases</name><type>Probabilistic</type></header>
  <data>
    <label index="0" x="90" y="128" z="65">Anterior Commissure</label>
    <label index="15" x="116" y="104" z="106">Corticospinal Tract L</label>
    <label index="16" x="63" y="104" z="106">Corticospinal Tract R</label>
    <label index="35" x="90" y="107" z="34">Middle Cerebellar Peduncle</label>
  </data>
</atlas>
XML

# Registry config (mirrors config/default_config.sh defaults for jhu).
export MULTI_ATLAS_EXTRA="jhu xtract"
export MULTI_ATLAS_SOURCE_TAGS="bianciardi cit168 aal3 jhu xtract"
export USE_JHU=true ATLAS_JHU_REL=JHU ATLAS_JHU_TYPE=dseg ATLAS_JHU_IMAGE=JHU-ICBM-labels-1mm.nii.gz
export ATLAS_JHU_LUT=JHU-labels.xml ATLAS_JHU_SPACE=MNI152NLin6Asym ATLAS_JHU_LUT_OFFSET=0
export ATLAS_JHU_LABELS="1 2 7 8" ATLAS_JHU_RESTRICT=brainstem
export USE_XTRACT=false
export HO_SUB_MAXPROB_THR=thr25

load_environment_module
set +e
source "$PROJECT_ROOT/src/modules/multi_atlas.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. Module load + guard + exports"

assert_function_exists "prepare_registry_atlas"      "prepare_registry_atlas defined"
assert_function_exists "run_registry_atlases"        "run_registry_atlases defined"
assert_function_exists "parse_fsl_xml_lut"           "parse_fsl_xml_lut defined"
assert_function_exists "atlas_lut_to_tsv"            "atlas_lut_to_tsv defined"
assert_function_exists "atlas_registry_source_tags"  "atlas_registry_source_tags defined"
_before="$_ATLAS_REGISTRY_LOADED"
source "$PROJECT_ROOT/src/modules/atlas_registry.sh" 2>/dev/null || true
assert_equals "$_before" "$_ATLAS_REGISTRY_LOADED" "double-source is a no-op (guard holds)"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. Registry accessors"

assert_equals "JHU" "$(_atlas_cfg jhu REL)"                    "_atlas_cfg reads ATLAS_JHU_REL"
assert_equals "dflt" "$(_atlas_cfg nosuch REL dflt)"           "_atlas_cfg falls back to the default"
_atlas_enabled jhu;    assert_exit_code 0 $? "_atlas_enabled: USE_JHU=true"
_atlas_enabled xtract; assert_exit_code 1 $? "_atlas_enabled: USE_XTRACT=false"
assert_equals "bianciardi cit168 aal3 jhu xtract" "$(atlas_registry_source_tags)" "source tags = built-ins + registry keys"
assert_equals "$ATLAS_DIR/JHU/JHU-ICBM-labels-1mm.nii.gz" "$(_atlas_resolve_path jhu JHU-ICBM-labels-1mm.nii.gz)" "image resolves under the atlas root"
assert_equals "$ATLAS_DIR/JHU-labels.xml" "$(_atlas_resolve_path jhu JHU-labels.xml)" "LUT falls back to the atlases root (FSL XML layout)"
atlas_registry_present jhu; assert_exit_code 0 $? "atlas_registry_present: JHU on disk"
mkdir -p "$ATLAS_DIR/LC"; create_fake_nifti "$ATLAS_DIR/LC/LC_7T_prob_atlas_v1_something.nii.gz"
export ATLAS_LCG_REL=LC ATLAS_LCG_IMAGE="LC*prob*.nii*"
assert_equals "$ATLAS_DIR/LC/LC_7T_prob_atlas_v1_something.nii.gz" "$(_atlas_resolve_path lcg "LC*prob*.nii*")" "glob IMAGE pattern resolves to the on-disk file"
atlas_registry_present lcg; assert_exit_code 0 $? "atlas_registry_present: glob pattern present"
export ATLAS_LCG_IMAGE="NOPE*.nii*"
atlas_registry_present lcg; assert_exit_code 1 $? "atlas_registry_present: glob with no match -> absent"
atlas_registry_present xtract; assert_exit_code 1 $? "atlas_registry_present: XTRACT absent"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. LUT parsing + offsets"

xml_out=$(parse_fsl_xml_lut "$ATLAS_DIR/JHU-labels.xml")
assert_equals "1	Middle_cerebellar_peduncle" "$(echo "$xml_out" | sed -n '2p')" "XML label 1 -> Middle_cerebellar_peduncle (spaces -> _)"
assert_equals "2	Pontine_crossing_tract_a_part_of_MCP" "$(echo "$xml_out" | sed -n '3p')" "XML parentheses stripped"
assert_equals "6" "$(echo "$xml_out" | wc -l | tr -d ' ')" "XML: 6 labels parsed (index 0 included)"

assert_equals "0" "$(_atlas_lut_offset jhu "$ATLAS_DIR/JHU-labels.xml")"     "offset: explicit ATLAS_JHU_LUT_OFFSET=0"
ATLAS_JHU_LUT_OFFSET=auto
assert_equals "0" "$(_atlas_lut_offset jhu "$ATLAS_DIR/JHU-labels.xml")"     "offset auto: FSL <type>Label</type> -> 0"
assert_equals "1" "$(_atlas_lut_offset xtract "$ATLAS_DIR/XTRACT.xml")"     "offset auto: FSL <type>Probabilistic</type> -> 1"
ATLAS_XTRACT_LUT_OFFSET=0
assert_equals "0" "$(_atlas_lut_offset xtract "$ATLAS_DIR/XTRACT.xml")"     "offset: explicit override wins"
unset ATLAS_XTRACT_LUT_OFFSET
ATLAS_JHU_LUT_OFFSET=0

lut_tsv="$TEMP_TEST_DIR/jhu_lut.tsv"
atlas_lut_to_tsv jhu "$ATLAS_DIR/JHU-labels.xml" "$lut_tsv"
assert_exit_code 0 $? "atlas_lut_to_tsv succeeds"
assert_equals "4" "$(grep -vc '^#' "$lut_tsv")" "LUT subset (LABELS='1 2 7 8') -> 4 rows"
assert_contains "$(cat "$lut_tsv")" "7	Corticospinal_tract_R" "value == index for a Label atlas"
assert_not_contains "$(cat "$lut_tsv")" "Unclassified" "index 0 (Unclassified) dropped"

ATLAS_XTRACT_LABELS="15 35"
xt_tsv="$TEMP_TEST_DIR/xtract_lut.tsv"
atlas_lut_to_tsv xtract "$ATLAS_DIR/XTRACT.xml" "$xt_tsv"
assert_contains "$(cat "$xt_tsv")" "16	Corticospinal_Tract_L" "Probabilistic maxprob: value = index + 1 (15 -> 16)"
assert_contains "$(cat "$xt_tsv")" "36	Middle_Cerebellar_Peduncle" "Probabilistic maxprob: 35 -> 36"
assert_equals "2" "$(grep -vc '^#' "$xt_tsv")" "subset by index -> 2 rows"
ATLAS_XTRACT_LABELS="middle_cerebellar_peduncle"
atlas_lut_to_tsv xtract "$ATLAS_DIR/XTRACT.xml" "$xt_tsv"
assert_equals "1" "$(grep -vc '^#' "$xt_tsv")" "subset by (case-insensitive) name -> 1 row"
# FreeSurfer-style LUT (NextBrain MNI atlas): multi-word names + RGBA, regex selection
fslut="$TEMP_TEST_DIR/nextbrain_lut.txt"
printf '# NextBrain\n0 Unknown 0 0 0 0\n48 Left head of caudate 120 18 134 0\n201 Left pontine nuclei 255 0 0 0\n10201 Right pontine nuclei 255 0 0 0\n220 Left locus coeruleus 0 255 0 0\n' > "$fslut"
fs_rows=$(_atlas_lut_rows nbm "$fslut")
assert_contains "$fs_rows" "201	Left_pontine_nuclei" "FreeSurfer LUT auto-detected: words joined, RGBA dropped"
assert_contains "$fs_rows" "10201	Right_pontine_nuclei" "FreeSurfer LUT: right-hemisphere offset label kept"
export ATLAS_NBM_LABEL_REGEX="pontine|coeruleus"
nbm_tsv="$TEMP_TEST_DIR/nbm.tsv"; atlas_lut_to_tsv nbm "$fslut" "$nbm_tsv"
assert_equals "3" "$(grep -vc '^#' "$nbm_tsv")" "LABEL_REGEX selects the 3 brainstem rows (caudate excluded)"
unset ATLAS_NBM_LABEL_REGEX
# _lut_image_offset on the emitted TSV must be 0 (values are image values)
assert_equals "0" "$(_lut_image_offset "$xt_tsv")" "emitted TSV needs no further offset downstream"
unset ATLAS_XTRACT_LABELS

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. Template-space handling (NLin6 vs 2009c)"

cache="$TEMP_TEST_DIR/cache"; mkdir -p "$cache"
create_fake_nifti "$TEMP_TEST_DIR/atlas2009c.nii.gz"
export ATLAS_C09_SPACE=MNI152NLin2009cAsym
unset MNI_2009C_TO_NLIN6_XFM TEMPLATEFLOW_HOME
out=$(_atlas_normalise_space c09 "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$cache" true 2>/dev/null)
assert_exit_code 1 $? "2009c atlas without the TemplateFlow xfm is SKIPPED (returns 1)"
msg=$(_atlas_normalise_space c09 "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$cache" true 2>&1 >/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$msg" "SKIPPING 'c09'" "…with an explicit WARNING naming the missing transform"
export MNI_2009C_TO_NLIN6_XFM="$TEMP_TEST_DIR/tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5"
: > "$MNI_2009C_TO_NLIN6_XFM"
out=$(_atlas_normalise_space c09 "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$cache" true 2>/dev/null)
assert_exit_code 0 $? "2009c atlas WITH the xfm is converted (returns 0)"
assert_file_exists "$cache/atlas2009c_nlin6.nii.gz" "…producing the *_nlin6 cache product"
export ATLAS_N6_SPACE=MNI152NLin6Asym
out=$(_atlas_normalise_space n6 "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$cache" true 2>/dev/null)
assert_equals "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$out" "NLin6 atlas on the same grid passes through untouched"
export ATLAS_BAD_SPACE=Talairach
_atlas_normalise_space bad "$TEMP_TEST_DIR/atlas2009c.nii.gz" "$cache" true >/dev/null 2>&1
assert_exit_code 1 $? "unknown space -> skipped"
# Explicit ATLAS_<KEY>_XFM chain (e.g. Dahl 2022 LC meta-mask's own ANTs transforms)
create_fake_nifti "$TEMP_TEST_DIR/atlas_lin.nii.gz"
export ATLAS_LIN_SPACE=MNI152Lin ATLAS_LIN_XFM="$TEMP_TEST_DIR/lin_to_nlin6_0GenericAffine.mat $TEMP_TEST_DIR/lin_to_nlin6_1Warp.nii.gz"
_atlas_normalise_space lin "$TEMP_TEST_DIR/atlas_lin.nii.gz" "$cache" true >/dev/null 2>&1
assert_exit_code 1 $? "explicit XFM with a missing transform file -> skipped"
: > "$TEMP_TEST_DIR/lin_to_nlin6_0GenericAffine.mat"; create_fake_nifti "$TEMP_TEST_DIR/lin_to_nlin6_1Warp.nii.gz"
out=$(_atlas_normalise_space lin "$TEMP_TEST_DIR/atlas_lin.nii.gz" "$cache" true 2>/dev/null)
assert_exit_code 0 $? "explicit XFM chain applied (returns 0)"
assert_equals "$cache/atlas_lin_nlin6.nii.gz" "$out" "explicit XFM output cached as *_nlin6"
unset MNI_2009C_TO_NLIN6_XFM

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. prepare_registry_atlas (cache + brainstem restriction)"

prep=$(prepare_registry_atlas jhu 2>/dev/null)
assert_exit_code 0 $? "prepare_registry_atlas jhu succeeds"
mni_dseg="${prep%%	*}"; mni_lut="${prep#*	}"
assert_file_exists "$mni_dseg" "MNI dseg cached ($mni_dseg)"
assert_file_exists "$mni_lut"  "MNI LUT cached"
assert_equals "$ATLAS_DIR/JHU/derived/jhu_MNI_dseg.nii.gz" "$mni_dseg" "cache lives under <ATLAS_DIR>/JHU/derived"
assert_equals "4" "$(grep -vc '^#' "$mni_lut")" "cached LUT carries the 4 selected pontine labels"
assert_file_exists "$ATLAS_DIR/HarvardOxford/derived/brainstem_extent_thr25_1mm_dil1.nii.gz" "HO brainstem extent (dilated) derived for the restriction"
msg=$(prepare_registry_atlas jhu 2>&1 >/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$msg" "cache up to date" "second call is a cache hit"

# Restriction requested but HO absent -> skip.
mv "$ATLAS_DIR/HarvardOxford" "$ATLAS_DIR/HarvardOxford.off"
rm -rf "$ATLAS_DIR/JHU/derived"
prepare_registry_atlas jhu >/dev/null 2>&1
assert_exit_code 1 $? "brainstem restriction without Harvard-Oxford -> atlas skipped"
mv "$ATLAS_DIR/HarvardOxford.off" "$ATLAS_DIR/HarvardOxford"

# Read-only cache dir -> per-run fallback cache.
export MULTI_ATLAS_CACHE_DIR="$TEMP_TEST_DIR/ro_cache"; mkdir -p "$MULTI_ATLAS_CACHE_DIR"; chmod 555 "$MULTI_ATLAS_CACHE_DIR"
if [ "$(id -u)" -ne 0 ]; then
  assert_equals "$RESULTS_DIR/segmentation/multi_atlas/cache/jhu" "$(_atlas_cache_dir jhu)" "read-only cache root -> per-run fallback under RESULTS_DIR"
fi
chmod 755 "$MULTI_ATLAS_CACHE_DIR"; export MULTI_ATLAS_CACHE_DIR="$ATLAS_DIR"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "6. run_registry_atlases end-to-end (mocked warp/split)"

work="$RESULTS_DIR/segmentation/multi_atlas"; region_out="$RESULTS_DIR/segmentation/detailed_brainstem"; views="$work/views"
reg="$work/registration"; mkdir -p "$reg" "$region_out" "$views"
: > "$reg/mni_to_subject_0GenericAffine.mat"; create_fake_nifti "$reg/mni_to_subject_1Warp.nii.gz"
create_fake_nifti "$TEMP_TEST_DIR/subject_T1.nii.gz"
run_registry_atlases "$TEMP_TEST_DIR/subject_T1.nii.gz" "$reg/mni_to_subject_" "$work" "$region_out" "$views" >/dev/null 2>&1
assert_exit_code 0 $? "run_registry_atlases returns 0 when an atlas produced masks"
assert_file_exists "$work/jhu_in_subject.nii.gz" "subject-space dseg written (<key>_in_subject)"
assert_file_exists "$region_out/jhu_middle_cerebellar_peduncle_label1.nii.gz" "per-region mask jhu_<name>_label<v>"
assert_file_exists "$region_out/jhu_corticospinal_tract_l_label8.nii.gz" "per-region mask keeps the image value (8)"
assert_file_exists "$region_out/jhu_region_volumes.tsv" "per-region volume sidecar"
assert_file_exists "$work/jhu_provenance.tsv" "provenance sidecar"
assert_contains "$(cat "$work/jhu_provenance.tsv")" "restrict	brainstem" "provenance records the restriction"
assert_file_exists "$views/view_jhu_nuclei.sh" "fsleyes view script emitted"
n_masks=$(ls "$region_out"/jhu_*_label*.nii.gz 2>/dev/null | wc -l | tr -d ' ')
assert_equals "4" "$n_masks" "exactly the 4 selected labels became masks"

# Subdivision aggregation + dilation on a probdir-style key (aan-like).
export MULTI_ATLAS_EXTRA="aanx"; export USE_AANX=true
export ATLAS_AANX_SUBDIV="lc=pons dr=midbrain pontine=pons"; export ATLAS_AANX_DILATE=1
aan_lut="$TEMP_TEST_DIR/aanx_lut.txt"; printf '# value\tname\n1\tLC_l\n2\tLC_r\n3\tDR\n4\tPAG\n5\tLeft_pontine_nuclei\n' > "$aan_lut"
create_fake_nifti "$work/aanx_in_subject.nii.gz"
split_dseg_to_region_masks "$work/aanx_in_subject.nii.gz" "$aan_lut" "$region_out" "aanx" >/dev/null 2>&1
_atlas_dilate_masks aanx "$region_out" 1 >/dev/null 2>&1
_atlas_aggregate_subdivisions aanx "$work/aanx_in_subject.nii.gz" "$aan_lut" "$region_out" >/dev/null 2>&1
assert_file_exists "$region_out/aanx_pons.nii.gz"       "SUBDIV: aanx_pons aggregate"
assert_file_exists "$region_out/aanx_left_pons.nii.gz"  "SUBDIV: laterality (_l / left_ prefix) -> aanx_left_pons"
assert_file_exists "$region_out/aanx_left_pontine_nuclei_label5.nii.gz" "left_-prefixed nucleus mask split"
assert_file_exists "$region_out/aanx_right_pons.nii.gz" "SUBDIV: laterality (_r) -> aanx_right_pons"
assert_file_exists "$region_out/aanx_midbrain.nii.gz"   "SUBDIV: DR -> aanx_midbrain"
assert_file_not_exists "$region_out/aanx_medulla.nii.gz" "SUBDIV: unmapped PAG creates no medulla aggregate"
assert_file_exists "$region_out/aanx_lc_l_label1_core.nii.gz" "DILATE: undilated core kept as *_core"
export MULTI_ATLAS_EXTRA="jhu xtract"

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "7. Probabilistic builders"

pm_dseg="$TEMP_TEST_DIR/lc_dseg.nii.gz"; pm_lut="$TEMP_TEST_DIR/lc_lut.txt"
create_fake_nifti "$TEMP_TEST_DIR/lc_prob.nii.gz"
build_probmap_dseg "$TEMP_TEST_DIR/lc_prob.nii.gz" "$pm_dseg" "$pm_lut" 0.25 lc >/dev/null 2>&1
assert_exit_code 0 $? "build_probmap_dseg succeeds"
assert_contains "$(cat "$pm_lut")" "1	lc" "probmap LUT: single label 1 named after the key"

if py=$(_atlas_python 2>/dev/null); then
    # Synthetic 4D atlas: 2 volumes on a 6x6x6 grid, plus a probdir of 2 maps.
    # shellcheck disable=SC2086
    $py - "$TEMP_TEST_DIR" <<'PYEOF'
import sys, os, numpy as np, nibabel as nib
d = sys.argv[1]
a = np.zeros((6,6,6,2), dtype=np.float32)
a[0:3, :, :, 0] = 0.9; a[3:6, :, :, 1] = 0.6; a[2, :, :, 1] = 0.95   # overlap at x=2 (p=0.95 > 0.9): vol1 wins
nib.save(nib.Nifti1Image(a, np.eye(4)), os.path.join(d, 'p4d.nii.gz'))
os.makedirs(os.path.join(d, 'pdir'), exist_ok=True)
m1 = np.zeros((6,6,6), dtype=np.float32); m1[:, 0:2, :] = 0.8
m2 = np.zeros((6,6,6), dtype=np.float32); m2[:, 0:2, :] = 0.5     # fully overlapped -> 0 owned
nib.save(nib.Nifti1Image(m1, np.eye(4)), os.path.join(d, 'pdir', 'NucA.nii.gz'))
nib.save(nib.Nifti1Image(m2, np.eye(4)), os.path.join(d, 'pdir', 'NucB.nii.gz'))
PYEOF
    rows="$TEMP_TEST_DIR/p4d_rows.txt"; printf '0\tTractZero\n1\tTractOne\n' > "$rows"
    build_prob4d_dseg "$TEMP_TEST_DIR/p4d.nii.gz" "$rows" "$TEMP_TEST_DIR/p4d_dseg.nii.gz" "$TEMP_TEST_DIR/p4d_lut.txt" 0.5 >/dev/null 2>&1
    assert_exit_code 0 $? "build_prob4d_dseg succeeds"
    assert_contains "$(cat "$TEMP_TEST_DIR/p4d_lut.txt")" "1	TractZero" "prob4d LUT: value = volume index + 1"
    # shellcheck disable=SC2086
    counts=$($py -c "import nibabel as nib, numpy as np; d=np.asanyarray(nib.load('$TEMP_TEST_DIR/p4d_dseg.nii.gz').dataobj); print(int((d==1).sum()), int((d==2).sum()))")
    assert_equals "72 144" "$counts" "prob4d argmax: vol0 keeps x=0,1 (72 voxels); vol1 wins the x=2 overlap + x=3..5 (144)"
    build_prob4d_dseg "$TEMP_TEST_DIR/p4d.nii.gz" "$rows" "$TEMP_TEST_DIR/p4d_sub.nii.gz" "$TEMP_TEST_DIR/p4d_sub_lut.txt" 0.5 1 >/dev/null 2>&1
    assert_equals "1" "$(grep -vc '^#' "$TEMP_TEST_DIR/p4d_sub_lut.txt")" "prob4d subset keeps only the requested volume"
    build_probdir_dseg "$TEMP_TEST_DIR/pdir" "$TEMP_TEST_DIR/pdir_dseg.nii.gz" "$TEMP_TEST_DIR/pdir_lut.txt" 0.25 >/dev/null 2>&1
    assert_exit_code 0 $? "build_probdir_dseg succeeds"
    assert_contains "$(cat "$TEMP_TEST_DIR/pdir_lut.txt")" "2	NucB	0" "probdir: fully overlapped nucleus owns 0 voxels"
    assert_file_exists "$TEMP_TEST_DIR/overlay/NucB.nii.gz" "probdir: zero-owned nucleus kept as an overlay map"
else
    echo "  (numpy/nibabel unavailable — prob4d/probdir builder tests skipped)"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "8. Downstream source-tag helpers"

source "$PROJECT_ROOT/src/modules/analysis.sh" 2>/dev/null || true
if declare -f _region_source_from_path >/dev/null 2>&1; then
    assert_equals "jhu" "$(_region_source_from_path "$region_out/jhu_middle_cerebellar_peduncle_label1.nii.gz")" "analysis: jhu_* tagged 'jhu'"
    assert_equals "nextbrain" "$(_region_source_from_path "$region_out/nextbrain_pontine_nuclei_label12.nii.gz")" "analysis: nextbrain_* tagged 'nextbrain' (tool tag)"
    assert_equals "bianciardi" "$(_region_source_from_path "$region_out/bianciardi_LC_label5.nii.gz")" "analysis: built-in tags unchanged"
    assert_equals "freesurfer" "$(_region_source_from_path "$region_out/subj_pons.nii.gz")" "analysis: untagged detailed_brainstem parcel -> freesurfer"
    assert_contains "$(_analysis_source_tags)" "xtract" "analysis: source tags include registry keys"
    unset CONSENSUS_VOTE_BY CONSENSUS_SOURCE_FAMILIES
    assert_equals "atlas" "$(_analysis_consensus_key jhu)"             "consensus: jhu votes as the 'atlas' family"
    assert_equals "atlas" "$(_analysis_consensus_key bianciardi)"      "consensus: bianciardi votes as 'atlas'"
    assert_equals "freesurfer" "$(_analysis_consensus_key nextbrain)"  "consensus: nextbrain votes with freesurfer"
    assert_equals "harvard_oxford" "$(_analysis_consensus_key harvard_oxford)" "consensus: HO is its own family"
    assert_equals "mystery" "$(_analysis_consensus_key mystery)"       "consensus: unknown source votes as itself"
    assert_equals "jhu" "$(CONSENSUS_VOTE_BY=source _analysis_consensus_key jhu)" "consensus: CONSENSUS_VOTE_BY=source keeps per-source votes"
fi
source "$PROJECT_ROOT/src/modules/reporting.sh" 2>/dev/null || true
if declare -f _reporting_source_for_mask >/dev/null 2>&1; then
    assert_equals "jhu" "$(_reporting_source_for_mask jhu_corticospinal_tract_l_label8.nii.gz)" "reporting: jhu_* -> jhu"
    assert_equals "freesurfer" "$(_reporting_source_for_mask subj_midbrain.nii.gz)" "reporting: default -> freesurfer"
fi

# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "9. Graceful degradation"

export ATLAS_DIR="$TEMP_TEST_DIR/empty_atlases"; mkdir -p "$ATLAS_DIR"; export MULTI_ATLAS_CACHE_DIR="$ATLAS_DIR"
run_registry_atlases "$TEMP_TEST_DIR/subject_T1.nii.gz" "$reg/mni_to_subject_" "$work" "$region_out" "$views" >/dev/null 2>&1
assert_exit_code 1 $? "no atlas on disk -> run_registry_atlases returns 1 (nothing produced), no crash"
export USE_JHU=false USE_XTRACT=false
run_registry_atlases "$TEMP_TEST_DIR/subject_T1.nii.gz" "$reg/mni_to_subject_" "$work" "$region_out" "$views" >/dev/null 2>&1
assert_exit_code 1 $? "all keys disabled -> returns 1, no crash"
export MULTI_ATLAS_EXTRA=""
run_registry_atlases "$TEMP_TEST_DIR/subject_T1.nii.gz" "$reg/mni_to_subject_" "$work" "$region_out" "$views" >/dev/null 2>&1
assert_exit_code 1 $? "empty registry -> returns 1, no crash"

cleanup_test_environment
print_test_summary
