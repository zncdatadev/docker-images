#!/bin/bash
# /kubedoop/lib/signal.sh -- Process lifecycle management
#
# Provides graceful process termination, cleanup orchestration,
# and full lifecycle management for the universal entrypoint.
#
# Depends on: lib/log.sh, lib/run.sh (loaded via glob in entrypoint)
#
# Required global variables (set by entrypoint before calling run_lifecycle):
#   KUBEDOOP_KILL_TIMEOUT - Max seconds to wait before SIGKILL (readonly)
#   KUBEDOOP_MOUNT_DIR    - Path to mount directory (readonly)

# The main command owns a separate session/process group. Signal only that
# group, never the entrypoint/post-hook group. A startup signal can precede
# setsid; fall back to the still-owned direct child in that short window.
_signal_process() {
    local pid="$1" signal="$2" group="${3:-}"
    if [[ -n "$group" ]]; then
        if kill -"$signal" -- -"$group" 2>/dev/null; then
            [[ "$signal" != TERM ]] || _GROUP_TERM_SENT=1
        else
            kill -"$signal" "$pid" 2>/dev/null || true
        fi
    else
        kill -"$signal" "$pid" 2>/dev/null || true
    fi
}

_group_has_live_processes() {
    local group="$1" file line remainder state parent process_group ignored
    [[ -n "$group" ]] || return 1
    for file in /proc/[0-9]*/stat; do
        [[ -r "$file" ]] || continue
        IFS= read -r line < "$file" 2>/dev/null || continue
        remainder="${line##*) }"
        read -r state parent process_group ignored <<< "$remainder"
        if [[ "$process_group" == "$group" && "$state" != Z && "$state" != X ]]; then
            return 0
        fi
    done
    return 1
}

_stop_remaining_group() {
    local group="$1" deadline="$2"
    _group_has_live_processes "$group" || return 0
    log_info "Stopping remaining main-process group members"
    if [[ "${_GROUP_TERM_SENT:-0}" -eq 0 ]]; then
        kill -TERM -- -"$group" 2>/dev/null || true
        _GROUP_TERM_SENT=1
    fi
    while _group_has_live_processes "$group" && ((SECONDS < deadline)); do sleep 0.05; done
    if _group_has_live_processes "$group"; then
        log_warn "Main process group did not exit before shutdown deadline, sending SIGKILL"
        kill -KILL -- -"$group" 2>/dev/null || true
        # Ignore zombies, which Tini reaps; give the kernel a bounded interval
        # to complete fatal signal delivery without running hooks prematurely.
        local kill_deadline=$((SECONDS + 2))
        while _group_has_live_processes "$group" && ((SECONDS < kill_deadline)); do sleep 0.05; done
    fi
    if _group_has_live_processes "$group"; then
        log_error "Main process group remains alive; refusing post-scripts"
        return 1
    fi
}

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
#   Caller must supply an owned child whose status has not yet been consumed.
#   Sets STOP_EXIT_CODE to the child's exit code (including a legitimate 127).
#   Sets STOP_REAPED=1 after wait, 0 if no PID was supplied.
stop_process() {
    local pid="$1"
    local timeout="$2"
    local group="${3:-}"

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
        STOP_EXIT_CODE=$rc
        STOP_REAPED=1
        return 0
    fi

    log_info "Forwarding SIGTERM to main process (PID: $pid)"
    _signal_process "$pid" TERM "$group"

    # Reap process to capture exit code. Use a SIGALRM timer for timeout
    # protection instead of polling with kill -0: a dead-but-unreaped child is
    # still visible to kill -0 as a zombie, which can add a full timeout delay
    # even after graceful shutdown has completed.
    local timed_out=0
    local shell_pid="$BASHPID"
    # Install before arming the timer, and keep installed until it is reaped.
    trap 'timed_out=1; log_warn "Main process did not exit in ${timeout}s, sending SIGKILL"; _signal_process "$pid" KILL "$group"' SIGALRM
    (
        sleep "$timeout"
        kill -ALRM "$shell_pid" 2>/dev/null
    ) &
    local timer_pid=$!

    local rc=0
    while :; do
        timed_out=0
        _CLEANUP_INTERRUPTED=0
        wait "$pid" 2>/dev/null
        rc=$?
        # A handled signal interrupts Bash's wait without consuming the child's
        # status. Keep waiting after repeated shutdown signals or the timeout
        # alarm, but preserve real application exit codes (including 130/142/143).
        if [[ "$timed_out" -eq 1 && "$rc" -eq $((128 + 14)) ]] ||
            [[ "$_CLEANUP_INTERRUPTED" -eq 1 && ( "$rc" -eq 130 || "$rc" -eq 143 || "$rc" -eq $((128 + $(kill -l RTMIN+3))) ) ]]; then
            continue
        fi
        break
    done

    # This is our timer shell, not the application: cancellation must not depend
    # on TERM delivery/traps. Otherwise it can sleep to the deadline and send an
    # unhandled ALRM after the main child has already exited gracefully.
    kill -KILL "$timer_pid" 2>/dev/null || true
    local timer_rc=0
    while :; do
        timed_out=0
        _CLEANUP_INTERRUPTED=0
        wait "$timer_pid" 2>/dev/null
        timer_rc=$?
        if [[ "$timed_out" -eq 1 && "$timer_rc" -eq $((128 + 14)) ]] ||
            [[ "$_CLEANUP_INTERRUPTED" -eq 1 && ( "$timer_rc" -eq 130 || "$timer_rc" -eq 143 || "$timer_rc" -eq $((128 + $(kill -l RTMIN+3))) ) ]]; then
            continue
        fi
        break
    done
    trap - SIGALRM

    STOP_EXIT_CODE=$rc
    STOP_REAPED=1
}

