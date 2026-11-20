#!/bin/bash
# Validate the built trino image's entrypoint framework wiring.
#
# This is an image-level companion to source-entrypoint-framework.sh. It should
# be run after `make trino-build` and tests the final container behavior.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRODUCT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd "${PRODUCT_DIR}/.." && pwd)

DEFAULT_REGISTRY="${REGISTRY:-quay.io/zncdatadev}"
DEFAULT_KUBEDOOP_VERSION="${KUBEDOOP_VERSION:-0.0.0-dev}"
DEFAULT_PRODUCT_VERSION="451"
if [[ -f "${PRODUCT_DIR}/versions.yaml" ]]; then
    DEFAULT_PRODUCT_VERSION=$(awk '
        $1 == "-" && $2 == "product:" {
            print $3
            exit
        }
        $1 == "product:" {
            print $2
            exit
        }
    ' "${PRODUCT_DIR}/versions.yaml")
fi

IMAGE="${1:-${DEFAULT_REGISTRY}/trino:${DEFAULT_PRODUCT_VERSION}-kubedoop${DEFAULT_KUBEDOOP_VERSION}}"
TMP_DIR=$(mktemp -d)
TEST_IMAGE=""
CONTAINER_IDS=()

cleanup() {
    local cid
    for cid in "${CONTAINER_IDS[@]}"; do
        docker rm -f "$cid" >/dev/null 2>&1 || true
    done
    if [[ -n "$TEST_IMAGE" ]]; then
        docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "not ok - $*" >&2
    exit 1
}

pass() {
    echo "ok - $*"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if ! grep -Fq "$needle" <<<"$haystack"; then
        echo "$haystack" >&2
        fail "$message"
    fi
}

wait_for_log() {
    local cid="$1"
    local pattern="$2"
    local timeout="${3:-10}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if docker logs "$cid" 2>&1 | grep -F "$pattern" >/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    docker logs "$cid" 2>&1 || true
    return 1
}

run_expect_status() {
    local expected="$1"
    shift

    local rc=0
    "$@"
    rc=$?

    [[ "$rc" -eq "$expected" ]] || fail "expected exit code ${expected}, got ${rc}: $*"
}

test_image_exists() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image not found locally: ${IMAGE}"
    pass "image exists locally: ${IMAGE}"
}

test_entrypoint_metadata() {
    local metadata
    metadata=$(docker image inspect \
        --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{.Config.User}}' \
        "$IMAGE")

    assert_contains "$metadata" '["tini","--","/kubedoop/bin/entrypoint.sh"]' "unexpected image ENTRYPOINT"
    assert_contains "$metadata" '["launcher","run"]' "unexpected image CMD"
    assert_contains "$metadata" 'kubedoop' "unexpected image USER"
    pass "image metadata wires tini and the universal entrypoint"
}

test_runtime_files_and_user() {
    docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
        set -euo pipefail
        test "$(id -un)" = "kubedoop"
        command -v setsid
        test -x /usr/bin/tini
        test -x /kubedoop/bin/entrypoint.sh
        test -x /kubedoop/lib/log.sh
        test -x /kubedoop/lib/run.sh
        test -x /kubedoop/lib/signal.sh
        test "$(stat -c "%u:%a" /kubedoop/bin/entrypoint.sh)" = "0:755"
        test "$(stat -c "%u:%a" /kubedoop/lib/signal.sh)" = "0:755"
        # Preserve HOME writes, but prevent replacement of root-owned framework
        # directories through the root-owned sticky parent.
        test "$(stat -c "%u:%a" /kubedoop)" = "0:1770"
        marker=$(mktemp -d "$HOME/.home-write-test.XXXXXX")
        rmdir "$marker"
        for directory in /kubedoop/bin /kubedoop/lib /kubedoop/mount; do
            test "$(stat -c "%u:%a" "$directory")" = "0:755"
            test ! -w "$directory"
            if mv "$directory" "/kubedoop/run/replaced-${directory##*/}" 2>/dev/null; then
                echo "runtime user replaced a framework directory" >&2
                exit 1
            fi
        done
        test -w /kubedoop/run
    ' || fail "runtime file layout or permissions are invalid"

    pass "runtime files, ownership, and kubedoop user are valid"
}

