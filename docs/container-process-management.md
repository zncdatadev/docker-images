# Container Process Management Design

> **Status**: Draft — Init system (tini / dumb-init / others) not yet finalized.

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

1. **Must ultimately `exec` into the long-running process** — not fork+exit. The universal framework tracks the main process PID; if the product entrypoint forks and exits, the PID tracking breaks.
2. **Must not install its own SIGTERM trap** — the universal framework owns signal handling.
3. **Path convention**: product-specific entrypoints must live at `/kubedoop/bin/product-entrypoint.sh` (or any path other than `/kubedoop/bin/entrypoint.sh`) to avoid collision with the universal framework.

Example:
```
Universal framework: /kubedoop/bin/entrypoint.sh  (deployed by kubedoop-base)
Product entrypoint:  /kubedoop/bin/start-app.sh   (product-specific, any name except entrypoint.sh)
```

## Directory Layout

```
/kubedoop/
├── bin/
│   └── entrypoint.sh              # Universal entrypoint (shared across all images)
├── lib/
│   ├── log.sh                     # Logging functions
│   ├── run-phase.sh               # Script discovery and execution engine
│   └── pod-state.sh               # Pod state file management
├── mount/                         # Runtime injection layer (fixed mount points)
│   ├── pre-script/                # Scripts to run before main process (auto-discovered)
│   │   └── (empty by default — populated by K8s Volume mount at runtime)
│   └── post-script/               # Scripts to run after main process exits (auto-discovered)
│       └── (empty by default — populated by K8s Volume mount at runtime)
├── app/                           # Application files
└── run/                           # Shared Pod state (mounted via emptyDir)
    ├── main.pid                   # Main process PID (written on startup)
    ├── main.status                # running → stopping → stopped
    └── main.exit_code             # Exit code (written on exit)
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
|  |  [2] run_phase mount/pre-script     Runtime pre-hooks   | |
|  |  [3] write_state running            Signal to sidecars  | |
|  |  [4] trap SIGTERM -> cleanup         Register handler   | |
|  |  [5] "$@" &                          Start main process | |
|  |  [6] write_pid $MAIN_PID            Publish PID         | |
|  |  [7] wait $MAIN_PID                  Wait               | |
|  |                                                         | |
|  |  -- On SIGTERM received --                              | |
|  |  [8] write_state stopping           Signal to sidecars  | |
|  |  [9] kill -TERM $MAIN_PID            Forward signal     | |
|  |  [10] wait $MAIN_PID                 Wait for exit      | |
|  |  [11] write_state stopped            Signal to sidecars | |
|  |  [12] run_phase mount/post-script    Runtime post-hooks | |
|  |  [13] exit $EXIT_CODE                Propagate exit     | |
|  +---------------------------------------------------------+ |
+--------------------------------------------------------------+
```

## Implementation

> **Note on error handling**: The entrypoint uses `set -uo pipefail` (without `-e`).
> Signal-aware shell scripts must not use `set -e` because trap handlers and `set -e`
> interact unpredictably. All error handling is explicit.

### lib/log.sh — Unified Logging

```bash
#!/bin/bash
# /kubedoop/lib/log.sh — Unified log output

__KUBEDOOP_LOG_PREFIX="${__KUBEDOOP_LOG_PREFIX:-kubedoop}"

_kubedoop_log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf "[%s] [%s] [%s] %s\n" "$timestamp" "$__KUBEDOOP_LOG_PREFIX" "$level" "$*"
}

log_info()  { _kubedoop_log "INFO"  "$@"; }
log_warn()  { _kubedoop_log "WARN"  "$@"; }
log_error() { _kubedoop_log "ERROR" "$@"; }
log_debug() { [[ "${KUBEDOOP_DEBUG:-false}" == "true" ]] && _kubedoop_log "DEBUG" "$@"; }
```

### lib/run-phase.sh — Script Discovery and Execution Engine

