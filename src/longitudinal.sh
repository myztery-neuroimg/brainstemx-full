#!/usr/bin/env bash
#
# longitudinal.sh - Longitudinal multi-session orchestrator for BrainStemX-Full
#
# Standalone driver for within-subject longitudinal analysis.  Reads an
# operator-supplied session map, identifies the anchor session (whose
# non-contrast T1 defines the common anatomical space), then runs
# src/pipeline.sh for each session with the Units A/B/C variables set so
# every session lands in the shared anatomical space.
#
# Usage:
#   LONGITUDINAL_SESSIONS=/path/to/session_map.txt bash src/longitudinal.sh [--help] [--dry-run]
#
# CLI flags:
#   --help        Print this usage and exit.
#   --dry-run     Parse the session map and print the execution plan
#                 (anchor + ordered per-session invocations) WITHOUT
#                 running the heavy per-session pipeline.
#
# LONGITUDINAL_MODE gate:
#   When LONGITUDINAL_MODE=false (the default set in config/default_config.sh)
#   and this script is NOT invoked directly, single-study pipeline runs are
#   completely unaffected.  Set LONGITUDINAL_MODE=true or invoke this script
#   explicitly to enter the longitudinal path.
#
# ── Session map format ────────────────────────────────────────────────────────
#
# One session per line; blank lines and lines beginning with '#' are ignored.
# Each line has three whitespace-separated fields:
#
#   <session_label>   <input_or_extracted_dir>   <role>
#
#   session_label  : short identifier used for the per-session output directory
#                    and the run manifest (e.g. baseline, followup1, tp02).
#                    Use only letters, digits, underscores, and hyphens.
#   input_dir      : absolute path to the DICOM input directory (or an
#                    already-extracted NIfTI directory) for this session.
#                    Must be operator-supplied; NEVER commit real paths.
#   role           : exactly one of:
#                      anchor    - the session whose non-contrast T1 defines
#                                  the common anatomical space; runs first;
#                                  exactly ONE anchor is required.
#                      timepoint - a follow-up session; runs after the anchor.
#
# Generic example (place in a gitignored operator config file — NEVER commit):
#
#   # session_map.txt — operator-supplied; gitignored
#   #
#   # label          input_dir                        role
#   baseline         /data/subject01/session_baseline  anchor
#   followup1        /data/subject01/session_followup1 timepoint
#   followup2        /data/subject01/session_followup2 timepoint
#
# ── Recon-once intent ─────────────────────────────────────────────────────────
#
# FreeSurfer recon-all runs on the anchor T1 first.  For each timepoint the
# orchestrator sets:
#   FREESURFER_T1_INPUT=<anchor T1 path>
#   ANATOMICAL_REFERENCE_T1=<anchor T1 path>
# so the per-session pipeline reuses the anchor's anatomical labels rather
# than re-running the multi-hour recon-all independently.  Full label
# propagation across timepoints (via FreeSurfer longitudinal -base) is
# deferred to Unit E; this hook establishes the correct input path so the
# per-session pipeline degrades to the HO gross mask rather than launching
# a new recon on a non-anchor timepoint.
#
# ── Outputs ───────────────────────────────────────────────────────────────────
#
#   <LONGITUDINAL_OUTPUT_DIR>/
#     longitudinal_manifest.json   — sessions, roles, common-space anchor,
#                                    per-session results dirs, exit codes
#     logs/longitudinal.log        — orchestrator log
#
# ── Environment variables ─────────────────────────────────────────────────────
#
#   LONGITUDINAL_SESSIONS      : (required) path to the session map file.
#   LONGITUDINAL_OUTPUT_DIR    : root output dir (default: ../longitudinal_results).
#   LONGITUDINAL_COMMON_SPACE  : common-space strategy (default: anchor).
#                                Currently only "anchor" is supported (use the
#                                anchor T1 directly).  A future v2 will add
#                                "template" (antsMultivariateTemplateConstruction2).
#   LONGITUDINAL_MODE          : master gate; set by config/default_config.sh
#                                to false; explicit invocation of this script
#                                ignores the gate and always runs.
#   PIPELINE_SH                : path to the per-session pipeline script
#                                (default: <this_script_dir>/pipeline.sh).
#
# ─────────────────────────────────────────────────────────────────────────────

