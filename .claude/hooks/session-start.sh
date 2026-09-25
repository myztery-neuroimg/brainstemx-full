#!/usr/bin/env bash
# SessionStart hook for Claude Code on the web (agentic environment bootstrap).
#
# Purpose: make the repo's CI checks runnable inside a fresh cloud session:
#   - `uv sync`                      -> Python 3.12.8 venv (pytest, reporting tests)
#   - `uv tool install shellcheck-py` -> shellcheck for `shellcheck --severity=error`
#   - a dummy $FSLDIR/etc/fslconf/fsl.sh so `bash src/pipeline.sh --help` (the CI
#     smoke test) can run without a real FSL install (mirrors validate-scripts.yml)
#
# Idempotent, non-interactive, synchronous (dependencies are guaranteed present
# before the session starts). Runs ONLY in remote (web) sessions; local sessions
# keep the developer's own environment untouched.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() { printf '[session-start] %s\n' "$*"; }

# --- Python env (uv) --------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
  log "uv sync (Python 3.12.8 venv from uv.lock)"
  uv sync --frozen >/dev/null 2>&1 || uv sync >/dev/null 2>&1 || log "WARNING: uv sync failed (pytest may be unavailable)"
else
  log "WARNING: uv not found; skipping Python env setup"
fi

# --- shellcheck (CI lint) ---------------------------------------------------
if ! command -v shellcheck >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    log "installing shellcheck via 'uv tool install shellcheck-py'"
    uv tool install shellcheck-py >/dev/null 2>&1 || log "WARNING: shellcheck install failed"
  fi
fi
# uv tool binaries land in ~/.local/bin; persist it on PATH for the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -d "$HOME/.local/bin" ]; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

# --- dummy FSL config for the pipeline --help smoke test --------------------
# pipeline.sh sources $FSLDIR/etc/fslconf/fsl.sh under `set -e`; CI provides a
# stub. Only set it when no real FSL is configured.
if [ -z "${FSLDIR:-}" ] || [ ! -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
  fake_fsl="/tmp/fake_fsl"
  mkdir -p "${fake_fsl}/etc/fslconf"
  [ -f "${fake_fsl}/etc/fslconf/fsl.sh" ] || printf '# dummy FSL config for smoke tests\n' > "${fake_fsl}/etc/fslconf/fsl.sh"
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export FSLDIR=\"${fake_fsl}\"" >> "$CLAUDE_ENV_FILE"
  fi
  log "FSLDIR stub at ${fake_fsl} (no real FSL in this container)"
fi

log "done: uv env + shellcheck ready; run the checks listed in CLAUDE.md"
