# Bugs Found During Unit Test Development

These issues were discovered while building unit tests for environment.sh,
pipeline.sh, and import.sh. File each as a separate GitHub issue at:
https://github.com/myztery-neuroimg/brainstemx-full/issues/new

---

## Issue 1: validate_nifti() file size check broken on Linux (stat -f portability)

**Labels:** bug, environment

### Description
`validate_nifti()` in `src/modules/environment.sh` uses `stat -f "%z"` to get file size. This is macOS syntax. On Linux, `-f` means `--file-system` and **silently succeeds** (exit 0) but outputs filesystem info instead of the file size.

Because `stat -f "%z"` returns exit 0 on Linux, the `||` fallback to `stat --format="%s"` never runs. The `file_size` variable gets multiline filesystem garbage, the `-lt` comparison fails silently, and **size validation is completely skipped**.

### Location
`src/modules/environment.sh`, line ~933:
```bash
local file_size=$(stat -f "%z" "$file" 2>/dev/null || stat --format="%s" "$file" 2>/dev/null)
```

### Impact
- Undersized or truncated NIfTI files pass validation on Linux
- Pipeline may proceed with corrupt/incomplete data without warning

### Suggested Fix
```bash
local file_size
file_size=$(stat -c "%s" "$file" 2>/dev/null || stat -f "%z" "$file" 2>/dev/null || echo "0")
```
Try GNU `stat -c` first (Linux), then macOS `stat -f` as fallback.

### Evidence
`tests/test_environment_unit.sh` documents this with a platform-aware skip annotation.

---

## Issue 2: validate_step() in pipeline.sh has unreachable code

**Labels:** bug, pipeline

### Description
`validate_step()` in `src/pipeline.sh` has `return 0` as its very first statement, making the entire function body unreachable. The step validation logic (checking output files, calling `validate_module_execution`) never executes.

### Location
`src/pipeline.sh`, line ~280:
```bash
validate_step() {
  return 0           # <-- Everything below is dead code
  local step_name="$1"
  local output_files="$2"
  local module="$3"
  # ... validation logic never runs
}
```

### Impact
- No step validation occurs between pipeline stages
- Corrupt or missing intermediate files are silently accepted
- Pipeline may fail late in processing instead of catching problems early

### Suggested Fix
Remove the `return 0` line (or wrap it in a feature flag if intentionally disabled).

---

## Issue 3: QUALITY_PRESET default misspelled as "MEIDUM" in pipeline.sh

**Labels:** bug, pipeline

### Description
In `pipeline.sh`'s `parse_arguments()`, the default `QUALITY_PRESET` is misspelled as `"MEIDUM"` instead of `"MEDIUM"`.

### Location
`src/pipeline.sh`, line ~174:
```bash
QUALITY_PRESET="MEIDUM"  # Should be "MEDIUM"
```

### Impact
If no `-q` flag is passed, the quality preset is set to the invalid value "MEIDUM", which may cause unexpected behavior or fall through to a default case elsewhere.

Note: The `parse_arguments()` in `environment.sh` has the correct spelling "MEDIUM".

---

## Issue 4: Duplicate parse_arguments() functions (environment.sh vs pipeline.sh)

**Labels:** bug, architecture

### Description
Two separate `parse_arguments()` functions exist:
1. **`src/modules/environment.sh`** (line ~1212): Simpler version without `--start-stage`, `--compare-import-options`, verbosity flags, or `PIPELINE_MODE`
2. **`src/pipeline.sh`** (line ~168): Full version with all pipeline-specific flags

Since `pipeline.sh` sources `environment.sh` first, and then defines its own `parse_arguments()`, the environment.sh version is silently overridden. However, if any other script sources only `environment.sh` and calls `parse_arguments()`, it gets the limited version with different defaults.

### Impact
- `environment.sh` version defaults `SRC_DIR` to `"../DiCOM"`, pipeline.sh version defaults to `"../DICOM"` (capitalization difference)
- environment.sh version defaults `QUALITY_PRESET` to `"MEDIUM"`, pipeline.sh version defaults to `"MEIDUM"` (typo)
- Any script sourcing only environment.sh gets a `parse_arguments()` that doesn't support `--start-stage`, `--verbose`, `--quiet`, `--debug`, or `--compare-import-options`
- Confusing maintenance surface - fixes to one copy don't propagate to the other

### Suggested Fix
Remove `parse_arguments()` from `environment.sh` and keep only the full version in `pipeline.sh`, or extract it to a shared location.

---

## Issue 5: import_validate_dicom_files_new_2 and import_deduplicate_identical_files are disabled

**Labels:** documentation, tech-debt

### Description
Two functions in `src/modules/import.sh` have `return 0` as their first executable statement, making them no-ops:

1. **`import_validate_dicom_files_new_2()`** (line ~558): Returns 0 immediately, skipping all DICOM validation
2. **`import_deduplicate_identical_files()`** (line ~72): Also effectively disabled (dedup code is commented out for safety)

Both functions are still called in the pipeline and exported, creating the impression that validation/dedup is happening when it is not.

### Impact
- No DICOM file validation occurs during import
- Dead code adds confusion for maintainers
- Function exports and calls add overhead for no benefit

### Suggested Fix
Either:
1. Remove the functions and their call sites if they're permanently disabled
2. Add clear documentation/logging that they are intentionally disabled and why
3. Fix them to work correctly if the functionality is actually needed