set -e -u -o pipefail

# ── Resolve script location ───────────────────────────────────────────────────

LONGITUDINAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_SH="${PIPELINE_SH:-${LONGITUDINAL_SCRIPT_DIR}/pipeline.sh}"

# ── Minimal logging (no environment.sh dependency at this level) ──────────────
# The orchestrator is a standalone driver; it cannot source environment.sh
# before the per-session pipeline loads it.  Use simple wrappers here.

_log_ts() { date "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "????-??-??T??:??:??"; }

_log() {
  local level="$1"; shift
  echo "[${level}] $(_log_ts) longitudinal.sh: $*" >&2
  if [ -n "${_LONG_LOG_FILE:-}" ]; then
    echo "[${level}] $(_log_ts) longitudinal.sh: $*" >> "${_LONG_LOG_FILE}" 2>/dev/null || true
  fi
}

log_info()    { _log "INFO"    "$@"; }
log_warning() { _log "WARNING" "$@"; }
log_error()   { _log "ERROR"   "$@"; }

# ── Help ─────────────────────────────────────────────────────────────────────

show_longitudinal_help() {
  cat <<'EOF'
Usage: LONGITUDINAL_SESSIONS=<map_file> bash src/longitudinal.sh [--help] [--dry-run]

BrainStemX-Full longitudinal multi-session orchestrator (Unit D).

Reads an operator-supplied session map file, identifies the anchor session
(whose non-contrast T1 is the common-space anatomical anchor), runs the
per-session pipeline with ANATOMICAL_REFERENCE_T1 + WITHIN_SUBJECT_REGISTRATION
+ PREFER_EXTERNAL_NONCONTRAST_T1 so every session lands in the same anatomical
space, and writes a run manifest.

Options:
  --help       Show this help and exit.
  --dry-run    Parse the session map and print the execution plan without
               running the pipeline.

Required environment variables:
  LONGITUDINAL_SESSIONS      Path to the session map file (one session per line).

Optional environment variables:
  LONGITUDINAL_OUTPUT_DIR    Root output directory (default: ../longitudinal_results).
  LONGITUDINAL_COMMON_SPACE  Common-space strategy: "anchor" (default).
  PIPELINE_SH                Path to the per-session pipeline.sh.

Session map format (one session per line; # comments and blanks ignored):
  <label>  <input_dir>  <role>
  role must be "anchor" (exactly one) or "timepoint".

Example session map (operator-supplied, gitignored — NEVER committed):
  # label          input_dir                          role
  baseline         /data/subject01/session_baseline   anchor
  followup1        /data/subject01/session_followup1  timepoint
  followup2        /data/subject01/session_followup2  timepoint
EOF
}

# ── Parse CLI flags ───────────────────────────────────────────────────────────

DRY_RUN=false

for _arg in "$@"; do
  case "$_arg" in
    -h|--help)
      show_longitudinal_help
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      log_error "Unknown argument: $_arg"
      show_longitudinal_help
      exit 1
      ;;
  esac
done
unset _arg

# ── Validate config ───────────────────────────────────────────────────────────

LONGITUDINAL_OUTPUT_DIR="${LONGITUDINAL_OUTPUT_DIR:-../longitudinal_results}"
LONGITUDINAL_COMMON_SPACE="${LONGITUDINAL_COMMON_SPACE:-anchor}"
LONGITUDINAL_SESSIONS="${LONGITUDINAL_SESSIONS:-}"

if [ -z "${LONGITUDINAL_SESSIONS}" ]; then
  log_error "LONGITUDINAL_SESSIONS is not set. Export the path to a session map file."
  show_longitudinal_help
  exit 1
fi

if [ ! -f "${LONGITUDINAL_SESSIONS}" ]; then
  log_error "Session map file not found: ${LONGITUDINAL_SESSIONS}"
  exit 1
fi

if [ "${LONGITUDINAL_COMMON_SPACE}" != "anchor" ]; then
  log_error "LONGITUDINAL_COMMON_SPACE='${LONGITUDINAL_COMMON_SPACE}' is not supported. Only 'anchor' is implemented in Unit D."
  exit 1
fi

# ── Set up output directory + log ─────────────────────────────────────────────

mkdir -p "${LONGITUDINAL_OUTPUT_DIR}/logs"
_LONG_LOG_FILE="${LONGITUDINAL_OUTPUT_DIR}/logs/longitudinal.log"
# Truncate (new run); ignore write errors on dry-run
: > "${_LONG_LOG_FILE}" 2>/dev/null || _LONG_LOG_FILE=""

log_info "Longitudinal orchestrator starting."
log_info "Session map: ${LONGITUDINAL_SESSIONS}"
log_info "Output dir:  ${LONGITUDINAL_OUTPUT_DIR}"
log_info "Common space: ${LONGITUDINAL_COMMON_SPACE}"
log_info "Dry-run: ${DRY_RUN}"

# ── Parse session map ─────────────────────────────────────────────────────────
# Arrays: parallel indexed lists of labels, input dirs, and roles.

declare -a _session_labels=()
declare -a _session_dirs=()
declare -a _session_roles=()

_line_num=0
while IFS= read -r _line || [ -n "${_line}" ]; do
  _line_num=$(( _line_num + 1 ))
  # Strip leading/trailing whitespace
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line%"${_line##*[![:space:]]}"}"
  # Skip blank lines and comment lines
  [ -z "${_line}" ] && continue
  case "${_line}" in \#*) continue ;; esac

  # Split into up to three fields (excess tokens become part of the 3rd field)
  read -r _label _dir _role _extra <<< "${_line}" || true

  # Validate field count
  if [ -z "${_label:-}" ] || [ -z "${_dir:-}" ] || [ -z "${_role:-}" ]; then
    log_error "Session map line ${_line_num}: expected 3 fields (label dir role), got: '${_line}'"
    exit 1
  fi
  if [ -n "${_extra:-}" ]; then
    log_warning "Session map line ${_line_num}: extra tokens after role ignored: '${_extra}'"
  fi

  # Validate role
  case "${_role}" in
    anchor|timepoint) ;;
    *)
      log_error "Session map line ${_line_num}: invalid role '${_role}' (must be 'anchor' or 'timepoint')"
      exit 1
      ;;
  esac

  # Validate label (letters, digits, underscores, hyphens only)
  if ! printf '%s' "${_label}" | grep -qE '^[A-Za-z0-9_-]+$'; then
    log_error "Session map line ${_line_num}: invalid label '${_label}' (use only letters, digits, underscores, hyphens)"
    exit 1
  fi

  _session_labels+=("${_label}")
  _session_dirs+=("${_dir}")
  _session_roles+=("${_role}")

