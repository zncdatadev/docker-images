#!/bin/bash
# /kubedoop/bin/entrypoint.sh -- Universal container entrypoint
#
# Note: Uses set -uo pipefail WITHOUT -e.
# Signal-aware scripts must not use set -e because trap handlers
# and set -e interact unpredictably. All error handling is explicit.
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
# Note: Libraries load in glob sort order. If a library depends on another,
# it must document this requirement (e.g., run-phase.sh depends on log.sh).
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

# --- Register signal handler ---
MAIN_PID=""
EXIT_CODE=0
_CLEANUP_RUNNING=0

# Graceful shutdown handler. Invoked via SIGTERM/SIGINT trap.
#
# Steps:
#   1. Guard against re-entrant execution (trap + fallthrough race)
#   2. Disarm signal traps to prevent nested handler execution
#   3. Forward SIGTERM to main process (if still alive)
#   4. Wait for main process to exit (up to KUBEDOOP_KILL_TIMEOUT seconds)
#   5. Escalate to SIGKILL if main process does not exit in time
#   6. Reap main process and capture actual exit code
#   7. Run post-script phase hooks
#
# Environment:
#   MAIN_PID              - PID of the main process (set by caller)
#   KUBEDOOP_KILL_TIMEOUT - Max seconds to wait before SIGKILL (readonly)
#
# Returns:
#   0 - Always (best-effort cleanup, errors are logged but not propagated)
cleanup() {
    # Prevent re-entrant execution (trap + fallthrough race)
    if [[ "${_CLEANUP_RUNNING}" -eq 1 ]]; then
        return 0
    fi
    _CLEANUP_RUNNING=1

    # Disarm signal traps during cleanup to prevent nested handler execution
    trap - SIGTERM SIGINT

    log_info "Starting shutdown cleanup"

    # Only forward signal if main process is still alive (signal-triggered shutdown)
    if [[ -n "$MAIN_PID" ]] && kill -0 "$MAIN_PID" 2>/dev/null; then
        log_info "Forwarding SIGTERM to main process (PID: $MAIN_PID)"
        kill -TERM "$MAIN_PID" 2>/dev/null || true

        # Wait for main process to exit (with timeout protection)
        local elapsed=0
        while kill -0 "$MAIN_PID" 2>/dev/null && [[ $elapsed -lt $KUBEDOOP_KILL_TIMEOUT ]]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done

        # Force kill on timeout
        if kill -0 "$MAIN_PID" 2>/dev/null; then
            log_warn "Main process did not exit in ${KUBEDOOP_KILL_TIMEOUT}s, sending SIGKILL"
            kill -KILL "$MAIN_PID" 2>/dev/null || true
        fi
    fi

    # Reap main process to capture actual exit code and prevent zombies.
    # On signal path: overrides interrupted-wait's 128+SIGNUM with real exit code.
    # On normal path: process already reaped, wait returns 127, which we ignore.
    if [[ -n "$MAIN_PID" ]]; then
        local reap_code=0
        wait "$MAIN_PID" 2>/dev/null || reap_code=$?
        if [[ "$reap_code" -ne 127 ]]; then
            EXIT_CODE="$reap_code"
        fi
    fi

    log_info "Main process stopped"

    # Phase 2: Runtime post-script hooks (auto-discovered from mount)
    run_phase "post-script" "${KUBEDOOP_MOUNT_DIR}/post-script" || true

    log_info "Shutdown complete"
}

# Block signals during process start to prevent cleanup() from firing with empty MAIN_PID.
# There is a small race window between "$@" & MAIN_PID=$! and the trap re-arm below
# where SIGTERM is still ignored. If SIGTERM arrives during this window, the main process
# continues running and will only be terminated when K8s escalates to SIGKILL after
# terminationGracePeriodSeconds. tini provides the safety net (reaps orphans on exit).
trap '' SIGTERM SIGINT

# --- Start main process ---
if [[ $# -eq 0 ]]; then
    log_error "No command specified"
    exit 1
fi

# Start process and capture PID atomically (same logical line as backgrounding)
"$@" & MAIN_PID=$!

# Restore signal handler immediately after PID capture — minimizes race window
trap cleanup SIGTERM SIGINT

log_info "Main process started (PID: $MAIN_PID): $*"

# Wait for main process to exit
wait $MAIN_PID || EXIT_CODE=$?

# Run cleanup (if not already triggered by signal trap)
cleanup

exit $EXIT_CODE