test_runtime_source_hashes() {
    local file expected actual
    for file in bin/entrypoint.sh lib/log.sh lib/run.sh lib/signal.sh; do
        expected=$(sha256sum "$PRODUCT_DIR/kubedoop/$file" | awk '{print $1}')
        actual=$(docker run --rm --entrypoint sha256sum "$IMAGE" "/kubedoop/$file" | awk '{print $1}')
        [[ $actual == "$expected" ]] || fail "stale runtime source $file"
    done
    pass 'installed runtime sources match the tested worktree'
}

test_exit_code_propagation() {
    run_expect_status 7 docker run --rm "$IMAGE" bash -c 'exit 7'
    run_expect_status 127 docker run --rm "$IMAGE" bash -c 'exit 127'
    pass "entrypoint preserves main process exit code"
}

test_main_stdin_is_preserved() {
    local output
    output=$(printf '%s\n' TEST_MAIN_STDIN | docker run --rm -i "$IMAGE" cat) || fail "stdin test failed"
    [[ "$output" == TEST_MAIN_STDIN ]] || fail "main stdin/stdout was changed by the entrypoint"
    output=$(docker run --rm -e KUBEDOOP_DEBUG=true "$IMAGE" bash -c 'printf "%s\\n" "{\"value\":42}"') || fail "structured stdout test failed"
    [[ "$output" == '{"value":42}' ]] || fail "framework diagnostics polluted structured stdout"
    output=$(printf '%s\n' ROOT_STDIN | docker run --rm -i --user root "$IMAGE" cat) || fail 'root stdin failed'
    [[ "$output" == ROOT_STDIN ]] || fail 'root stdout changed'
    pass "main stdin and structured stdout are preserved"
}