done < "${LONGITUDINAL_SESSIONS}"
unset _line _line_num _label _dir _role _extra

if [ "${#_session_labels[@]}" -eq 0 ]; then
  log_error "Session map '${LONGITUDINAL_SESSIONS}' contains no valid session entries."
  exit 1
fi

log_info "Parsed ${#_session_labels[@]} session(s) from map."

# ── Resolve anchor session ────────────────────────────────────────────────────

_anchor_label=""
_anchor_dir=""
_anchor_index=-1
_anchor_count=0

for _i in "${!_session_roles[@]}"; do
  if [ "${_session_roles[${_i}]}" = "anchor" ]; then
    _anchor_count=$(( _anchor_count + 1 ))
    _anchor_label="${_session_labels[${_i}]}"
    _anchor_dir="${_session_dirs[${_i}]}"
    _anchor_index="${_i}"
  fi
done
unset _i

if [ "${_anchor_count}" -eq 0 ]; then
  log_error "No 'anchor' session found in the session map. Exactly one session must have role=anchor."
  exit 1
fi

if [ "${_anchor_count}" -gt 1 ]; then
  log_error "Multiple 'anchor' sessions found (${_anchor_count}). Exactly one session must have role=anchor."
  exit 1
fi

log_info "Anchor session: '${_anchor_label}' from ${_anchor_dir}"

# Validate anchor input dir exists (warn-only in dry-run)
if [ ! -d "${_anchor_dir}" ]; then
  if [ "${DRY_RUN}" = "true" ]; then
    log_warning "Anchor input dir does not exist (dry-run, continuing): ${_anchor_dir}"
  else
    log_error "Anchor input directory not found: ${_anchor_dir}"
    exit 1
  fi