```bash
#!/bin/bash
# /kubedoop/lib/run-phase.sh — Script auto-discovery and execution

# Discover executable scripts in a directory, sorted by filename
# Output: sorted list of script paths (one per line)
discover_scripts() {
    local phase_dir="$1"

    if [[ ! -d "$phase_dir" ]]; then
        return 0
    fi

    # Only match .sh suffix + executable permission + regular file
    find "$phase_dir" -maxdepth 1 -type f -name '*.sh' -perm -u+x \
        | sort
}

# Run scripts sequentially (for pre-script / post-script)
# Any script failure aborts the phase
run_phase() {
    local phase_name="$1"
    local phase_dir="$2"

    local scripts
    scripts=$(discover_scripts "$phase_dir") || {
        log_error "Phase '$phase_name': failed to discover scripts in $phase_dir"
        return 1
    }

    if [[ -z "$scripts" ]]; then
        log_info "Phase '$phase_name': no scripts found in $phase_dir"
        return 0
    fi

    log_info "Phase '$phase_name' starting..."

    local count=0
    while IFS= read -r script; do
        local name
        name=$(basename "$script")
        log_info "Phase '$phase_name': running $name"
        count=$((count + 1))

        local rc=0
        "$script" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "Phase '$phase_name': $name failed with exit code $rc"
            return 1
        fi
    done <<< "$scripts"

    log_info "Phase '$phase_name': completed ($count scripts)"
    return 0
}
```

### lib/pod-state.sh — Pod State File Management

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

KUBEDOOP_RUN_DIR="${KUBEDOOP_RUN_DIR:-${KUBEDOOP_HOME}/run}"

# Atomic write: write to tmp file, then rename
# rename(2) is atomic on the same filesystem (including tmpfs/emptyDir)
_atomic_write() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp.$$"
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$target"
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

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # Check current state
        if [[ -f "${KUBEDOOP_RUN_DIR}/main.status" ]] \
            && [[ "$(cat "${KUBEDOOP_RUN_DIR}/main.status" 2>/dev/null)" == "$expected" ]]; then
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
        elapsed=$((elapsed + 1))
    done

    log_error "Timeout waiting for main.status = $expected (${timeout}s)"
    return 1
}
```

### bin/entrypoint.sh — Universal Container Entry

```bash
#!/bin/bash
# /kubedoop/bin/entrypoint.sh — Universal container entrypoint
#
# Note: Uses set -uo pipefail WITHOUT -e.
# Signal-aware scripts must not use set -e because trap handlers
# and set -e interact unpredictably. All error handling is explicit.
set -uo pipefail

export KUBEDOOP_HOME="${KUBEDOOP_HOME:-/kubedoop}"
export KUBEDOOP_MOUNT_DIR="${KUBEDOOP_MOUNT_DIR:-${KUBEDOOP_HOME}/mount}"
export KUBEDOOP_RUN_DIR="${KUBEDOOP_RUN_DIR:-${KUBEDOOP_HOME}/run}"

# Ensure run directory exists with correct permissions
mkdir -p "${KUBEDOOP_RUN_DIR}"

# Load common libraries
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

# --- Signal handling and graceful shutdown ---
MAIN_PID=""
EXIT_CODE=0
_CLEANUP_RUNNING=0

cleanup() {
    # Prevent re-entrant execution (trap + fallthrough race)
    if [[ "${_CLEANUP_RUNNING}" -eq 1 ]]; then
        return 0
    fi
    _CLEANUP_RUNNING=1

    log_info "Received shutdown signal"

    # Notify sidecars: main container is stopping
    write_state "stopping"

    # Forward SIGTERM to main process
    if [[ -n "$MAIN_PID" ]] && kill -0 "$MAIN_PID" 2>/dev/null; then
        log_info "Forwarding SIGTERM to main process (PID: $MAIN_PID)"
        kill -TERM "$MAIN_PID" 2>/dev/null || true

        # Wait for main process to exit (with timeout protection)
        local timeout="${KUBEDOOP_SHUTDOWN_TIMEOUT:-30}"
        local elapsed=0
        while kill -0 "$MAIN_PID" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done

        # Force kill on timeout
        if kill -0 "$MAIN_PID" 2>/dev/null; then
            log_warn "Main process did not exit in ${timeout}s, sending SIGKILL"
            kill -KILL "$MAIN_PID" 2>/dev/null || true
        fi
    fi

    # Notify sidecars: main container has stopped
    write_state "stopped"

    # Phase 2: Runtime post-script hooks (auto-discovered from mount)
    run_phase "post-script" "${KUBEDOOP_MOUNT_DIR}/post-script" || true

    log_info "Shutdown complete"
}