build_script_test_image() {
    TEST_IMAGE="trino-entrypoint-test:$(date +%s)-$$"
    mkdir -p "${TMP_DIR}/scripts"

    cat >"${TMP_DIR}/scripts/10-pre.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
cat >/dev/null
if [[ "${TEST_FAIL_PRE:-false}" == true ]]; then exit 23; fi
echo pre-script-marker > /kubedoop/run/pre-script-marker
echo TEST_PRE_SCRIPT_RAN
EOF

    cat >"${TMP_DIR}/scripts/10-post.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
test -f /kubedoop/run/pre-script-marker || exit 1
if [[ "${TEST_FAIL_POST:-false}" == true ]]; then exit 23; fi
if [[ "${TEST_REQUIRE_CHILD_CLEANUP:-false}" == true ]]; then
    test -f /kubedoop/run/child-cleanup-done || exit 1
fi
if [[ "${TEST_REQUIRE_GROUP_CLEANUP:-false}" == true ]]; then
    source /kubedoop/lib/signal.sh
    group=$(cat /kubedoop/run/main-group)
    [[ "$group" =~ ^[1-9][0-9]*$ ]] || exit 1
    if _group_has_live_processes "$group"; then exit 1; fi
fi
if [[ "${TEST_WAIT_POST:-false}" == true ]]; then
    echo TEST_POST_STARTED
    while [[ ! -e /kubedoop/run/post-release ]]; do sleep 0.05; done
fi
echo TEST_POST_SCRIPT_RAN
EOF

    chmod 0755 "${TMP_DIR}/scripts/10-pre.sh" "${TMP_DIR}/scripts/10-post.sh"

    cat >"${TMP_DIR}/scripts/20-pre.sh" <<'EOF'
#!/bin/bash
echo TEST_SECOND_PRE_SCRIPT_RAN
EOF

    cat >"${TMP_DIR}/Dockerfile" <<EOF
FROM ${IMAGE}
USER root
COPY --chown=root:root scripts/10-pre.sh /kubedoop/mount/pre-script/..version/10-pre.sh
COPY --chown=root:root scripts/20-pre.sh /kubedoop/mount/pre-script/..version/20-pre.sh
COPY --chown=root:root scripts/10-post.sh /kubedoop/mount/post-script/..version/10-post.sh
RUN chmod 0755 /kubedoop/mount/pre-script/..version/*.sh /kubedoop/mount/post-script/..version/*.sh \
    && ln -s ..version /kubedoop/mount/pre-script/..data \
    && ln -s ..data/10-pre.sh /kubedoop/mount/pre-script/10-pre.sh \
    && ln -s ..data/20-pre.sh /kubedoop/mount/pre-script/20-pre.sh \
    && ln -s ..version /kubedoop/mount/post-script/..data \
    && ln -s ..data/10-post.sh /kubedoop/mount/post-script/10-post.sh
USER kubedoop
EOF

    docker build -q -t "$TEST_IMAGE" "$TMP_DIR" >/dev/null || fail "failed to build script test image"
}

test_root_owned_scripts_execute() {
    build_script_test_image

    local output
    output=$(docker run --rm "$TEST_IMAGE" bash -c '
        test -f /kubedoop/run/pre-script-marker || exit 1
        echo TEST_MAIN_RAN
    ' 2>&1) || {
        echo "$output" >&2
        fail "root-owned script image run failed"
    }

    assert_contains "$output" "TEST_PRE_SCRIPT_RAN" "pre-script did not run"
    assert_contains "$output" "TEST_SECOND_PRE_SCRIPT_RAN" "stdin-reading pre-script skipped the next script"
    assert_contains "$output" "TEST_MAIN_RAN" "main command did not run after pre-script"
    assert_contains "$output" "TEST_POST_SCRIPT_RAN" "post-script did not run"
    local order
    order=$(grep -E '^(TEST_PRE_SCRIPT_RAN|TEST_SECOND_PRE_SCRIPT_RAN|TEST_MAIN_RAN|TEST_POST_SCRIPT_RAN)$' <<< "$output")
    [[ "$order" == $'TEST_PRE_SCRIPT_RAN\nTEST_SECOND_PRE_SCRIPT_RAN\nTEST_MAIN_RAN\nTEST_POST_SCRIPT_RAN' ]] || fail "hooks and main command ran out of order or more than once"
    pass "ConfigMap-style pre/post scripts execute; stdin readers do not skip the next script"
}

test_sigterm_is_forwarded() {
    local expected="${1:-42}"
    local cid
    cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=2 "$IMAGE" bash -c '
        trap "echo TEST_CHILD_TERM; exit $1" TERM
        echo TEST_CHILD_READY
        while :; do sleep 1; done
    ' bash "$expected") || fail "failed to start signal test container"
    CONTAINER_IDS+=("$cid")

    wait_for_log "$cid" "TEST_CHILD_READY" 10 || fail "signal test container did not become ready"
    docker stop -t 5 "$cid" >/dev/null || fail "docker stop failed for signal test container"

    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || true)
    [[ "$exit_code" == "$expected" ]] || fail "expected container exit code ${expected} after forwarded SIGTERM, got ${exit_code}"

    local logs
    logs=$(docker logs "$cid" 2>&1 || true)
    assert_contains "$logs" "TEST_CHILD_TERM" "child did not log SIGTERM handling"
    pass "SIGTERM reaches the main process through tini and the entrypoint"
}

test_hook_failure_behavior() {
    local output rc=0
    output=$(docker run --rm -e TEST_FAIL_PRE=true "$TEST_IMAGE" bash -c 'echo TEST_UNEXPECTED_MAIN' 2>&1) || rc=$?
    [[ "$rc" == 1 ]] || fail "pre-script failure did not abort startup"
    assert_contains "$output" "Pre-scripts failed, aborting startup" "pre-script failure was not reported"
    if grep -Eq 'TEST_UNEXPECTED_MAIN|TEST_POST_SCRIPT_RAN' <<< "$output"; then
        fail "main process or post-script ran after pre-script failure"
    fi
    rc=0
    output=$(docker run --rm -e TEST_FAIL_POST=true "$TEST_IMAGE" bash -c 'exit 7' 2>&1) || rc=$?
    [[ "$rc" == 7 ]] || fail "post-script failure overwrote the application exit status"
    assert_contains "$output" "failed with exit code 23" "post-script failure was not reported"
    assert_contains "$output" "Shutdown complete" "post-script failure prevented cleanup completion"
    pass "pre-script failures abort startup; post-script failures preserve application status"
}

test_sigkill_after_timeout() {
    local cid
    cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=1 "$IMAGE" bash -c '
        trap "" TERM
        echo TEST_IGNORE_READY
        while :; do sleep 1; done
    ') || fail "failed to start SIGKILL escalation test container"
    CONTAINER_IDS+=("$cid")

    wait_for_log "$cid" "TEST_IGNORE_READY" 10 || fail "SIGKILL escalation test container did not become ready"
    docker stop -t 5 "$cid" >/dev/null || fail "docker stop failed for SIGKILL escalation test container"

    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || true)
    [[ "$exit_code" == "137" ]] || fail "expected container exit code 137 after SIGKILL escalation, got ${exit_code}"
    pass "SIGKILL escalation works in the final image"
}

test_signals_during_cleanup() {
    local mode="$1"
    local cid expected output
    if [[ "$mode" == signal ]]; then
        expected=42
        cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=10 -e TEST_WAIT_POST=true \
            -e TEST_REQUIRE_CHILD_CLEANUP=true "$TEST_IMAGE" bash -c '
                trap '\''echo TEST_CHILD_TERM; while [[ ! -e /kubedoop/run/child-release ]]; do sleep 0.05; done; touch /kubedoop/run/child-cleanup-done; exit 42'\'' TERM
                echo TEST_CHILD_READY
                while :; do sleep 0.05; done
            ') || fail "failed to start cleanup signal test"
    else
        expected=7
        cid=$(docker run -d -e TEST_WAIT_POST=true "$TEST_IMAGE" bash -c 'exit 7') || fail "failed to start normal cleanup test"
    fi
    CONTAINER_IDS+=("$cid")

    if [[ "$mode" == signal ]]; then
        wait_for_log "$cid" TEST_CHILD_READY || fail "cleanup test child did not become ready"
        docker kill --signal TERM "$cid" >/dev/null || fail "initial SIGTERM failed"
        wait_for_log "$cid" TEST_CHILD_TERM || fail "child did not receive SIGTERM"
        docker kill --signal TERM "$cid" >/dev/null || fail "repeated SIGTERM failed"
        docker kill --signal INT "$cid" >/dev/null || fail "repeated SIGINT failed"
        docker exec "$cid" touch /kubedoop/run/child-release || fail "child cleanup was interrupted"
    fi
    wait_for_log "$cid" TEST_POST_STARTED || fail "post-script did not start"
    docker kill --signal TERM "$cid" >/dev/null || fail "SIGTERM during post-script failed"
    docker kill --signal INT "$cid" >/dev/null || fail "SIGINT during post-script failed"
    docker exec "$cid" touch /kubedoop/run/post-release || fail "post-script was interrupted"

    output=$(timeout 15 docker wait "$cid") || fail "cleanup did not finish"
    [[ "$output" == "$expected" ]] || fail "expected cleanup exit code ${expected}, got ${output}"
    output=$(docker logs "$cid" 2>&1)
    [[ "$(grep -xc TEST_POST_SCRIPT_RAN <<< "$output")" == 1 ]] || fail "post-script did not finish exactly once"
    assert_contains "$output" "Shutdown complete" "shutdown cleanup was interrupted"
    pass "SIGTERM/SIGINT do not interrupt ${mode}-driven application or post-script cleanup"
}

test_arguments_are_not_logged() {
    local debug output
    for debug in false true; do
        output=$(docker run --rm -e KUBEDOOP_DEBUG="$debug" "$IMAGE" \
            bash -c 'exit 0' --password TEST_SECRET_NOT_FOR_LOGS 2>&1) || fail "logging test failed"
        if grep -Fq TEST_SECRET_NOT_FOR_LOGS <<<"$output"; then
            fail "framework logged command arguments with KUBEDOOP_DEBUG=$debug"
        fi
    done
    pass "command arguments are omitted from framework logs, including debug mode"
}

test_descendants_after_normal_exit() {
    local mode="$1" cid output
    cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=1 -e TEST_REQUIRE_GROUP_CLEANUP=true \
        "$TEST_IMAGE" bash -c '
            echo "$$" > /kubedoop/run/main-group
            bash -c '\''
                if [[ "$1" == ignore ]]; then
                    trap "" TERM
                else
                    trap "touch /kubedoop/run/descendant-term; exit 42" TERM
                fi
                touch /kubedoop/run/descendant-ready
                while :; do sleep 0.05; done
            '\'' bash "$1" &
            while [[ ! -e /kubedoop/run/descendant-ready ]]; do sleep 0.05; done
            exit 7
        ' bash "$mode") || fail 'descendant test startup'
    CONTAINER_IDS+=("$cid")
    output=$(timeout 8 docker wait "$cid") || fail 'descendant drain was unbounded'
    [[ $output == 7 ]] || fail 'descendant cleanup changed main status7'
    output=$(docker logs "$cid" 2>&1)
    [[ $(grep -xc TEST_POST_SCRIPT_RAN <<< "$output") == 1 ]] || fail 'post ran before descendant drain or not exactly once'
    if [[ $mode == ignore ]]; then
        assert_contains "$output" 'Main process group did not exit' 'TERM-ignoring descendant was not escalated'
    else
        docker cp "$cid:/kubedoop/run/descendant-term" "$TMP_DIR/descendant-term" >/dev/null || fail 'descendant did not receive TERM'
        if grep -Fq 'sending SIGKILL' <<< "$output"; then fail 'graceful descendant was forcibly killed'; fi
    fi
    pass "$mode descendant stops before post-hook after normal main exit"
}

test_link_target_permissions() {
    docker run --rm --user root --entrypoint /bin/bash "$IMAGE" -c '
        set -euo pipefail
        source /kubedoop/lib/run.sh
        test_dir=$(mktemp -d)
        mkdir "$test_dir/..data"
        cp /usr/bin/true "$test_dir/..data/allowed.sh"
        cp /usr/bin/true "$test_dir/..data/nonroot.sh"
        cp /usr/bin/true "$test_dir/..data/nonexec.sh"
        chown 1001:1001 "$test_dir/..data/nonroot.sh"
        chmod 0644 "$test_dir/..data/nonexec.sh"
        for name in allowed nonroot nonexec; do
            ln -s "..data/$name.sh" "$test_dir/$name.sh"
        done
        found=$(_discover_scripts "$test_dir" | tr "\\0" "\\n")
        test "$found" = "$test_dir/allowed.sh"
    ' || fail "discovery did not enforce symlink target ownership and executability"
    pass "symlink target ownership and executable permissions are checked"
}

cd "$REPO_DIR" || fail "failed to enter repository directory: $REPO_DIR"

test_image_exists
test_entrypoint_metadata
test_runtime_files_and_user
test_runtime_source_hashes
test_exit_code_propagation
test_main_stdin_is_preserved
test_root_owned_scripts_execute
test_hook_failure_behavior
test_sigterm_is_forwarded
test_sigterm_is_forwarded 127
test_sigterm_is_forwarded 142
test_sigkill_after_timeout
test_signals_during_cleanup signal
test_signals_during_cleanup normal
test_descendants_after_normal_exit graceful
test_descendants_after_normal_exit ignore
test_arguments_are_not_logged
test_link_target_permissions