fi

# ── Build ordered execution list: anchor first, then timepoints in map order ──

declare -a _exec_labels=()
declare -a _exec_dirs=()
declare -a _exec_roles=()

# Anchor first
_exec_labels+=("${_anchor_label}")
_exec_dirs+=("${_anchor_dir}")
_exec_roles+=("anchor")

# Remaining sessions in map order (skip anchor)
for _i in "${!_session_labels[@]}"; do
  if [ "${_i}" -ne "${_anchor_index}" ]; then
    _exec_labels+=("${_session_labels[${_i}]}")
    _exec_dirs+=("${_session_dirs[${_i}]}")
    _exec_roles+=("${_session_roles[${_i}]}")
  fi
done
unset _i

# ── Execution plan printout ───────────────────────────────────────────────────

_total="${#_exec_labels[@]}"

log_info "Execution plan — ${_total} session(s) in order:"
for _i in "${!_exec_labels[@]}"; do
  _plan_num=$(( _i + 1 ))
  log_info "  [${_plan_num}/${_total}] label=${_exec_labels[${_i}]}  role=${_exec_roles[${_i}]}  dir=${_exec_dirs[${_i}]}"
done
unset _i _plan_num

log_info "Common-space anchor: '${_anchor_label}' (${LONGITUDINAL_COMMON_SPACE} strategy)"
log_info "Anchor T1 will be resolved after anchor session runs (per-session RESULTS_DIR/bias_corrected/)."
log_info "Recon-once: FREESURFER_T1_INPUT + ANATOMICAL_REFERENCE_T1 set to anchor T1 for all timepoints."

if [ "${DRY_RUN}" = "true" ]; then
  log_info "Dry-run complete — no pipeline sessions were executed."
  exit 0
fi

# ── Validate per-session pipeline exists ──────────────────────────────────────

if [ ! -f "${PIPELINE_SH}" ]; then
  log_error "Per-session pipeline not found: ${PIPELINE_SH}"
  exit 1
fi

# ── Run sessions ──────────────────────────────────────────────────────────────
# The anchor runs first.  After it completes we discover its T1 path and export
# it for all subsequent timepoints.

_anchor_t1_path=""     # set after the anchor session completes
declare -A _session_exit_codes

_run_session() {
  local label="$1"
  local input_dir="$2"
  local role="$3"
  local session_out="${LONGITUDINAL_OUTPUT_DIR}/${label}"

  log_info "────────────────────────────────────────────────────────────"
  log_info "Starting session '${label}' (role=${role})"
  log_info "  input: ${input_dir}"
  log_info "  output: ${session_out}"

  mkdir -p "${session_out}"

  # Build the per-session environment.
  # Units A/B/C variables are always exported so the per-session pipeline uses
  # within-subject registration presets and borrows the anchor T1 when needed.
  local -x WITHIN_SUBJECT_REGISTRATION="true"
  local -x PREFER_EXTERNAL_NONCONTRAST_T1="true"

  if [ "${role}" = "anchor" ]; then
    # Anchor: run with whatever T1 is present in the study.
    # ANATOMICAL_REFERENCE_T1 is intentionally left as-is from the caller
    # environment (empty by default); the per-session pipeline selects the
    # in-study T1 normally.  FREESURFER_T1_INPUT is also left to auto-detect
    # so recon-all uses the best raw T1 from this study.
    log_info "  (anchor: using in-study T1; no borrowed reference)"
  else
    # Timepoint: borrow the anchor T1 as the anatomical reference.
    # This implements Unit A (external anatomical T1 reference) and the
    # recon-once intent (FREESURFER_T1_INPUT points at the anchor T1 so
    # the per-session pipeline reuses that anatomy rather than re-running
    # multi-hour recon-all from scratch).
    if [ -n "${_anchor_t1_path}" ] && [ -f "${_anchor_t1_path}" ]; then
      local -x ANATOMICAL_REFERENCE_T1="${_anchor_t1_path}"
      local -x ANATOMICAL_REFERENCE_LABEL="longitudinal_anchor_${_anchor_label}"
      local -x FREESURFER_T1_INPUT="${_anchor_t1_path}"
      log_info "  ANATOMICAL_REFERENCE_T1=${_anchor_t1_path}"
      log_info "  FREESURFER_T1_INPUT=${_anchor_t1_path}"
    else
      log_warning "  Anchor T1 not resolved yet (path empty or missing) — ANATOMICAL_REFERENCE_T1 will not be set for this timepoint."
    fi
  fi

  local pipeline_exit=0
  bash "${PIPELINE_SH}" \
    -i "${input_dir}" \
    -o "${session_out}" \
    -s "${label}" \
    || pipeline_exit=$?

  if [ "${pipeline_exit}" -eq 0 ]; then
    log_info "Session '${label}' completed successfully."
  else
    log_warning "Session '${label}' finished with exit code ${pipeline_exit}. Continuing."
  fi

  return "${pipeline_exit}"
}

