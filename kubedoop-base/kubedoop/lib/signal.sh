#!/bin/bash
# /kubedoop/lib/signal.sh -- Process lifecycle management
#
# Provides graceful process termination with configurable timeout.
# SIGTERM → wait → SIGKILL escalation pattern with exit code capture.

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
