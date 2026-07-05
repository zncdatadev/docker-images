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
#   Sets STOP_EXIT_CODE to the reaped exit code (empty if PID is empty or already reaped)
#   Sets STOP_REAPED=1 if the process was reaped, 0 if no PID or already reaped
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
        wait "$pid" 2>/dev/null
        local rc=$?
        if [[ $rc -eq 127 ]]; then
            # Not a child of this shell — already reaped, exit code unknown
            STOP_REAPED=0
        else
            STOP_EXIT_CODE=$rc
            STOP_REAPED=1
        fi
        return 0
    fi

    log_info "Forwarding SIGTERM to main process (PID: $pid)"
    kill -TERM "$pid" 2>/dev/null || true

    # Reap process to capture exit code. Use a SIGALRM timer for timeout
    # protection instead of polling with kill -0: a dead-but-unreaped child is
    # still visible to kill -0 as a zombie, which can add a full timeout delay
    # even after graceful shutdown has completed.
    local timed_out=0
    local shell_pid="$BASHPID"
    (
        sleep "$timeout"
        kill -ALRM "$shell_pid" 2>/dev/null
    ) &
    local timer_pid=$!

    trap 'timed_out=1; log_warn "Main process did not exit in ${timeout}s, sending SIGKILL"; kill -KILL "$pid" 2>/dev/null || true' SIGALRM

    wait "$pid" 2>/dev/null
    local rc=$?
    if [[ "$timed_out" -eq 1 ]]; then
        wait "$pid" 2>/dev/null
        rc=$?
    fi

    trap - SIGALRM
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true

    if [[ $rc -eq 127 ]]; then
        # Not a child of this shell — already reaped, exit code unknown
        STOP_REAPED=0
    else
        STOP_EXIT_CODE=$rc
        STOP_REAPED=1
    fi
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
    if [[ "${_CLEANUP_RUNNING:-0}" -eq 1 ]]; then
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
    _PENDING_SIGNAL=0

    # Defer signals during process start to close the race where SIGTERM arrives
    # before MAIN_PID is captured (which would run cleanup() with an empty PID).
    #
    # CRITICAL: use a real handler that records a pending flag — NOT `trap ''`.
    # `trap '' SIGTERM` installs SIG_IGN, which is INHERITED by the backgrounded
    # child across fork/exec. A non-interactive child shell cannot re-trap a
    # signal that was ignored on entry, so the child (and any SIGTERM handler it
    # installs, e.g. a product entrypoint) would silently ignore graceful
    # shutdown — the exact opposite of this framework's guarantee. A real trap
    # handler is reset to SIG_DFL in the execed child, so the child receives
    # SIGTERM normally and may install its own handler.
    trap '_PENDING_SIGNAL=1' SIGTERM SIGINT

    # Start process and capture PID atomically (same logical line as backgrounding)
    "$@" & MAIN_PID=$!

    # Swap the deferring handler for the real cleanup handler.
    trap cleanup SIGTERM SIGINT

    log_info "Main process started (PID: $MAIN_PID): $*"

    # If a signal arrived during the start window, the deferring handler recorded
    # it. Run cleanup now (with a valid MAIN_PID) instead of waiting.
    if [[ "$_PENDING_SIGNAL" -eq 1 ]]; then
        log_info "Signal received during startup, initiating shutdown"
        cleanup
    fi

    # Wait for the main process to exit.
    #
    # Two paths reach this point:
    #   Normal exit — main process exits on its own; wait returns its real code.
    #   Signal path — SIGTERM/SIGINT arrives during wait, firing the cleanup()
    #                 trap. cleanup() reaps the child and sets EXIT_CODE to the
    #                 real reaped code. The interrupted wait then returns
    #                 128+signum (e.g. 143 for SIGTERM), which must NOT clobber
    #                 the real exit code cleanup() already captured.
    local rc=0
    wait "$MAIN_PID" || rc=$?

    if [[ "${_CLEANUP_RUNNING:-0}" -ne 1 ]]; then
        # Normal exit path: capture the real exit code, then run cleanup hooks.
        EXIT_CODE=$rc
        cleanup
    fi
    # Signal path: cleanup() already ran and set EXIT_CODE — leave it intact.
}
