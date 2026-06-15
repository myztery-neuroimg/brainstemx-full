#!/usr/bin/env bash
#
# test_dependency_report_unit.sh - Unit tests for the comprehensive
# optional/feature-gated dependency inventory in src/modules/environment.sh.
#
# Tests:
#   - _dep_probe_cmd          (present / absent)
#   - _dep_timeout            (returns command status; bounds runtime)
#   - _dep_probe_image        (docker image / .sif on disk / absent)
#   - _dep_report             (matrix line + enabled-but-missing WARNING)
#   - check_optional_dependencies
#       * groups REQUIRED vs OPTIONAL
#       * reports present/absent per dependency (mocked)
#       * cross-references config toggles → "enabled but missing → SKIPPED"
#       * is NON-fatal (always returns 0)
#       * prints the inventory summary (counts + skip list)
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
init_test_suite "Dependency Report Unit Tests"
setup_test_environment

# Source the module under test (stderr suppressed; it emits log lines on load).
load_environment_module

# ══════════════════════════════════════════════════════════════════════════════
# 1. _dep_probe_cmd
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "1. _dep_probe_cmd"

# bash is always present
probe="$(_dep_probe_cmd bash)"
assert_contains "$probe" "present|" \
    "_dep_probe_cmd reports 'present|<path>' for an existing command"

probe="$(_dep_probe_cmd this_command_does_not_exist_xyz)"
assert_equals "absent" "$probe" \
    "_dep_probe_cmd reports 'absent' for a missing command"

# ══════════════════════════════════════════════════════════════════════════════
# 2. _dep_timeout
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "2. _dep_timeout"

set +e
_dep_timeout 5 true
ec=$?
set -e
assert_exit_code 0 "$ec" \
    "_dep_timeout passes through a successful command's exit status"

set +e
_dep_timeout 5 false
ec=$?
set -e
assert_exit_code 1 "$ec" \
    "_dep_timeout passes through a failing command's exit status"

# A command that would run forever must be bounded (must not hang the suite).
start=$(date +%s)
set +e
_dep_timeout 1 sleep 30 >/dev/null 2>&1
set -e
end=$(date +%s)
elapsed=$((end - start))
if [[ "$elapsed" -le 10 ]]; then
    echo -e "${GREEN}  PASS${NC}: _dep_timeout bounds a long-running command (${elapsed}s)"
    PASS_COUNT=$((PASS_COUNT + 1)); TEST_COUNT=$((TEST_COUNT + 1))
else
    echo -e "${RED}  FAIL${NC}: _dep_timeout did NOT bound a long-running command (${elapsed}s)"
    FAIL_COUNT=$((FAIL_COUNT + 1)); TEST_COUNT=$((TEST_COUNT + 1))
    FAILED_TESTS+=("_dep_timeout bounds a long-running command")
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. _dep_probe_image
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "3. _dep_probe_image"

# A non-existent docker image with no runtime that can satisfy it → absent.
# (We can't assume docker is installed; with no .sif and a bogus image it must
#  fall through to 'absent' without hanging — short internal timeout.)
probe="$(_dep_probe_image "nonexistent/image:does-not-exist-xyz" "")"
assert_equals "absent" "$probe" \
    "_dep_probe_image reports 'absent' for an unknown image / no .sif"

# A .sif file on disk + a (mocked) apptainer runtime → present|sif:<path>.
fake_sif="$TEMP_TEST_DIR/fake_model.sif"
touch "$fake_sif"
create_mock_command "apptainer" 0 "apptainer version 1.0"
probe="$(_dep_probe_image "" "$fake_sif")"
assert_contains "$probe" "present|sif:$fake_sif" \
    "_dep_probe_image reports a present .sif when an apptainer runtime exists"

# ══════════════════════════════════════════════════════════════════════════════
# 4. _dep_report (matrix line + enabled-but-missing WARNING)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "4. _dep_report"

# NOTE: _dep_report mutates module-scope counters/arrays, so it must run in the
# CURRENT shell (NOT a $(...) subshell). Capture its output to a temp file.
_dep_out="$TEMP_TEST_DIR/dep_report.out"

# Present REQ → SUCCESS line, increments _DEP_PRESENT.
_DEP_PRESENT=0; _DEP_ABSENT=0; _DEP_SKIPPED_FEATURES=()
_dep_report "toolA" "REQ" "present|/usr/bin/toolA" "core thing" >"$_dep_out" 2>&1
out="$(cat "$_dep_out")"
assert_contains "$out" "toolA | REQ | present (/usr/bin/toolA) | gates: core thing" \
    "_dep_report formats a present REQ matrix line"
assert_equals "1" "$_DEP_PRESENT" "_dep_report increments _DEP_PRESENT on present"
assert_equals "0" "${#_DEP_SKIPPED_FEATURES[@]}" "_dep_report adds no skip entry on present"

