#!/bin/bash
# /kubedoop/lib/run-phase.sh -- Script auto-discovery and execution
#
# Discovers and executes .sh scripts in a directory, sorted by filename.
# Used for pre-script and post-script lifecycle phases.

# Discover executable .sh scripts in a directory, sorted by filename.
#
# Arguments:
#   $1 - Directory path to scan
#
# Output:
#   stdout - Sorted list of matching script paths (one per line), empty if none found
#
# Returns:
#   0 - Always (missing directory is not an error)
discover_scripts() {
    local phase_dir="$1"

    if [[ ! -d "$phase_dir" ]]; then
        return 0
    fi

    # Only match .sh files that have any execute bit set (owner, group, or other).
    # Note: -executable is GNU find specific (not BSD/macOS). Acceptable here since
    # the target environment is ubi9-minimal (Linux, GNU findutils).
    # With ConfigMap defaultMode: 0755, this correctly matches all executable scripts.
    # SECURITY: Only execute scripts owned by root (uid 0) to prevent injection
    # from non-root writable volumes (emptyDir, PVC, hostPath).
    find "$phase_dir" -maxdepth 1 -type f -name '*.sh' -executable \
        -uid 0 \
        | sort
}

# Execute all discovered scripts in a phase directory sequentially.
# Script execution order is determined by filename sort order.
# First script failure aborts the phase immediately.
#
# Arguments:
#   $1 - Phase name (for logging, e.g., "pre-script", "post-script")
#   $2 - Directory containing executable .sh scripts
#
# Returns:
#   0 - All scripts succeeded, or no scripts found
#   1 - A script failed, or script discovery failed
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
