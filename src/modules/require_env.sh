#!/usr/bin/env bash
#
# require_env.sh - Lightweight guard to verify pipeline environment is initialized
#
# Source this at the top of any module instead of environment.sh.
# During pipeline execution this is a fast no-op (environment already loaded).
# For standalone debugging, source environment.sh first:
#   source src/modules/environment.sh && bash src/modules/your_module.sh
#

# Fast path: environment already loaded
if [ -n "${_ENVIRONMENT_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi

# Environment not loaded - fail fast with clear instructions
echo "[ERROR] Pipeline environment not initialized." >&2
echo "  Source environment.sh first, e.g.:" >&2
echo "    source src/modules/environment.sh" >&2
return 1 2>/dev/null || exit 1