_discover_anchor_t1() {
  # After the anchor session runs, locate the bias-corrected T1 (the best
  # full-head T1 for recon-all reuse).  The per-session pipeline writes
  # bias-corrected images under <RESULTS_DIR>/bias_corrected/.
  local anchor_out="${LONGITUDINAL_OUTPUT_DIR}/${_anchor_label}"
  local bc_dir="${anchor_out}/bias_corrected"

  local t1_candidate
  # Prefer the N4-corrected T1 (filename contains n4 or N4Corrected)
  t1_candidate="$(find "${bc_dir}" -maxdepth 1 -name '*_n4*.nii.gz' \
      -o -name '*N4Corrected*.nii.gz' 2>/dev/null | grep -i 't1\|mprage\|spgr' | head -1 || true)"

  if [ -z "${t1_candidate}" ]; then
    # Broader fallback: any T1-like .nii.gz in bias_corrected
    t1_candidate="$(find "${bc_dir}" -maxdepth 1 -name '*.nii.gz' 2>/dev/null \
        | grep -i 't1\|mprage\|spgr' | head -1 || true)"
  fi

  if [ -z "${t1_candidate}" ]; then
    # Last resort: any .nii.gz in bias_corrected
    t1_candidate="$(find "${bc_dir}" -maxdepth 1 -name '*.nii.gz' 2>/dev/null | head -1 || true)"
  fi

  echo "${t1_candidate}"
}

# Track outcomes for the manifest
declare -a _exec_exit_codes=()

for _i in "${!_exec_labels[@]}"; do
  _lbl="${_exec_labels[${_i}]}"
  _dir="${_exec_dirs[${_i}]}"
  _role="${_exec_roles[${_i}]}"

  _exit_code=0
  _run_session "${_lbl}" "${_dir}" "${_role}" || _exit_code=$?
  _exec_exit_codes+=("${_exit_code}")

  # After the anchor completes, discover its T1 path
  if [ "${_role}" = "anchor" ] && [ "${_exit_code}" -eq 0 ]; then
    _anchor_t1_path="$(_discover_anchor_t1)"
    if [ -n "${_anchor_t1_path}" ]; then
      log_info "Anchor T1 resolved: ${_anchor_t1_path}"
    else
      log_warning "Could not discover anchor T1 under ${LONGITUDINAL_OUTPUT_DIR}/${_anchor_label}/bias_corrected/."
      log_warning "Timepoints will proceed without a borrowed anatomical reference."
    fi
  fi
done
unset _i _lbl _dir _role _exit_code

# ── Write longitudinal manifest ───────────────────────────────────────────────

_manifest="${LONGITUDINAL_OUTPUT_DIR}/longitudinal_manifest.json"
log_info "Writing run manifest: ${_manifest}"

