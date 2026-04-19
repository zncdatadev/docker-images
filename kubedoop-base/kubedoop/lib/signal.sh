#!/bin/bash
# /kubedoop/lib/signal.sh -- Process lifecycle management
#
# Provides graceful process termination, cleanup orchestration,
# and full lifecycle management for the universal entrypoint.
#
# Depends on: lib/log.sh, lib/run-phase.sh (loaded via glob in entrypoint)
#
# Required global variables (set by entrypoint before calling run_lifecycle):
#   KUBEDOOP_KILL_TIMEOUT - Max seconds to wait before SIGKILL (readonly)
#   KUBEDOOP_MOUNT_DIR    - Path to mount directory (readonly)

# Terminate a process gracefully with timeout escalation.
#
# Steps:
#   1. If process is alive, send SIGTERM
#   2. Wait up to timeout seconds for process to exit
#   3. Escalate to SIGKILL on timeout
#   4. Reap process to capture exit code and prevent zombies
#
# Arguments:
#   $1 - PID to terminate
#   $2 - Timeout in seconds before SIGKILL escalation
#
# Side effects:
#   Sets STOP_EXIT_CODE to the reaped exit code (empty if PID is empty)
#   Sets STOP_REAPED=1 if the process was reaped, 0 if no PID
stop_process() {
    local pid="$1"
    local timeout="$2"

    STOP_EXIT_CODE=""
    STOP_REAPED=0

    # Nothing to do if no PID
    if [[ -z "$pid" ]]; then
        return 0
    fi

    # Process already dead — try reap in case of signal path (interrupted wait)
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || STOP_EXIT_CODE=$?
        STOP_REAPED=1
        return 0
    fi

    log_info "Forwarding SIGTERM to main process (PID: $pid)"
    kill -TERM "$pid" 2>/dev/null || true

    # Wait for process to exit (with timeout protection)
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Force kill on timeout
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Main process did not exit in ${timeout}s, sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    fi

    # Reap process to capture exit code
    wait "$pid" 2>/dev/null || STOP_EXIT_CODE=$?
    STOP_REAPED=1
}

# Graceful shutdown handler. Invoked via SIGTERM/SIGINT trap by run_lifecycle.
#
# Steps:
#   1. Guard against re-entrant execution
#   2. Disarm signal traps to prevent nested handler execution
#   3. Stop main process (SIGTERM → wait → SIGKILL escalation)
#   4. Capture actual exit code from reap
#   5. Run post-script phase hooks
#
# Environment:
#   MAIN_PID              - PID of the main process (set by run_lifecycle)
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

    stop_process "$MAIN_PID" "$KUBEDOOP_KILL_TIMEOUT"

    # Capture real exit code if process was reaped during signal path
    if [[ "$STOP_REAPED" -eq 1 && -n "$STOP_EXIT_CODE" ]]; then
        EXIT_CODE="$STOP_EXIT_CODE"
    fi

    log_info "Main process stopped"

    # Phase: Runtime post-script hooks (auto-discovered from mount)
    run_phase "post-script" "${KUBEDOOP_MOUNT_DIR}/post-script" || true

    log_info "Shutdown complete"
}

# Start main process and manage its full lifecycle.
#
# This is the core lifecycle function that:
#   - Blocks signals during process start (prevents empty PID race)
#   - Backgrounds the command and captures PID
#   - Restores signal handler immediately after PID capture (minimizes race window)
#   - Waits for process exit (normal or signal-triggered)
#   - Runs cleanup on exit
#
# Sets EXIT_CODE global to the process exit code on return.
#
# Arguments:
#   $@ - Command and arguments to run as the main process
run_lifecycle() {
    MAIN_PID=""
    EXIT_CODE=0
    _CLEANUP_RUNNING=0

    # Block signals during process start to prevent cleanup() with empty MAIN_PID.
    # There is a small race window between "$@" & MAIN_PID=$! and the trap re-arm
    # below where SIGTERM is still ignored. If SIGTERM arrives during this window,
    # the main process continues running and will only be terminated when K8s
    # escalates to SIGKILL after terminationGracePeriodSeconds.
    # tini provides the safety net (reaps orphans on exit).
    trap '' SIGTERM SIGINT

    # Start process and capture PID atomically (same logical line as backgrounding)
    "$@" & MAIN_PID=$!

    # Restore signal handler immediately after PID capture — minimizes race window
    trap cleanup SIGTERM SIGINT

    log_info "Main process started (PID: $MAIN_PID): $*"

    # Wait for main process to exit
    wait $MAIN_PID || EXIT_CODE=$?

    # Run cleanup (if not already triggered by signal trap)
    cleanup
}
