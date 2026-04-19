#!/bin/bash
# /kubedoop/bin/entrypoint.sh -- Universal container entrypoint
#
# Note: Uses set -uo pipefail WITHOUT -e.
# Signal-aware scripts must not use set -e because trap handlers
# and set -e interact unpredictably. All error handling is explicit.
#
# Lifecycle logic (cleanup, signal handling) is in lib/signal.sh.
# This script is a thin orchestrator: config → load → pre-script → lifecycle → exit.
set -uo pipefail

# Paths are locked at build time — not overridable via environment variables
readonly KUBEDOOP_HOME="/kubedoop"
readonly KUBEDOOP_MOUNT_DIR="${KUBEDOOP_HOME}/mount"
readonly KUBEDOOP_RUN_DIR="${KUBEDOOP_HOME}/run"

# Graceful shutdown timeout (seconds). Validated and locked at startup.
KUBEDOOP_KILL_TIMEOUT="${KUBEDOOP_KILL_TIMEOUT:-30}"
if ! [[ "$KUBEDOOP_KILL_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "[kubedoop] [ERROR] KUBEDOOP_KILL_TIMEOUT must be a positive integer >= 1, got: $KUBEDOOP_KILL_TIMEOUT" >&2
    exit 1
fi
readonly KUBEDOOP_KILL_TIMEOUT

# Ensure run directory exists with correct permissions
mkdir -p "${KUBEDOOP_RUN_DIR}"

# Load common libraries.
# Libraries load in glob sort order. If a library depends on another,
# it must document this requirement (e.g., signal.sh depends on log.sh and run-phase.sh).
for lib in "${KUBEDOOP_HOME}/lib/"*.sh; do
    if [[ -f "$lib" ]]; then
        # shellcheck source=/dev/null
        source "$lib"
    fi
done

log_info "Entrypoint starting: $*"

# --- Phase 1: Runtime pre-script hooks (auto-discovered from mount) ---
# Note: pre-script failure prevents main process startup (fail-fast).
# Operators must test injected scripts in non-production environments first.
if ! run_phase "pre-script" "${KUBEDOOP_MOUNT_DIR}/pre-script"; then
    log_error "Pre-script phase failed, aborting startup"
    exit 1
fi

# --- Phase 2: Start main process and manage lifecycle ---
if [[ $# -eq 0 ]]; then
    log_error "No command specified"
    exit 1
fi

run_lifecycle "$@"
exit $EXIT_CODE
