#!/bin/bash
# Lightweight source-level behavioral tests for the Hadoop-vendored entrypoint framework.
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
source "${LIB_DIR}/run.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/signal.sh"

KUBEDOOP_KILL_TIMEOUT=2
KUBEDOOP_MOUNT_DIR="${TMP_DIR}/mount"
mkdir -p "${KUBEDOOP_MOUNT_DIR}/pre-script" "${KUBEDOOP_MOUNT_DIR}/post-script"

test_normal_exit_code() {
    local expected
    for expected in 7 127 130 142 143; do
        run_lifecycle bash -c 'exit "$1"' bash "$expected"
        [[ "$EXIT_CODE" -eq "$expected" ]] || fail "expected normal exit code ${expected}, got ${EXIT_CODE}"
    done
    pass "normal main-process exit code is preserved"
}

test_main_stdin_is_preserved() {
    local output
    output=$(run_lifecycle cat <<< 'TEST_MAIN_STDIN')
    [[ "$output" == TEST_MAIN_STDIN ]] || fail "main stdin/stdout was changed by the framework"
    pass "background main process preserves stdin and clean stdout"
}

test_logging_uses_stderr() {
    local output stderr_file="${TMP_DIR}/framework-stderr"
    output=$({
        log_info TEST_INFO_DIAGNOSTIC
        KUBEDOOP_DEBUG=true log_debug TEST_DEBUG_DIAGNOSTIC
    } 2>"$stderr_file")
    [[ -z "$output" ]] || fail "framework diagnostics polluted stdout"
    grep -Fq '[INFO] TEST_INFO_DIAGNOSTIC' "$stderr_file" || fail "INFO diagnostic missing from stderr"
    grep -Fq '[DEBUG] TEST_DEBUG_DIAGNOSTIC' "$stderr_file" || fail "DEBUG diagnostic missing from stderr"
    pass "INFO and DEBUG diagnostics use stderr"
}

test_signals_during_cleanup() {
    local mode="$1"
    local markers="${TMP_DIR}/cleanup-${mode}"
    mkdir -p "$markers"

    (
        KUBEDOOP_KILL_TIMEOUT=10
        run_post_scripts() {
            touch "$markers/post-started"
            while [[ ! -e "$markers/post-release" ]]; do sleep 0.05; done
            echo post >> "$markers/post-done"
        }
        if [[ "$mode" == signal ]]; then
            run_lifecycle bash -c '
                trap '\''touch "$1/child-term"; while [[ ! -e "$1/child-release" ]]; do sleep 0.05; done; touch "$1/child-done"; exit 42'\'' TERM
                touch "$1/child-ready"
                while :; do sleep 0.05; done
            ' bash "$markers"
        else
            run_lifecycle bash -c 'exit 7'
        fi
        exit "$EXIT_CODE"
    ) &
    local lifecycle_pid=$!

    if [[ "$mode" == signal ]]; then
        wait_for_file "$markers/child-ready" || fail "child did not become ready"
        kill -TERM "$lifecycle_pid"
        wait_for_file "$markers/child-term" || fail "child did not receive initial SIGTERM"
        kill -TERM "$lifecycle_pid"
        touch "$markers/child-release"
    fi
    wait_for_file "$markers/post-started" || fail "post-script did not start"
    kill -TERM "$lifecycle_pid"
    touch "$markers/post-release"

    local rc=0
    wait "$lifecycle_pid" || rc=$?
    local expected=7
    if [[ "$mode" == signal ]]; then
        expected=42
        [[ -e "$markers/child-done" ]] || fail "child cleanup was interrupted"
    fi
    [[ "$rc" -eq "$expected" ]] || fail "cleanup signal changed exit code ${expected} to ${rc}"
    [[ "$(wc -l < "$markers/post-done")" -eq 1 ]] || fail "post-script did not finish exactly once"
    pass "shutdown signals do not interrupt ${mode}-driven cleanup"
}

test_sigterm_is_forwarded() {
    local expected="${1:-42}"
    local child_ready="${TMP_DIR}/child-ready-${expected}"
    local child_term="${TMP_DIR}/child-term-${expected}"

    (
        source "${LIB_DIR}/log.sh"
        source "${LIB_DIR}/run.sh"
        source "${LIB_DIR}/signal.sh"
        KUBEDOOP_KILL_TIMEOUT=2
        KUBEDOOP_MOUNT_DIR="${TMP_DIR}/missing-hooks"
        run_lifecycle bash -c '
            trap "echo term > \"$1\"; exit $3" TERM
            echo ready > "$2"
            while :; do sleep 1; done
        ' bash "$child_term" "$child_ready" "$expected"
        exit "$EXIT_CODE"
    ) &
    local lifecycle_pid=$!

    wait_for_file "$child_ready" || fail "child did not report readiness"
    kill -TERM "$lifecycle_pid"

    local rc=0
    wait "$lifecycle_pid" || rc=$?

    [[ "$rc" -eq "$expected" ]] || fail "expected lifecycle exit code ${expected} after forwarded SIGTERM, got ${rc}"
    grep -qx 'term' "$child_term" || fail "child did not receive forwarded SIGTERM"
    pass "SIGTERM is forwarded and child exit code is preserved"
}

test_sigkill_after_timeout() {
    local child_ready="${TMP_DIR}/ignore-ready"

    (
        source "${LIB_DIR}/log.sh"
        source "${LIB_DIR}/run.sh"
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

test_exited_child_status_127() {
    # Cover a child that exits before shutdown reaches stop_process.
    bash -c 'exit 127' &
    local child_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        kill -0 "$child_pid" 2>/dev/null || break
        sleep 0.01
    done
    stop_process "$child_pid" 1
    [[ "$STOP_REAPED" -eq 1 && "$STOP_EXIT_CODE" -eq 127 ]] ||
        fail "already-exited child status 127 was lost"
    pass "status 127 is preserved when the child has already exited"
}

test_root_owned_scripts_when_possible() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "skip - root-owned script execution requires running this test as root"
        return 0
    fi

    local scripts_dir="${TMP_DIR}/scripts"
    local marker="${TMP_DIR}/script-order"
    mkdir -p "$scripts_dir"

    cat > "${scripts_dir}/20-second.sh" <<EOF
#!/bin/bash
echo second >> "${marker}"
EOF
    cat > "${scripts_dir}/10-first.sh" <<EOF
#!/bin/bash
echo first >> "${marker}"
EOF
    chmod 0755 "${scripts_dir}/10-first.sh" "${scripts_dir}/20-second.sh"

    _run_scripts "test" "$scripts_dir" || fail "root-owned scripts failed"

    local order
    order=$(tr '\n' ',' < "$marker")
    [[ "$order" == "first,second," ]] || fail "expected sorted script execution, got ${order}"
    pass "root-owned executable scripts run in sorted order"
}

test_script_discovery_failure_is_propagated() {
    local original_discover_scripts
    original_discover_scripts=$(declare -f _discover_scripts)

    _discover_scripts() {
        return 23
    }

    if run_pre_scripts; then
        fail "script discovery failure was reported as success"
    fi

    eval "$original_discover_scripts"
    pass "script discovery failure aborts the pre-script run"
}

test_logging_uses_stderr
test_normal_exit_code
test_main_stdin_is_preserved
test_sigterm_is_forwarded
test_sigterm_is_forwarded 127
test_signals_during_cleanup signal
test_signals_during_cleanup normal
test_sigkill_after_timeout
test_exited_child_status_127
test_root_owned_scripts_when_possible
test_script_discovery_failure_is_propagated
