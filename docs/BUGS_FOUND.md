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

## Issue 4: Unguarded re-sourcing causes repeated side effects, variable clobbering, and potential pipeline termination

**Labels:** bug, architecture, high-priority

### Description

`environment.sh` and `default_config.sh` are sourced **multiple times** during a
single pipeline run. Neither file has an include guard. `default_config.sh` has
severe side effects that re-execute on every source, including an `exit 1` that
can kill the entire pipeline mid-run.

### The re-sourcing chain

During a normal `pipeline.sh` execution:

```
pipeline.sh
├─ L81:  source environment.sh                           ← 1st
├─ L82-98: source 16 modules, including:
│   ├─ segmentation.sh
│   │   ├─ L4: source default_config.sh                  ← SIDE EFFECTS (1st)
│   │   ├─ L5: source environment.sh                     ← 2nd
│   │   └─ L8: source hierarchical_joint_fusion.sh
│   │       ├─ L5: source default_config.sh              ← SIDE EFFECTS (2nd)
│   │       └─ L6: source environment.sh                 ← 3rd
│   ├─ segmentation_transformation_extraction.sh
│   │   ├─ L2: source environment.sh                     ← 4th
│   │   └─ L3: source default_config.sh                  ← SIDE EFFECTS (3rd)
│   ├─ reference_space_selection.sh
│   │   └─ L18: source environment.sh                    ← 5th
│   └─ enhanced_registration_validation.sh
│       └─ L21-30: conditional source environment.sh     ← 6th (maybe)
└─ L309 (in run_pipeline): load_config default_config.sh ← SIDE EFFECTS (4th)
```

**Result: `environment.sh` sourced 5-6 times, `default_config.sh` sourced 3-4 times.**

### default_config.sh side effects on EVERY source

| Line(s) | Side Effect | Severity |
|---------|-------------|----------|
| 43 | `cpuinfo \| grep -i count` — runs external process | Medium: overhead + potential inconsistency |
| 109-136 | CPU-based branching **resets** `QUALITY_PRESET`, `ANTS_THREADS`, `ANTS_MEMORY_LIMIT`, all threading vars | **High: clobbers values set by parse_arguments or -q flag** |
| 25, 62, 67 | `RESULTS_DIR` and `SRC_DIR` overwritten with hardcoded defaults | **High: clobbers parse_arguments -o/-i values** |
| 26-27 | `mkdir -p "$RESULTS_DIR"` and `mkdir -p "$EXTRACT_DIR"` | Low: idempotent |
| 38, 41, 49, 56 | `log_message`/`log_formatted` called at top level | **Crash if sourced before environment.sh** (segmentation.sh L4) |
| 48, 65 | `PATH="$PATH:${ANTS_BIN}"` appended | Low: PATH accumulates duplicates |
| 138 | `echo "QUALITY_PRESET: ..." >&2` | Low: output noise |
| **207-209** | **`exit 1` if `FSLDIR` unset** | **CATASTROPHIC: kills entire pipeline** |

### Sourcing order problem

Several modules source `default_config.sh` **before** `environment.sh`:

```bash
# segmentation.sh
source "config/default_config.sh"     # L4 — calls log_message() which doesn't exist yet!
source "src/modules/environment.sh"   # L5

# hierarchical_joint_fusion.sh
source ./config/default_config.sh     # L5 — same problem
source ./src/modules/environment.sh   # L6
```

`default_config.sh` calls `log_message` and `log_formatted` at the top level
(lines 38, 41, 49, 56). If `environment.sh` hasn't been sourced yet, these
functions are undefined and the source fails or produces errors.

### environment.sh re-sourcing effects

While mostly harmless (function re-definitions), re-sourcing `environment.sh`
also:

- **Overwrites `parse_arguments()`**: environment.sh defines a simpler version
  (line ~1212) missing `--start-stage`, `--verbose`, `--debug`,
  `--compare-import-options`. After pipeline.sh defines its full version (L168),
  any subsequent re-source of environment.sh replaces it with the limited one.
- **Re-exports `RESULTS_DIR` default** (line 510): `export RESULTS_DIR="${RESULTS_DIR:-../mri_results}"` — safe if already set, but adds fragility.
- **Re-runs `set -e -u -o pipefail`** (line 495-497).

### The duplicate `parse_arguments` problem

Two separate `parse_arguments()` functions exist with divergent behavior:

| | `environment.sh` (L1212) | `pipeline.sh` (L168) |
|--|---|---|
| `SRC_DIR` default | `../DiCOM` | `../DICOM` (different case) |
| `QUALITY_PRESET` default | `MEDIUM` | `MEIDUM` (typo, see Bug #3) |
| `--start-stage` | Not supported | Supported |
| `--verbose/--quiet/--debug` | Not supported | Supported |
| `--compare-import-options` | Not supported | Supported |

Since modules re-source environment.sh after pipeline.sh defines its version,
the environment.sh version silently wins in the function namespace.

### Variable clobbering timeline

```
1. parse_arguments sets: RESULTS_DIR="/custom/output" QUALITY_PRESET="HIGH"
2. segmentation.sh sourced → default_config.sh executes:
   - L67: RESULTS_DIR="../mri_results"    ← CLOBBERED
   - L101: QUALITY_PRESET="HIGH"          ← overwritten
   - L109-136: QUALITY_PRESET reset based on cpuinfo → maybe "MEDIUM" ← CLOBBERED AGAIN
3. hierarchical_joint_fusion.sh sourced → default_config.sh executes again:
   - Same clobbering repeats
4. load_config in run_pipeline → default_config.sh executes again:
   - Same clobbering repeats
```

### `DICOM_PRIMARY_PATTERN` defined twice in same file

`default_config.sh` defines this variable twice with different values:
```bash
L14:  export DICOM_PRIMARY_PATTERN='Image"*"'   # Quoted glob — won't match
L242: export DICOM_PRIMARY_PATTERN=I*            # Unquoted — matches I* at source time
```

The second definition (L242) wins but expands `I*` at source time against the
current working directory, producing unpredictable results.

### Impact Summary

1. **Pipeline can terminate mid-run** if FSLDIR becomes unset during re-source
2. **User-supplied arguments are silently overwritten** (-o, -q, etc.)
3. **Quality preset can change mid-pipeline** based on CPU count re-evaluation
4. **Sourcing modules before environment.sh causes undefined function calls**
5. **parse_arguments regresses** from full version to limited version
6. **cpuinfo runs 3-4 times** unnecessarily

### Suggested Fix

1. **Add include guards** to both files:
   ```bash
   # Top of environment.sh
   [[ -n "${_ENVIRONMENT_SH_LOADED:-}" ]] && return 0
   _ENVIRONMENT_SH_LOADED=1

   # Top of default_config.sh
   [[ -n "${_DEFAULT_CONFIG_LOADED:-}" ]] && return 0
   _DEFAULT_CONFIG_LOADED=1
   ```

2. **Remove redundant `source` statements** from modules that are already
   sourced by pipeline.sh before they're loaded (segmentation.sh,
   hierarchical_joint_fusion.sh, segmentation_transformation_extraction.sh,
   reference_space_selection.sh).

3. **Move side effects out of default_config.sh** — the `exit 1` for FSLDIR,
   `mkdir -p` calls, and `cpuinfo` execution should be in initialization
   functions, not at file scope.

4. **Remove `parse_arguments()` from environment.sh** — keep only the full
   version in pipeline.sh.

5. **Fix the duplicate `DICOM_PRIMARY_PATTERN`** — remove L14 or L242 and
   quote the glob properly.

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