# Absent OPT that is ENABLED → WARNING + skip-list entry.
_DEP_PRESENT=0; _DEP_ABSENT=0; _DEP_SKIPPED_FEATURES=()
_dep_report "toolB" "OPT" "absent" "Fancy Feature" "true" >"$_dep_out" 2>&1
out="$(cat "$_dep_out")"
assert_contains "$out" "toolB | OPT | absent | gates: Fancy Feature" \
    "_dep_report formats an absent OPT matrix line"
assert_contains "$out" "Fancy Feature is ENABLED but toolB not found" \
    "_dep_report warns when an ENABLED optional feature's dep is absent"
assert_equals "1" "$_DEP_ABSENT" "_dep_report increments _DEP_ABSENT on absent"
assert_equals "1" "${#_DEP_SKIPPED_FEATURES[@]}" "_dep_report records the skipped feature"

# Absent OPT that is NOT enabled → no warning, no skip entry.
_DEP_PRESENT=0; _DEP_ABSENT=0; _DEP_SKIPPED_FEATURES=()
_dep_report "toolC" "OPT" "absent" "Disabled Feature" "false" >"$_dep_out" 2>&1
out="$(cat "$_dep_out")"
assert_not_contains "$out" "is ENABLED but toolC not found" \
    "_dep_report does NOT warn when the optional feature is disabled"
assert_equals "0" "${#_DEP_SKIPPED_FEATURES[@]}" \
    "_dep_report records no skip entry for a disabled feature"

# ══════════════════════════════════════════════════════════════════════════════
# 5. check_optional_dependencies (end-to-end, fully mocked PATH)
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5. check_optional_dependencies"

# Build a deterministic PATH containing ONLY our mocks + the bare essentials so
# present/absent is controlled by the test, not the host.
mock_dir="$TEMP_TEST_DIR/dep_mock_bin"
mkdir -p "$mock_dir"
for tool in \
    fslmaths flirt fast bet robustfov cluster fslstats fslinfo \
    antsRegistration antsApplyTransforms N4BiasFieldCorrection DenoiseImage \
    Atropos ThresholdImage ImageMath ResampleImage antsRegistrationSyN.sh \
    dcm2niix c3d uv \
    recon-all segmentBS.sh mri_synthseg ; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/$tool"
    chmod +x "$mock_dir/$tool"
done
# Keep coreutils/bash available so the function body runs.
essentials_dir="$(dirname "$(command -v bash)")"
saved_path="$PATH"
export PATH="$mock_dir:$essentials_dir:/usr/bin:/bin"

# Make the FreeSurfer / atlas / FSL / container probes hermetic by clearing any
# host environment the developer's machine may have set, so present/absent is
# controlled by the test (mocked PATH) and not by the host.
unset FREESURFER_HOME FS_LICENSE FSLDIR \
      SEGCSVD_DOCKER_IMAGE SEGCSVD_CONTAINER_IMAGE LSTAI_DOCKER_IMAGE \
      SHIVA_WMH_CONTAINER_IMAGE MARS_WMH_DOCKER_IMAGE MARS_WMH_SIF \
      MARS_BRAINSTEM_DOCKER_IMAGE MARS_BRAINSTEM_SIF 2>/dev/null || true

# Config: enable a feature whose dep is deliberately ABSENT (mri_WMHsynthseg is
# not mocked) and disable everything container/python-based so the test is
# hermetic and fast.
export BRAINSTEM_SEGMENTATION_METHOD="all"
export SEG_RUN_FREESURFER="true"
export SEG_RUN_MULTI_ATLAS="false"
export SEG_RUN_SYNTHSEG="true"
export USE_SYNTHSR="false"
export PROCESS_DWI="false"
export WMH_BIANCA_ENABLED="false"
export WMH_LSTAI_ENABLED="false"
export WMH_SAMSEG_ENABLED="false"
export WMH_SYNTHSEG_ENABLED="true"     # enabled, but mri_WMHsynthseg is ABSENT
export WMH_SEGCSVD_ENABLED="false"
export WMH_SHIVA_ENABLED="false"
export WMH_MARS_ENABLED="false"
export MARS_BRAINSTEM_ENABLED="false"
export BRAINSTEM_AANSEG_ENABLED="false"

set +e
out="$(check_optional_dependencies 2>&1)"
ec=$?
set -e
export PATH="$saved_path"

# Strip ANSI colour codes for matching.
out_plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"

assert_exit_code 0 "$ec" \
    "check_optional_dependencies is NON-fatal (returns 0)"

assert_contains "$out_plain" "Optional / Feature-Gated Dependency Inventory" \
    "prints the inventory header"
assert_contains "$out_plain" "Core (REQUIRED)" \
    "prints the REQUIRED group header"
assert_contains "$out_plain" "FreeSurfer (OPTIONAL)" \
    "prints the OPTIONAL FreeSurfer group header"