{
  echo "{"
  echo "  \"longitudinal_common_space\": \"${LONGITUDINAL_COMMON_SPACE}\","
  echo "  \"anchor_label\": \"${_anchor_label}\","
  echo "  \"anchor_input_dir\": \"${_anchor_dir}\","
  echo "  \"anchor_t1_path\": \"${_anchor_t1_path:-}\","
  echo "  \"session_map_file\": \"${LONGITUDINAL_SESSIONS}\","
  echo "  \"longitudinal_output_dir\": \"${LONGITUDINAL_OUTPUT_DIR}\","
  echo "  \"sessions\": ["
  local_total="${#_exec_labels[@]}"
  for _i in "${!_exec_labels[@]}"; do
    local_label="${_exec_labels[${_i}]}"
    local_role="${_exec_roles[${_i}]}"
    local_dir="${_exec_dirs[${_i}]}"
    local_out="${LONGITUDINAL_OUTPUT_DIR}/${local_label}"
    local_exit="${_exec_exit_codes[${_i}]:-unknown}"
    local_comma=""
    if [ "$(( _i + 1 ))" -lt "${local_total}" ]; then
      local_comma=","
    fi
    echo "    {"
    echo "      \"label\": \"${local_label}\","
    echo "      \"role\": \"${local_role}\","
    echo "      \"input_dir\": \"${local_dir}\","
    echo "      \"results_dir\": \"${local_out}\","
    echo "      \"exit_code\": ${local_exit}"
    echo "    }${local_comma}"
  done
  echo "  ]"
  echo "}"
} > "${_manifest}"
unset _i local_label local_role local_dir local_out local_exit local_comma local_total

log_info "────────────────────────────────────────────────────────────"
log_info "Longitudinal run complete."

# ── Unit E: longitudinal change analysis ──────────────────────────────────────
# Run after the session loop completes and the manifest is written.  Non-fatal:
# a failure logs a warning and the orchestrator continues to the summary.

LONGITUDINAL_CHANGE_ENABLED="${LONGITUDINAL_CHANGE_ENABLED:-true}"

_change_reports_dir="${LONGITUDINAL_OUTPUT_DIR}/reports"
_change_script="${LONGITUDINAL_SCRIPT_DIR}/modules/longitudinal_change.py"

if [ "${LONGITUDINAL_CHANGE_ENABLED}" = "true" ]; then
  # Count successful sessions from the exit-code array
  _n_succeeded=0
  for _ec in "${_exec_exit_codes[@]}"; do
    if [ "${_ec}" -eq 0 ]; then
      _n_succeeded=$(( _n_succeeded + 1 ))
    fi
  done
  unset _ec

  if [ "${_n_succeeded}" -ge 2 ]; then
    log_info "Running Unit E longitudinal change analysis (${_n_succeeded} successful session(s))."
    if [ -f "${_change_script}" ]; then
      mkdir -p "${_change_reports_dir}"
      if uv run python "${_change_script}" \
            --manifest "${_manifest}" \
            --output   "${_change_reports_dir}" 2>&1 | while IFS= read -r _line; do
              log_info "  [change] ${_line}"
            done; then
        log_info "Longitudinal change report written to: ${_change_reports_dir}"
      else
        log_warning "Longitudinal change analysis failed (non-fatal) — see log above."
      fi
    else
      log_warning "longitudinal_change.py not found at '${_change_script}' — skipping Unit E."
    fi
  else
    log_info "Skipping longitudinal change analysis: fewer than 2 sessions succeeded (${_n_succeeded})."
  fi
else
  log_info "Longitudinal change analysis disabled (LONGITUDINAL_CHANGE_ENABLED=false)."
fi
unset _n_succeeded _change_reports_dir _change_script

# ── Summary report ────────────────────────────────────────────────────────────

_total_sessions="${#_exec_labels[@]}"
_failed=0
for _i in "${!_exec_exit_codes[@]}"; do
  if [ "${_exec_exit_codes[${_i}]}" -ne 0 ]; then
    _failed=$(( _failed + 1 ))
    log_warning "  FAILED: '${_exec_labels[${_i}]}' (exit ${_exec_exit_codes[${_i}]})"
  fi
done
unset _i

_passed=$(( _total_sessions - _failed ))
log_info "Sessions: ${_total_sessions} total, ${_passed} succeeded, ${_failed} failed."
log_info "Manifest written to: ${_manifest}"
log_info "Per-session results under: ${LONGITUDINAL_OUTPUT_DIR}/"

if [ "${_failed}" -gt 0 ]; then
  log_error "One or more sessions failed — review the warnings above and re-run."
  exit 1
fi

exit 0
