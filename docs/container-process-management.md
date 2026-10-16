# Container Process Management Design

> **Status**: Piloting in the **zookeeper** image (product-first rollout, see [Rollout Strategy](#rollout-strategy-product-first)). Init system: tini v0.19.0. Extraction into `kubedoop-base`, pod-state coordination, and the sidecar watchdog are deferred.

## Design Goals

| Goal | Description |
|------|-------------|
| Reliable signal delivery | Init process as PID 1, ensures SIGTERM reaches the application |
| Zombie reaping | Init process auto-waits, prevents process table leaks |
| Runtime script injection | Operator/User injects hooks via K8s Volume mount, no image rebuild |
| Auto-discovery | Scan `/kubedoop/mount/` fixed mount points, execute in order |
| Consistency | All product images share the same entrypoint framework |
| Zero-intrusion | No mounted scripts = behaves identically to bare exec |
| Pod coordination | Main container and sidecars synchronize lifecycle via shared state |

## Design Rationale

Product authors already control the Dockerfile and CMD. Their initialization logic stays in existing product entrypoints (e.g., airflow's entrypoint.sh, superset's entrypoint.sh). What this framework provides is a **runtime injection layer** — a standardized way for operators to inject custom hooks without rebuilding images.

The separation is:

| Layer | Owner | Mechanism |
|-------|-------|-----------|
| Product initialization | Product author | Existing entrypoint scripts / CMD |
| Runtime hooks | Operator / User | `/kubedoop/mount/` Volume injection |

## Product Entrypoint Contract

Product entrypoints called via CMD must follow these rules:

1. **Must be the long-running process** — the framework backgrounds CMD and tracks its PID. The command (or product entrypoint script) should be the process that stays alive for the container's lifetime. Do not fork+exit.
2. **Must not install its own SIGTERM trap** — the universal framework owns signal handling via `lib/signal.sh`.
3. **Path convention**: product-specific entrypoints must live at `/kubedoop/bin/product-entrypoint.sh` (or any path other than `/kubedoop/bin/entrypoint.sh`) to avoid collision with the universal framework.

Example:
```
Universal framework: /kubedoop/bin/entrypoint.sh  (deployed by kubedoop-base)
Product entrypoint:  /kubedoop/bin/start-app.sh   (product-specific, any name except entrypoint.sh)
```

## Directory Layout

```
/kubedoop/
├── bin/          root:root 0755  # Universal entrypoint (shared across all images)
│   └── entrypoint.sh
├── lib/          root:root 0755  # Framework libraries
│   ├── log.sh
│   ├── run.sh
│   ├── signal.sh
│   └── pod-state.sh           (deferred)
├── mount/        root:root 0755  # Runtime injection layer (fixed mount points)
│   ├── pre-script/               # K8s Volume managed at runtime
│   └── post-script/              # K8s Volume managed at runtime
├── app/          root:root 0755  # Application files
└── run/          kubedoop:kubedoop 1775  # Shared Pod state (emptyDir, writable, sticky bit)
    ├── main.pid
    ├── main.status
    └── main.exit_code
```

## Execution Flow

```
Kubernetes sends SIGTERM
        |
        v
+--- Init Process (PID 1) -------------------------------------+
|   Signal forwarding (to direct child only, no -g flag)       |
|   Zombie reaping (auto-wait all orphaned processes)          |
+--------------------------------------------------------------+
|                                                              |
|  +- entrypoint.sh (PID 2) --------------------------------+ |
|  |                                                         | |
|  |  [1] source lib/*.sh                Load libraries      | |
|  |  [2] run_pre_scripts                Operator pre-scripts | |
|  |  [3] run_lifecycle "$@"             Start + manage      | |
|  |      ├── trap 'defer' SIGTERM SIGINT Defer (not SIG_IGN)| |
|  |      ├── "$@" <&0 & MAIN_PID=$!     Background CMD      | |
|  |      ├── trap cleanup SIGTERM SIGINT Arm real handler   | |
|  |      └── wait $MAIN_PID             Wait for exit       | |
|  |                                                         | |
|  |  -- On SIGTERM received (via cleanup) --                 | |
|  |  [4] stop_process $MAIN_PID         Graceful shutdown   | |
|  |  [5] run_post_scripts               Operator post-scripts | |
|  |  [6] exit $EXIT_CODE                Propagate exit      | |
|  +---------------------------------------------------------+ |
+--------------------------------------------------------------+
```

## Implementation

> **Note on error handling**: The entrypoint uses `set -uo pipefail` (without `-e`).
> Signal-aware shell scripts must not use `set -e` because trap handlers and `set -e`
> interact unpredictably. All error handling is explicit.

> **Note on signals during cleanup**: `cleanup()` keeps its signal handlers installed.
> Further SIGTERM/SIGINT signals cannot re-enter or abort cleanup. If they interrupt
> Bash's `wait`, `stop_process()` resumes waiting for the child; a SIGALRM deadline
> still enforces SIGKILL escalation. Post-scripts inherit normal signal dispositions.

> **Note on KUBEDOOP_KILL_TIMEOUT**: Must be a positive integer >= 1. A value of 0
> (immediate SIGKILL) is intentionally not supported — the graceful shutdown window
> is always at least 1 second.

### lib/log.sh — Unified Logging

```bash
#!/bin/bash
# /kubedoop/lib/log.sh — Unified log output
#
# Provides structured logging with ISO 8601 timestamps.
# Log prefix is configurable via __KUBEDOOP_LOG_PREFIX (default: "kubedoop").
# Debug output is gated by KUBEDOOP_DEBUG=true.

__KUBEDOOP_LOG_PREFIX="${__KUBEDOOP_LOG_PREFIX:-kubedoop}"

# Internal log formatter. Strips control characters to prevent log injection.
#
# Arguments:
#   $1    - Log level (INFO, WARN, ERROR, DEBUG)
#   $2..  - Message strings
#
# Output:
#   stdout - Formatted log line: "[TIMESTAMP] [PREFIX] [LEVEL] MESSAGE"
_kubedoop_log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Sanitize: strip control characters to prevent log injection
    local msg
    msg=$(printf '%s' "$*" | tr -d '[:cntrl:]')
    printf "[%s] [%s] [%s] %s\n" "$timestamp" "$__KUBEDOOP_LOG_PREFIX" "$level" "$msg"
}

log_info()  { _kubedoop_log "INFO"  "$@"; }
log_warn()  { _kubedoop_log "WARN"  "$@" >&2; }
log_error() { _kubedoop_log "ERROR" "$@" >&2; }
log_debug() {
    if [[ "${KUBEDOOP_DEBUG:-false}" == "true" ]]; then
        _kubedoop_log "DEBUG" "$@"
    fi
}
```

### lib/run.sh — Operator Script Discovery and Execution

```bash
#!/bin/bash
# /kubedoop/lib/run.sh -- Operator-provided lifecycle scripts
#
# Executes the scripts operators mount under /kubedoop/mount/:
#   run_pre_scripts   - ${KUBEDOOP_MOUNT_DIR}/pre-script   (before the main process starts)
#   run_post_scripts  - ${KUBEDOOP_MOUNT_DIR}/post-script  (after the main process stopped)
#
# Depends on: lib/log.sh (loaded via glob in entrypoint)
#
# Required global variables:
#   KUBEDOOP_MOUNT_DIR - Path to mount directory (readonly, set by entrypoint)

# Discover executable .sh scripts in a directory, sorted by filename.
#
# Arguments:
#   $1 - Directory path to scan
#
# Output:
#   stdout - Null-delimited sorted list of matching script paths, empty if none found
#
# Returns:
#   0 - Discovery succeeded, or the directory does not exist
#   1 - find or sort failed
_discover_scripts() {
    local scripts_dir="$1"

    if [[ ! -d "$scripts_dir" ]]; then
        return 0
    fi

    # Only match .sh files that have any execute bit set (owner, group, or other).
    # Note: -executable is GNU find specific (not BSD/macOS). Acceptable here since
    # the target environment is ubi9-minimal (Linux, GNU findutils).
    # With ConfigMap defaultMode: 0755, this correctly matches all executable scripts.
    # SECURITY: Only execute scripts owned by root (uid 0) to prevent injection
    # from non-root writable volumes (emptyDir, PVC, hostPath).
    # ConfigMap/projected volumes expose symlinks into ..data. Follow links so
    # type, ownership and executable checks apply to the target, not the link.
    find -L "$scripts_dir" -maxdepth 1 -type f -name '*.sh' -executable \
        -uid 0 -print0 \
        | sort -z
    local -a pipeline_status=("${PIPESTATUS[@]}")
    if [[ "${pipeline_status[0]}" -ne 0 || "${pipeline_status[1]}" -ne 0 ]]; then
        return 1
    fi

    return 0
}

# Execute all scripts found in a directory sequentially, in filename sort order.
# First script failure aborts immediately.
#
# Arguments:
#   $1 - Label for logging (e.g., "pre-script", "post-script")
#   $2 - Directory containing executable .sh scripts
#
# Returns:
#   0 - All scripts succeeded, or no scripts found
#   1 - A script failed, or script discovery failed
_run_scripts() {
    local label="$1"
    local scripts_dir="$2"

    if [[ ! -d "$scripts_dir" ]]; then
        return 0
    fi

    local count=0
    local found_any=false
    local script_list

    # Process substitution hides the producer's exit status from the while loop.
    # Materialize the null-delimited list first so discovery errors (permission
    # denied, I/O errors, etc.) fail the run instead of looking like an empty
    # directory. KUBEDOOP_RUN_DIR is the writable runtime area in the image.
    if ! script_list=$(mktemp "${KUBEDOOP_RUN_DIR:-/tmp}/.scripts.XXXXXX"); then
        log_error "$label: failed to create script discovery file"
        return 1
    fi

    if ! _discover_scripts "$scripts_dir" > "$script_list"; then
        log_error "$label: failed to discover scripts in $scripts_dir"
        rm -f "$script_list"
        return 1
    fi

    local script_list_fd
    if ! exec {script_list_fd}<"$script_list"; then
        log_error "$label: failed to read discovered script list"
        rm -f "$script_list"
        return 1
    fi
    rm -f "$script_list"

    while IFS= read -r -d '' -u "$script_list_fd" script; do
        found_any=true
        local name
        name=$(basename "$script")
        log_info "$label: running $name"
        count=$((count + 1))

        local rc=0
        # Hooks are non-interactive and must not consume the discovery stream.
        "$script" </dev/null {script_list_fd}<&- || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "$label: $name failed with exit code $rc"
            exec {script_list_fd}<&-
            return 1
        fi
    done

    exec {script_list_fd}<&-

    if [[ "$found_any" == false ]]; then
        log_info "$label: no scripts found"
        return 0
    fi

    log_info "$label: completed ($count scripts)"
    return 0
}

# Execute operator-injected pre-scripts. Runs before the main process starts;
# a failure makes the caller abort startup (fail-fast).
#
# Returns:
#   0 - All pre-scripts succeeded, or none found
#   1 - A pre-script failed, or discovery failed
run_pre_scripts() {
    _run_scripts "pre-script" "${KUBEDOOP_MOUNT_DIR}/pre-script"
}

# Execute operator-injected post-scripts. Runs during shutdown cleanup, after
# the main process stopped; the caller decides how to handle failure.
#
# Returns:
#   0 - All post-scripts succeeded, or none found
#   1 - A post-script failed, or discovery failed
run_post_scripts() {
    _run_scripts "post-script" "${KUBEDOOP_MOUNT_DIR}/post-script"
}
```

### lib/signal.sh — Process Lifecycle Management

```bash
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
            [[ "$_CLEANUP_INTERRUPTED" -eq 1 && ( "$rc" -eq 130 || "$rc" -eq 143 ) ]]; then
            continue
        fi
        break
    done

    trap - SIGALRM
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true

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

    # Track reaping explicitly: 127 is a valid application exit status, not
    # evidence that wait has already consumed the child's status.
    if [[ "$_MAIN_REAPED" -eq 0 ]]; then
        stop_process "$MAIN_PID" "$KUBEDOOP_KILL_TIMEOUT"
        if [[ "$STOP_REAPED" -eq 1 ]]; then
            EXIT_CODE="$STOP_EXIT_CODE"
            _MAIN_REAPED=1
        fi
    fi

    log_info "Main process stopped"

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
    trap '_PENDING_SIGNAL=1' SIGTERM SIGINT

    # Start process and capture PID atomically (same logical line as backgrounding)
    # Explicit redirection preserves stdin; otherwise non-interactive Bash
    # connects a background command's stdin to /dev/null.
    "$@" <&0 & MAIN_PID=$!

    # Swap the deferring handler for the real cleanup handler.
    trap cleanup SIGTERM SIGINT

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
```

### lib/pod-state.sh — Pod State File Management

> **Status: Deferred** — This library is designed but not yet deployed. It will be included in a future phase when sidecar coordination is implemented.

```bash
#!/bin/bash
# /kubedoop/lib/pod-state.sh — Pod multi-container state coordination
#
# Writes state files to /kubedoop/run/ (shared via emptyDir volume).
# Sidecar containers (e.g., vector) monitor these files via inotifywait
# to synchronize their lifecycle with the main container.
#
# All writes use atomic rename (write-to-tmp + mv) to prevent
# sidecars from reading partial content.

# Paths are locked at build time by entrypoint.sh (readonly).
# These are fallback values for standalone testing only.
KUBEDOOP_HOME="${KUBEDOOP_HOME:-/kubedoop}"
KUBEDOOP_RUN_DIR="${KUBEDOOP_RUN_DIR:-${KUBEDOOP_HOME}/run}"

# Atomic write: write to tmp file, then rename
# rename(2) is atomic on the same filesystem (including tmpfs/emptyDir)
_atomic_write() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp.$$"
    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

# Write main process PID
write_pid() {
    local pid="$1"
    _atomic_write "${KUBEDOOP_RUN_DIR}/main.pid" "$pid"
    log_debug "Wrote main.pid: $pid"
}

# Write main process status: running | stopping | stopped
write_state() {
    local state="$1"
    _atomic_write "${KUBEDOOP_RUN_DIR}/main.status" "$state"
    log_debug "Wrote main.status: $state"
}

# Write main process exit code
write_exit_code() {
    local code="$1"
    _atomic_write "${KUBEDOOP_RUN_DIR}/main.exit_code" "$code"
    log_debug "Wrote main.exit_code: $code"
}

# Wait for main container status file to reach a specific state
# Usage: wait_for_state <expected_state> <timeout_seconds>
wait_for_state() {
    local expected="$1"
    local timeout="${2:-300}"

    local start now
    start=$(date +%s)
    while true; do
        now=$(date +%s)
        if (( now - start >= timeout )); then
            break
        fi

        # Check current state (strip trailing newline from file content)
        local current_state
        current_state=$(cat "${KUBEDOOP_RUN_DIR}/main.status" 2>/dev/null) || continue
        if [[ "$current_state" == "$expected" ]]; then
            return 0
        fi

        # Check if main container crashed before reaching expected state
        if [[ -f "${KUBEDOOP_RUN_DIR}/main.exit_code" ]] \
            && [[ "$expected" == "running" ]]; then
            log_error "Main container exited before reaching 'running' state"
            return 1
        fi

        # Wait for directory change (watches directory, not file — works even if file doesn't exist yet)
        if command -v inotifywait &>/dev/null; then
            inotifywait -q -t 1 -e close_write,moved_to,create \
                "${KUBEDOOP_RUN_DIR}/" &>/dev/null || true
        else
            sleep 1
        fi
    done

    log_error "Timeout waiting for main.status = $expected (${timeout}s)"
    return 1
}
```

### bin/entrypoint.sh — Universal Container Entry

```bash
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
# it must document this requirement (e.g., signal.sh depends on log.sh and run.sh).
for lib in "${KUBEDOOP_HOME}/lib/"*.sh; do
    if [[ -f "$lib" ]]; then
        # shellcheck source=/dev/null
        source "$lib"
    fi
done

# Arguments may contain credentials; never include them in framework logs.
log_info "Entrypoint starting"

# --- Step 1: Operator pre-scripts (auto-discovered from mount) ---
# Note: pre-script failure prevents main process startup (fail-fast).
# Operators must test injected scripts in non-production environments first.
if ! run_pre_scripts; then
    log_error "Pre-scripts failed, aborting startup"
    exit 1
fi

# --- Step 2: Start main process and manage lifecycle ---
if [[ $# -eq 0 ]]; then
    log_error "No command specified"
    exit 1
fi

run_lifecycle "$@"
exit "$EXIT_CODE"
```

### kubedoop-base/Dockerfile Integration

```dockerfile
# Append to existing kubedoop-base Dockerfile

# stage: tini-downloader
# Download and verify the init system in a build stage — the result image only
# receives the verified binary and never runs download tooling.
# tini: lightweight init, signal forwarding to direct child, zombie reaping
# Not available in UBI 9 repos — download static binary from GitHub releases.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS tini-downloader

RUN microdnf install -y curl && microdnf clean all

ARG TARGETARCH
RUN <<EOF
    set -e
    curl -sSfL -o /tmp/tini \
        "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH}"

    # SHA256 checksums are hardcoded in the verification step to prevent --build-arg override
    case "${TARGETARCH}" in
        arm64)  expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        amd64)  expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        *)      echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod +x /tmp/tini
EOF

# Deploy universal entrypoint framework
# Framework files: root-owned, world-readable/executable, NOT writable by kubedoop
COPY --from=tini-downloader /tmp/tini /usr/bin/tini

COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chmod -R 0755 /kubedoop/lib/ /kubedoop/bin/ \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script \
    && chown -R root:root /kubedoop/mount/ \
    && mkdir -p /kubedoop/run \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run

# Security requirements for derived images and pods:
# - runAsNonRoot: true (or runAsUser: 1001)
# - readOnlyRootFilesystem: true (with /kubedoop/run as emptyDir)
# - allowPrivilegeEscalation: false
# - Runtime script injection: only ConfigMap/projected volumes in /kubedoop/mount/
# Note: kubedoop-base runs as root to allow derived images to build freely.
# Derived images should set USER 1001 at the end of their final stage.

# Init process as PID 1
# No -g flag: tini forwards signals only to direct child process.
# The entrypoint.sh manages signal propagation explicitly via lib/signal.sh.
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
```

## Product Migration Examples

### Trino (Simplest Case — No Mount)

No volume mount needed. The framework auto-discovers empty `mount/` directories and directly starts the main process.

```dockerfile
FROM zncdatadev/image/kubedoop-base

# ... existing build steps ...

# CMD is automatically received by entrypoint.sh as "$@"
CMD ["launcher", "run"]
```

### Superset (Product Keeps Its Own Entrypoint)

Product author's initialization logic stays in the product's own script. The framework wraps around it.

```dockerfile
FROM zncdatadev/image/kubedoop-base

# ... existing build steps ...

# Product's own init script — MUST use a path different from /kubedoop/bin/entrypoint.sh
# to avoid collision with the universal framework deployed by kubedoop-base.
COPY kubedoop/bin/start-superset.sh /kubedoop/bin/start-superset.sh

CMD ["/kubedoop/bin/start-superset.sh"]
```

### Airflow (Complex Entrypoint)

```dockerfile
FROM zncdatadev/image/kubedoop-base

# ... existing build steps ...

# Rename product entrypoint to avoid collision with universal framework
COPY kubedoop/bin/entrypoint.sh /kubedoop/bin/start-airflow.sh

# Airflow's entrypoint ends with exec "airflow" "$@" — satisfies the exec contract
CMD ["/kubedoop/bin/start-airflow.sh", "webserver"]
```

## Runtime Script Injection (No Image Rebuild)

Inject custom scripts at runtime via Kubernetes Volume mount into `/kubedoop/mount/`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-startup-scripts
data:
  50-register-service.sh: |
    #!/bin/bash
    source /kubedoop/lib/log.sh
    log_info "Registering service in service discovery..."
    curl -s http://consul:8500/v1/agent/service/register -d '{}'
---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      volumes:
        - name: pre-scripts
          configMap:
            name: custom-startup-scripts
            defaultMode: 0755    # REQUIRED: scripts must have execute permission to be discovered
      containers:
        - name: app
          volumeMounts:
            # Mount into /kubedoop/mount/pre-script/ — auto-discovered by entrypoint
            - name: pre-scripts
              mountPath: /kubedoop/mount/pre-script
```

Key points:

- `/kubedoop/mount/pre-script/` and `/kubedoop/mount/post-script/` are **fixed mount points**
- The entrypoint framework auto-discovers all `*.sh` files that are executable by the container user
- Scripts are sorted by filename and executed sequentially
- No volume mount = no scripts discovered = zero-intrusion

### Important: Script Failure Behavior

- **pre-script failure**: Aborts startup. The main process will NOT start. This is a fail-fast design.
- **post-script failure**: Logged but ignored (post-scripts run with `|| true`). Cleanup continues.
- Operators should test injected scripts in non-production environments before deploying to production.

### Important: ConfigMap Permission Contract

Scripts are discovered only if they are **executable by the user running inside the container** (using `find -executable`). When using ConfigMap volumes:

- Always set `defaultMode: 0755` on the ConfigMap volume source so mounted scripts are executable for the runtime user
- When using `items:` with per-item `mode:`, ensure each script item has mode `0755`
- Projected volumes and downward API volumes must follow the same executability requirement

If scripts are found in the directory but none are executable by the runtime user, the framework logs an info message and proceeds as if no scripts were found.

## Script Naming Convention

```
{NN}-{descriptive-name}.sh
  |        |
  |        +-- kebab-case descriptive name
  +-- Two-digit prefix, determines execution order
```

| Range | Purpose |
|-------|---------|
| `01-19` | Configuration rendering (gomplate templates, etc.) |
| `20-39` | Dependency waiting (databases, message queues) |
| `40-59` | Initialization (schema migration, user creation) |
| `60-79` | Reserved (custom injection) |
| `80-99` | Final validation (health check preparation) |

## Pod Multi-Container State Synchronization

### Problem

In a Pod with multiple containers (main + sidecars like vector), the containers have independent lifecycles. When the main container receives SIGTERM and exits, sidecars may continue running, preventing the Pod from terminating.

```
Pod
├── Main Container (trino/kafka/airflow...)
│   └── SIGTERM → graceful shutdown → exits
│
└── Sidecar Container (vector)
    └── Unaware of main container exit → keeps running → Pod stuck
```

### Core Principle

> **State files coordinate behavior (flush/drain), not exit decisions.**
> Exit decisions belong to Kubernetes (native mode) or the watchdog (legacy mode).

### Native Sidecar Restart Problem (K8s 1.28+)

K8s 1.28+ native sidecars (`restartPolicy: Always` in initContainers) restart when they exit while regular containers are still running. If the sidecar watchdog exits based on state files, it triggers an unwanted restart loop:

```
[1] Main container: write "stopping" → starts graceful shutdown (still running)
[2] Sidecar watchdog: sees "stopping" → exits
[3] K8s: sidecar exited, main container still running → restartPolicy: Always → RESTART sidecar!
[4] Sidecar restarts → watchdog starts → wait_for_state "running" → sees "stopping"
[5] Watchdog fails → sidecar exits → restart loop!
```

**Solution**: In native mode, the sidecar must NOT exit on its own. It waits for K8s to send SIGTERM. State files only trigger early flush/drain behavior.

### Dual-Mode Design

| Aspect | Native Mode (K8s >= 1.28) | Legacy Mode (K8s < 1.28) |
|--------|---------------------------|---------------------------|
| Who decides when sidecar exits | K8s (SIGTERM during Pod termination) | Watchdog (detects main container stopped) |
| State file purpose | Trigger flush/drain, NOT control exit | Control exit + trigger flush |
| Sidecar exit behavior | Waits for SIGTERM, never exits voluntarily | Exits after detecting "stopped" |
| Restart risk | None (K8s manages) | N/A (no restart policy) |

### Solution: Shared emptyDir + File-Based Coordination

The entrypoint framework writes state files to `/kubedoop/run/` (shared via emptyDir volume). Sidecar containers monitor these files using **inotifywait** (already installed in the vector image) to coordinate behavior.

All state file writes use **atomic rename** (write-to-tmp + mv) to prevent sidecars from reading partial content.

```
emptyDir volume mounted at /kubedoop/run/ (shared between all containers)

Main Container:                    Sidecar Container (vector):
  write "running"  ──────────────────> watchdog detects, starts vector
  write PID                          │
  ...main process runs...            │ vector running normally
  write "stopping" ──────────────────> watchdog detects
  SIGTERM → main process             │ triggers early flush (SIGUSR1)
  write "stopped"  ──────────────────> (native: K8s sends SIGTERM to sidecar)
  exit                               │ (legacy: watchdog exits voluntarily)
                                     v
                                   Pod terminates
```

### State File Contract

| File | Writer | Reader | Content | When |
|------|--------|--------|---------|------|
| `main.pid` | entrypoint.sh | sidecar | PID number | Main process starts |
| `main.status` | entrypoint.sh | sidecar | `running` | Main process started |
| | | | `stopping` | SIGTERM received, before forwarding |
| | | | `stopped` | Main process exited |
| `main.exit_code` | entrypoint.sh | sidecar | Exit code number | After main process exits |

### Sidecar Watchdog Script

> **Status: Not yet implemented** — This script is designed but not deployed. It will be shipped with the pod-state coordination phase.

```bash
#!/bin/bash
# /kubedoop/bin/sidecar-watchdog.sh — Sidecar lifecycle coordination
#
# Dual-mode design:
#   native (K8s >= 1.28): State files trigger flush only. K8s manages exit.
#   legacy (K8s < 1.28):  State files trigger flush AND control exit.
set -uo pipefail

KUBEDOOP_SIDECAR_MODE="${KUBEDOOP_SIDECAR_MODE:-native}"

source /kubedoop/lib/log.sh
source /kubedoop/lib/pod-state.sh

log_info "Sidecar watchdog starting (mode: ${KUBEDOOP_SIDECAR_MODE})"

# Signal handler: clean up child processes on SIGTERM/SIGINT
# Without this, K8s SIGTERM (native mode) would kill the watchdog but orphan
# the sidecar process and the background monitor.
_watchdog_cleanup() {
    log_info "Watchdog received shutdown signal"
    kill -TERM "$SIDECAR_PID" 2>/dev/null || true
    kill -TERM "$MONITOR_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
}
trap _watchdog_cleanup SIGTERM SIGINT

# Wait for main container to be ready
# Also exits early if main.exit_code appears (main container crashed during startup)
wait_for_state "running" "${KUBEDOOP_STARTUP_TIMEOUT:-120}" || {
    log_error "Main container did not reach 'running' state within timeout"
    exit 1
}
log_info "Main container is running"

# Start sidecar main process
# The sidecar command must be provided via KUBEDOOP_SIDECAR_CMD env var or as script arguments.
# Example: KUBEDOOP_SIDECAR_CMD="vector --config /etc/vector/vector.toml"
# Note: KUBEDOOP_SIDECAR_CMD is split on whitespace into an array to avoid eval injection.
if [[ $# -gt 0 ]]; then
    "$@" &
elif [[ -n "${KUBEDOOP_SIDECAR_CMD:-}" ]]; then
    read -ra _sidecar_cmd <<< "$KUBEDOOP_SIDECAR_CMD"
    "${_sidecar_cmd[@]}" &
else
    log_error "No sidecar command specified. Use KUBEDOOP_SIDECAR_CMD or pass command as arguments."
    exit 1
fi
SIDECAR_PID=$!
log_info "Sidecar process started (PID: $SIDECAR_PID)"

# Background monitor: watches state files to trigger early flush
# This does NOT exit the sidecar — only sends a flush signal
(
    if wait_for_state "stopping" "${KUBEDOOP_RUN_TIMEOUT:-86400}"; then
        log_info "Main container stopping, triggering sidecar flush"
        # Send flush signal to sidecar process (e.g., SIGUSR1 for vector)
        kill -USR1 "$SIDECAR_PID" 2>/dev/null || true
    fi
) &
MONITOR_PID=$!

# Mode-specific exit strategy
case "${KUBEDOOP_SIDECAR_MODE}" in
    native)
        # K8s 1.28+: Do NOT exit voluntarily.
        # Wait for sidecar process to finish (it will be terminated by K8s SIGTERM).
        # K8s sends SIGTERM to sidecar after all regular containers exit.
        # The sidecar process (vector) handles SIGTERM with its own graceful shutdown.
        wait "$SIDECAR_PID" || true
        wait "$MONITOR_PID" 2>/dev/null || true
        log_info "Sidecar process exited"
        ;;
    legacy)
        # Pre-1.28: Wait for main container to fully stop, then exit voluntarily.
        # Without this, the sidecar would keep running and the Pod would never terminate.
        wait_for_state "stopped" "${KUBEDOOP_STATE_WAIT_TIMEOUT:-60}" || true
        log_info "Main container stopped, terminating sidecar"
        kill -TERM "$SIDECAR_PID" 2>/dev/null || true
        kill -TERM "$MONITOR_PID" 2>/dev/null || true
        wait "$SIDECAR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        log_info "Sidecar process terminated"
        ;;
    *)
        log_error "Unknown KUBEDOOP_SIDECAR_MODE: ${KUBEDOOP_SIDECAR_MODE} (expected: native|legacy)"
        exit 1
        ;;
esac
```

### Kubernetes Pod Spec

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:

      # Option A: Kubernetes 1.28+ native sidecar (recommended)
      # Sidecar must NOT exit on its own — K8s manages its lifecycle.
      initContainers:
        - name: vector
          restartPolicy: Always    # K8s restarts sidecar if it crashes during normal operation
          image: zncdatadev/vector:0.47.0
          env:
            - name: KUBEDOOP_SIDECAR_MODE
              value: "native"      # Watchdog triggers flush only, waits for K8s SIGTERM
            - name: KUBEDOOP_SIDECAR_CMD
              value: "vector --config /etc/vector/vector.toml"
          command: ["/kubedoop/bin/sidecar-watchdog.sh"]
          volumeMounts:
            - name: pod-state
              mountPath: /kubedoop/run

      # Option B: Pre-1.28 sidecar (manual coordination)
      # Watchdog must exit voluntarily after main container stops.
      # containers:
      #   - name: vector
      #     image: zncdatadev/vector:0.47.0
      #     env:
      #       - name: KUBEDOOP_SIDECAR_MODE
      #         value: "legacy"    # Watchdog controls exit after detecting main stopped
      #       - name: KUBEDOOP_SIDECAR_CMD
      #         value: "vector --config /etc/vector/vector.toml"
      #     command: ["/kubedoop/bin/sidecar-watchdog.sh"]
      #     volumeMounts:
      #       - name: pod-state
      #         mountPath: /kubedoop/run

      containers:
        - name: main
          image: zncdatadev/trino:latest
          volumeMounts:
            - name: pod-state
              mountPath: /kubedoop/run

      # emptyDir permissions: containers run as kubedoop (UID 1001).
      # Set fsGroup so the emptyDir is writable by non-root containers.
      securityContext:
        fsGroup: 1001

      volumes:
        - name: pod-state
          emptyDir: {}              # Shared state between containers
```

### Strategy per Kubernetes Version

| K8s Version | Sidecar Type | Exit Decision | State File Role |
|-------------|-------------|---------------|-----------------|
| >= 1.28 | `initContainer` + `restartPolicy: Always` | K8s sends SIGTERM to sidecar after regular containers exit | Trigger early flush only |
| < 1.28 | Standard `container` | Watchdog detects `stopped` and exits voluntarily | Trigger flush AND control exit |

For K8s >= 1.28, the native sidecar handles start/stop ordering. State files provide early flush triggering (the sidecar starts draining before K8s even sends SIGTERM), which reduces log loss during shutdown. State files also provide visibility (PID, exit code) for debugging.

## Rollout Strategy: Product-First

The end-state design deploys the framework once in `kubedoop-base` so every image
inherits it (see [kubedoop-base/Dockerfile Integration](#kubedoop-basedockerfile-integration)).
However, **any change to `kubedoop-base` rebuilds every downstream image** in the PR
pipeline, which is prohibitively slow while the framework itself is still being iterated on.

To avoid that, the framework is rolled out **product-first**:

1. **Pilot in a single product image** — the framework source (`lib/`, `bin/entrypoint.sh`)
   is vendored under the product directory (e.g. `zookeeper/kubedoop/{lib,bin}`), and the
   tini install + framework deploy steps live in that product's `Dockerfile`. Only that one
   image rebuilds. **zookeeper** is the first pilot (a simple, zero-script product).
2. **Repeat for a few more products** to validate the contract across shapes (zero-script,
   product-entrypoint, complex-entrypoint).
3. **Extract upward into `kubedoop-base`** once proven. At that point the per-product
   `lib/`, `bin/`, and Dockerfile steps are removed in favour of inheritance — this is the
   original Phase 1 below, executed last instead of first.

The framework contents are identical in both placements; only the *layer* they live in
changes. This means a product piloting the framework today needs no code changes when the
extraction lands — its `Dockerfile` simply drops the now-inherited steps.

## Gradual Migration Path

> **Note**: Under the [product-first rollout](#rollout-strategy-product-first), Phase 1 is
> executed **last** (extraction into `kubedoop-base`), after the framework has been piloted
> in individual product images. The phases below describe the end-state layering.

### Phase 1: Infrastructure

- kubedoop-base installs chosen init system
- Deploy `lib/` (log.sh, run.sh, signal.sh) and `bin/entrypoint.sh`
- Create empty `mount/{pre-script,post-script}` directories

### Phase 2: Simple Products (Zero-script Products)

- trino — Remove custom CMD, inherit ENTRYPOINT
- kafka — Same as above
- zookeeper — Same as above

Validation: Signal delivery works correctly, shutdown behavior unchanged.

### Phase 3: Products with Entrypoints

- superset — Rename entrypoint to `start-superset.sh`, call via CMD
- airflow — Rename entrypoint to `start-airflow.sh`, call via CMD
- hive — Rename start-metastore to `start-metastore.sh`, call via CMD

### Phase 4: Runtime Injection

- Operator mounts ConfigMap into `/kubedoop/mount/pre-script/`
- Operator mounts ConfigMap into `/kubedoop/mount/post-script/`
- Scripts auto-discovered and executed

## Security: Runtime Script Isolation

Runtime script injection introduces a trust boundary: operators can inject arbitrary code that runs inside the container. The framework must ensure injected scripts cannot tamper with the framework itself or application files.

### Threat Model

| Threat | Target | Impact |
|--------|--------|--------|
| Framework tampering | `/kubedoop/bin/`, `/kubedoop/lib/` | Bypass signal handling, disable cleanup, modify behavior |
| Application tampering | `/kubedoop/app/`, product directories | Replace JARs, modify configs, inject malicious code |
| Sensitive data access | Credential files, secrets | Expose secrets to external systems |
| State file manipulation | `/kubedoop/run/` | Confuse sidecar coordination |

### Defense: File Ownership Separation

The core principle is **root owns, kubedoop executes**. Injected scripts run as `kubedoop` (UID 1001) and can only write to `/kubedoop/run/`.

```
Ownership:     root:root         root:root         root:root         root:root         kubedoop:kubedoop
Permissions:   0755              0755              0755              0755              0755
               ┌─── bin/         ┌─── lib/         ┌─── mount/       ┌─── app/         ┌─── run/
kubedoop user: │   read+exec     │   read+exec     │   read+exec     │   read+exec     │   read+write
               └─── ✗ write      └─── ✗ write      └─── ✗ write      └─── ✗ write      └─── ✓ write
```

### Kubernetes Layer: Read-Only Root Filesystem

For maximum protection, use Kubernetes `readOnlyRootFilesystem` and mount writable paths explicitly:

```yaml
securityContext:
  readOnlyRootFilesystem: true
  fsGroup: 1001

# Mount writable emptyDir for state files only
volumes:
  - name: pod-state
    emptyDir: {}
  - name: tmp
    emptyDir: {}    # Application tmp if needed

containers:
  - name: app
    volumeMounts:
      - name: pod-state
        mountPath: /kubedoop/run
      - name: tmp
        mountPath: /tmp
```

With `readOnlyRootFilesystem: true`:
- All container filesystem layers are immutable at runtime
- Only explicitly mounted volumes (emptyDir, ConfigMap) are writable
- Even if a script gains elevated privileges, it cannot modify the root filesystem
- Combined with file ownership, this provides defense-in-depth

### Defense-in-Depth Summary

| Layer | Mechanism | Protects Against |
|-------|-----------|-----------------|
| File ownership | `root:root 0755` on framework/app | kubedoop user cannot overwrite files |
| K8s security | `readOnlyRootFilesystem: true` | Runtime filesystem immutability |
| K8s security | `runAsNonRoot: true`, `runAsUser: 1001` | Container never runs as root |
| K8s security | `allowPrivilegeEscalation: false` | Scripts cannot gain root via setuid |
| Pod spec | Only `/kubedoop/run/` as emptyDir | Write surface limited to state files |

### Trust Boundary

The security model protects the **container image** (framework + application), not mounted volumes. The operator controls both injected scripts (ConfigMap content) and writable mount paths (Pod spec volumes). If the operator is malicious, they have more direct attack vectors (privileged containers, host mounts, etc.).

**What is protected**: Injected scripts cannot modify framework libraries, entrypoint, or application binaries — regardless of bugs or malicious intent in the scripts.

**What is NOT protected**: Writable paths explicitly mounted by the operator (log directories, PVC data, hostPath mounts). This is by design — the operator controls the trust boundary.

**State file protection** (deferred, ships with pod-state coordination): once state files are written, the entrypoint will clean stale/fake state files after pre-scripts run but before the main process starts (a `rm -f` step in entrypoint.sh). This prevents injected pre-scripts from poisoning sidecar coordination with fake `main.status` or `main.pid` values. Pre-scripts are trusted not to write state files between the cleanup and the real state writes (a sub-millisecond window). Until `lib/pod-state.sh` is deployed, no state files are written and this cleanup is not present.

## Architecture Relationship

```
+--------------------------------------------------------------+
|                  Kubernetes Operator Layer                    |
|  preStop lifecycle hook                                       |
|  terminationGracePeriodSeconds                                |
|  probes (readiness/liveness)                                  |
+--------------------------------------------------------------+
|                  Container Image Layer (This Design)          |
|  Init process (PID 1) -> entrypoint.sh -> "$@"                |
|  mount/{pre-script, post-script} (auto-discovered)           |
|  run/ (shared emptyDir for Pod coordination)                 |
+--------------------------------------------------------------+
|                  Application Layer                            |
|  Product entrypoint scripts (existing, unchanged)            |
|  JVM ShutdownHook / gunicorn worker lifecycle                 |
|  Application-native graceful shutdown logic                   |
+--------------------------------------------------------------+
```

Each layer has its own responsibility:

- **Operator layer** controls Pod lifecycle timing, runtime script injection, and sidecar coordination
- **Container layer** manages process signal delivery, mount script orchestration, and cross-container state
- **Application layer** handles product-specific initialization and business-logic-level cleanup

## Comparison with Current Approaches

| Aspect | Current | With This Design |
|--------|---------|-----------------|
| PID 1 | bash / app | Init process (tini / dumb-init) |
| Signal delivery | Depends on exec usage | Guaranteed via init (no -g) + explicit trap |
| Zombie reaping | None | Init process auto-wait |
| Entrypoint customization | Per-product shell script | Unchanged, product keeps its own |
| Graceful shutdown | Application-dependent only | SIGTERM forwarding + timeout + SIGKILL fallback |
| Runtime hooks | Requires image rebuild | mount/ volume mount (no rebuild) |
| Sidecar coordination | None (Pod stuck risk) | emptyDir state files + inotifywait |
| Cross-product consistency | Low (each product different) | High (shared signal + mount + state framework) |