assert_contains "$out_plain" "Container runtimes & images (OPTIONAL)" \
    "prints the container group header"

# Mocked-present core tool shows present.
assert_contains "$out_plain" "fslmaths | REQ | present" \
    "reports a mocked core tool (fslmaths) as present"
# Mocked-present optional FS tool shows present.
assert_contains "$out_plain" "recon-all | OPT | present" \
    "reports a mocked optional tool (recon-all) as present"
# Non-mocked optional tool shows absent.
assert_contains "$out_plain" "mri_WMHsynthseg | OPT | absent" \
    "reports a non-mocked optional tool (mri_WMHsynthseg) as absent"

# Enabled-but-missing feature must produce a WARNING + appear in the skip list.
assert_contains "$out_plain" "WMH-SynthSeg is ENABLED but mri_WMHsynthseg not found" \
    "warns that an ENABLED feature with a missing dep will be skipped"
assert_contains "$out_plain" "Optional features that WILL be SKIPPED" \
    "prints the skip-list summary header"
assert_contains "$out_plain" "WMH-SynthSeg (missing mri_WMHsynthseg)" \
    "lists the skipped feature in the summary"

# Summary line with counts is present.
assert_contains "$out_plain" "Dependencies present:" \
    "prints the present/absent counts summary"

# ══════════════════════════════════════════════════════════════════════════════
# 5b. Any-of back-end gating (SHIVA: antspynet OR container)
#     Enabling SHIVA with ONE back-end present must NOT warn it will be skipped.
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "5b. Any-of back-end gating"

# Same hermetic core PATH; clear host env again for determinism.
unset FREESURFER_HOME FS_LICENSE FSLDIR \
      SEGCSVD_DOCKER_IMAGE SEGCSVD_CONTAINER_IMAGE LSTAI_DOCKER_IMAGE \
      MARS_WMH_DOCKER_IMAGE MARS_WMH_SIF \
      MARS_BRAINSTEM_DOCKER_IMAGE MARS_BRAINSTEM_SIF 2>/dev/null || true

# Provide a SHiVAi .sif on disk + a mocked apptainer runtime so the CONTAINER
# back-end is present, while antspynet (no uv project here) stays ABSENT.
shiva_sif="$TEMP_TEST_DIR/shiva_model.sif"
touch "$shiva_sif"
export SHIVA_WMH_CONTAINER_IMAGE="$shiva_sif"
# mock_dir already has 'uv' (returns 0), so antspynet import "succeeds" trivially;
# point uv at a stub that FAILS the import so antspynet is genuinely absent.
printf '#!/usr/bin/env bash\nexit 1\n' > "$mock_dir/uv"
chmod +x "$mock_dir/uv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/apptainer"
chmod +x "$mock_dir/apptainer"

export PATH="$mock_dir:$essentials_dir:/usr/bin:/bin"
export WMH_SHIVA_ENABLED="true"      # SHIVA on; container present, antspynet absent
export WMH_SYNTHSEG_ENABLED="false"  # silence the unrelated SynthSeg skip
export WMH_MARS_ENABLED="false"
export WMH_LSTAI_ENABLED="false"

set +e
out2="$(check_optional_dependencies 2>&1)"
set -e
export PATH="$saved_path"
out2_plain="$(printf '%s' "$out2" | sed 's/\x1b\[[0-9;]*m//g')"

assert_contains "$out2_plain" "SHIVA-WMH back-end | OPT | present" \
    "any-of: SHIVA back-end reports present when only the container exists"
assert_not_contains "$out2_plain" "SHIVA-WMH is ENABLED but" \
    "any-of: enabled SHIVA does NOT warn-skip when one back-end is present"
assert_not_contains "$out2_plain" "SHIVA-WMH (missing" \
    "any-of: SHIVA is not listed in the skip summary when a back-end exists"

# Restore the plain 'uv' mock for any later groups.
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/uv"
chmod +x "$mock_dir/uv"

# ══════════════════════════════════════════════════════════════════════════════
# 6. Function availability
# ══════════════════════════════════════════════════════════════════════════════
begin_test_group "6. Function Availability"

assert_function_exists "check_optional_dependencies" "check_optional_dependencies defined"
assert_function_exists "_dep_probe_cmd"              "_dep_probe_cmd defined"
assert_function_exists "_dep_probe_pymodule"         "_dep_probe_pymodule defined"
assert_function_exists "_dep_probe_image"            "_dep_probe_image defined"
assert_function_exists "_dep_report"                 "_dep_report defined"
assert_function_exists "_dep_timeout"                "_dep_timeout defined"

# ══════════════════════════════════════════════════════════════════════════════
# Cleanup & Summary
# ══════════════════════════════════════════════════════════════════════════════
cleanup_test_environment
print_test_summary
