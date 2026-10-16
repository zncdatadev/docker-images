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