trap cleanup SIGTERM SIGINT

# --- Start main process ---
if [[ $# -eq 0 ]]; then
    log_error "No command specified"
    exit 1
fi

write_state "running"

"$@" &
MAIN_PID=$!
write_pid "$MAIN_PID"
log_info "Main process started (PID: $MAIN_PID): $*"

# Wait for main process to exit
wait $MAIN_PID || EXIT_CODE=$?
write_exit_code "$EXIT_CODE"

# Run cleanup (if not already triggered by signal trap)
cleanup

exit $EXIT_CODE
```

### kubedoop-base/Dockerfile Integration

```dockerfile
# Append to existing kubedoop-base Dockerfile

# Install init system (e.g., tini, dumb-init — to be decided)
RUN <<EOF
    microdnf install tini
EOF

# Deploy universal entrypoint framework
COPY kubedoop/lib/ /kubedoop/lib/
COPY kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chmod +x /kubedoop/bin/entrypoint.sh \
    && mkdir -p /kubedoop/mount/{pre-script,post-script} \
    && chown -R kubedoop:kubedoop /kubedoop/mount/ \
    && chmod -R 0755 /kubedoop/mount/

# Init process as PID 1
# No -g flag: init forwards signals only to direct child process.
# The entrypoint.sh manages signal propagation explicitly via trap.
#
# tini:      ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
# dumb-init: ENTRYPOINT ["dumb-init", "--", "/kubedoop/bin/entrypoint.sh"]
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
- The entrypoint framework auto-discovers all `*.sh` files with execute permission
- Scripts are sorted by filename and executed sequentially
- No volume mount = no scripts discovered = zero-intrusion

### Important: Script Failure Behavior

- **pre-script failure**: Aborts startup. The main process will NOT start. This is a fail-fast design.
- **post-script failure**: Logged but ignored (post-scripts run with `|| true`). Cleanup continues.
- Operators should test injected scripts in non-production environments before deploying to production.

### Important: ConfigMap Permission Contract

Scripts are discovered only if they have the **owner-execute bit** set (`-perm -u+x`). When using ConfigMap volumes:

- Always set `defaultMode: 0755` on the ConfigMap volume source
- When using `items:` with per-item `mode:`, ensure each script item has mode `0755`
- Projected volumes and downward API volumes follow the same rule

If scripts are found in the directory but none have execute permission, the framework logs an info message and proceeds as if no scripts were found.

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

# Wait for main container to be ready
# Also exits early if main.exit_code appears (main container crashed during startup)
wait_for_state "running" "${KUBEDOOP_STARTUP_TIMEOUT:-120}" || {
    log_error "Main container did not reach 'running' state within timeout"
    exit 1
}
log_info "Main container is running"

# Start sidecar main process (e.g., vector)
vector --config /etc/vector/vector.toml &
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
        log_info "Sidecar process exited"
        ;;
    legacy)
        # Pre-1.28: Wait for main container to fully stop, then exit voluntarily.
        # Without this, the sidecar would keep running and the Pod would never terminate.
        wait_for_state "stopped" "${KUBEDOOP_SHUTDOWN_TIMEOUT:-30}" || true
        log_info "Main container stopped, terminating sidecar"
        kill -TERM "$SIDECAR_PID" 2>/dev/null || true
        wait "$SIDECAR_PID" 2>/dev/null || true
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

## Gradual Migration Path

### Phase 1: Infrastructure

- kubedoop-base installs chosen init system
- Deploy `lib/` and `bin/entrypoint.sh`
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