# Graceful shutdown handler. Invoked via SIGTERM/SIGINT trap by run_lifecycle.
#
# Steps:
#   1. Guard against re-entrant execution
#   2. Keep handling shutdown signals without re-entering cleanup
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
        _CLEANUP_INTERRUPTED=1
        return 0
    fi
    _CLEANUP_RUNNING=1

    # Leave the real handler installed: restoring SIG_DFL would abort cleanup
    # on another signal; SIG_IGN would also be inherited by post-script hooks.

    log_info "Starting shutdown cleanup"
    local shutdown_deadline=$((SECONDS + KUBEDOOP_KILL_TIMEOUT))

    # Track reaping explicitly: 127 is a valid application exit status, not
    # evidence that wait has already consumed the child's status.
    if [[ "$_MAIN_REAPED" -eq 0 ]]; then
        stop_process "$MAIN_PID" "$KUBEDOOP_KILL_TIMEOUT" "${MAIN_PGID:-}"
        if [[ "$STOP_REAPED" -eq 1 ]]; then
            EXIT_CODE="$STOP_EXIT_CODE"
            _MAIN_REAPED=1
        fi
    fi

    log_info "Main process stopped"
    # Foreground commands can leave descendants. Also cover children left
    # behind after normal main-command exit, retaining the main exit status.
    _stop_remaining_group "${MAIN_PGID:-}" "$shutdown_deadline" || return 0

    # Operator post-scripts (auto-discovered from mount); best-effort
    run_post_scripts || true

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
    MAIN_PGID=""
    _GROUP_TERM_SENT=0
    EXIT_CODE=0
    _CLEANUP_RUNNING=0
    _CLEANUP_INTERRUPTED=0
    _PENDING_SIGNAL=0
    _MAIN_REAPED=0

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
    trap '_PENDING_SIGNAL=1' SIGTERM SIGINT SIGRTMIN+3

    # Start process and capture PID atomically (same logical line as backgrounding)
    # Explicit redirection preserves stdin; otherwise non-interactive Bash
    # connects a background command's stdin to /dev/null.
    # Non-interactive entrypoints have job control off: setsid execs without
    # forking, keeping the supervised PID equal to the final JVM PID.
    set +m
    setsid -- "$@" <&0 & MAIN_PID=$!; MAIN_PGID=$MAIN_PID

    # Swap the deferring handler for the real cleanup handler.
    trap cleanup SIGTERM SIGINT SIGRTMIN+3

    log_info "Main process started (PID: $MAIN_PID)"

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
        _MAIN_REAPED=1
        cleanup
    fi
    # Signal path: cleanup() already ran and set EXIT_CODE — leave it intact.
}
