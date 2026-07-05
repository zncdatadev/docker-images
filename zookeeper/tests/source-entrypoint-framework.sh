#!/bin/bash
# Lightweight source-level behavioral tests for the zookeeper-vendored entrypoint framework.
#
# These tests source the framework libraries directly from the working tree so
# they can validate lifecycle logic without requiring a full container image
# build. Use image-entrypoint-framework.sh after building the image to validate
# final container wiring.
#
# Keep this aligned with the entrypoint itself: no `set -e`. The lifecycle
# functions intentionally inspect non-zero wait statuses.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRODUCT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
LIB_DIR="${PRODUCT_DIR}/kubedoop/lib"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
    echo "not ok - $*" >&2
    exit 1
}

pass() {
    echo "ok - $*"
}

wait_for_file() {
    local path="$1"
    local timeout="${2:-5}"
    local elapsed=0

    while [[ ! -e "$path" && $elapsed -lt $timeout ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    [[ -e "$path" ]]
}

# shellcheck source=/dev/null
source "${LIB_DIR}/log.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/run-phase.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/signal.sh"

KUBEDOOP_KILL_TIMEOUT=2
KUBEDOOP_MOUNT_DIR="${TMP_DIR}/mount"
mkdir -p "${KUBEDOOP_MOUNT_DIR}/pre-script" "${KUBEDOOP_MOUNT_DIR}/post-script"

test_normal_exit_code() {
    EXIT_CODE=0
    run_lifecycle bash -c 'exit 7'
    [[ "$EXIT_CODE" -eq 7 ]] || fail "expected normal exit code 7, got ${EXIT_CODE}"
    pass "normal main-process exit code is preserved"
}

test_sigterm_is_forwarded() {
    local child_ready="${TMP_DIR}/child-ready"
    local child_term="${TMP_DIR}/child-term"

    (
        source "${LIB_DIR}/log.sh"
        source "${LIB_DIR}/run-phase.sh"
        source "${LIB_DIR}/signal.sh"
        KUBEDOOP_KILL_TIMEOUT=2
        KUBEDOOP_MOUNT_DIR="${TMP_DIR}/missing-hooks"
        run_lifecycle bash -c '
            trap "echo term > \"$1\"; exit 42" TERM
            echo ready > "$2"
            while :; do sleep 1; done
        ' bash "$child_term" "$child_ready"
        exit "$EXIT_CODE"
    ) &
    local lifecycle_pid=$!

    wait_for_file "$child_ready" || fail "child did not report readiness"
    kill -TERM "$lifecycle_pid"

    local rc=0
    wait "$lifecycle_pid" || rc=$?

    [[ "$rc" -eq 42 ]] || fail "expected lifecycle exit code 42 after forwarded SIGTERM, got ${rc}"
    grep -qx 'term' "$child_term" || fail "child did not receive forwarded SIGTERM"
    pass "SIGTERM is forwarded and child exit code is preserved"
}

test_sigkill_after_timeout() {
    local child_ready="${TMP_DIR}/ignore-ready"

    (
        source "${LIB_DIR}/log.sh"
        source "${LIB_DIR}/run-phase.sh"
        source "${LIB_DIR}/signal.sh"
        KUBEDOOP_KILL_TIMEOUT=1
        KUBEDOOP_MOUNT_DIR="${TMP_DIR}/missing-hooks"
        run_lifecycle bash -c '
            trap "" TERM
            echo ready > "$1"
            while :; do sleep 1; done
        ' bash "$child_ready"
        exit "$EXIT_CODE"
    ) &
    local lifecycle_pid=$!

    wait_for_file "$child_ready" || fail "TERM-ignoring child did not report readiness"
    kill -TERM "$lifecycle_pid"

    local rc=0
    wait "$lifecycle_pid" || rc=$?

    [[ "$rc" -eq 137 ]] || fail "expected lifecycle exit code 137 after SIGKILL escalation, got ${rc}"
    pass "SIGKILL escalation occurs after KUBEDOOP_KILL_TIMEOUT"
}

test_root_owned_phase_scripts_when_possible() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "skip - root-owned phase script execution requires running this test as root"
        return 0
    fi

    local phase_dir="${TMP_DIR}/phase"
    local marker="${TMP_DIR}/phase-order"
    mkdir -p "$phase_dir"

    cat > "${phase_dir}/20-second.sh" <<EOF
#!/bin/bash
echo second >> "${marker}"
EOF
    cat > "${phase_dir}/10-first.sh" <<EOF
#!/bin/bash
echo first >> "${marker}"
EOF
    chmod 0755 "${phase_dir}/10-first.sh" "${phase_dir}/20-second.sh"

    run_phase "test-phase" "$phase_dir" || fail "root-owned phase scripts failed"

    local order
    order=$(tr '\n' ',' < "$marker")
    [[ "$order" == "first,second," ]] || fail "expected sorted phase execution, got ${order}"
    pass "root-owned executable phase scripts run in sorted order"
}

test_normal_exit_code
test_sigterm_is_forwarded
test_sigkill_after_timeout
test_root_owned_phase_scripts_when_possible
