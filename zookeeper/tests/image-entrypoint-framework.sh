#!/bin/bash
# Validate the built zookeeper image's entrypoint framework wiring.
#
# This is an image-level companion to source-entrypoint-framework.sh. It should
# be run after `make zookeeper-build` and tests the final container behavior.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRODUCT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd "${PRODUCT_DIR}/.." && pwd)

DEFAULT_REGISTRY="${REGISTRY:-quay.io/zncdatadev}"
DEFAULT_KUBEDOOP_VERSION="${KUBEDOOP_VERSION:-0.0.0-dev}"
DEFAULT_PRODUCT_VERSION="3.9.3"
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

IMAGE="${1:-${DEFAULT_REGISTRY}/zookeeper:${DEFAULT_PRODUCT_VERSION}-kubedoop${DEFAULT_KUBEDOOP_VERSION}}"
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
        if docker logs "$cid" 2>&1 | grep -Fq "$pattern"; then
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
    assert_contains "$metadata" '["bin/zkServer.sh","start-foreground","config/zoo_sample.cfg"]' "unexpected image CMD"
    assert_contains "$metadata" 'kubedoop' "unexpected image USER"
    pass "image metadata wires tini and the universal entrypoint"
}

test_runtime_files_and_user() {
    docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
        set -euo pipefail
        test "$(id -un)" = "kubedoop"
        test -x /usr/bin/tini
        test -x /kubedoop/bin/entrypoint.sh
        test -x /kubedoop/lib/log.sh
        test -x /kubedoop/lib/run-phase.sh
        test -x /kubedoop/lib/signal.sh
        test "$(stat -c "%u:%a" /kubedoop/bin/entrypoint.sh)" = "0:755"
        test "$(stat -c "%u:%a" /kubedoop/lib/signal.sh)" = "0:755"
        test -w /kubedoop/run
    ' || fail "runtime file layout or permissions are invalid"

    pass "runtime files, ownership, and kubedoop user are valid"
}

test_exit_code_propagation() {
    run_expect_status 7 docker run --rm "$IMAGE" bash -c 'exit 7'
    pass "entrypoint preserves main process exit code"
}

build_hook_test_image() {
    TEST_IMAGE="zookeeper-entrypoint-test:$(date +%s)-$$"
    mkdir -p "${TMP_DIR}/hooks"

    cat >"${TMP_DIR}/hooks/10-pre.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
echo pre-hook > /kubedoop/run/pre-hook
echo TEST_PRE_HOOK_RAN
EOF

    cat >"${TMP_DIR}/hooks/10-post.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
test -f /kubedoop/run/pre-hook
echo TEST_POST_HOOK_RAN
EOF

    chmod 0755 "${TMP_DIR}/hooks/10-pre.sh" "${TMP_DIR}/hooks/10-post.sh"

    cat >"${TMP_DIR}/Dockerfile" <<EOF
FROM ${IMAGE}
USER root
COPY --chown=root:root hooks/10-pre.sh /kubedoop/mount/pre-script/10-pre.sh
COPY --chown=root:root hooks/10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-pre.sh /kubedoop/mount/post-script/10-post.sh
USER kubedoop
EOF

    docker build -q -t "$TEST_IMAGE" "$TMP_DIR" >/dev/null || fail "failed to build hook test image"
}

test_root_owned_hooks_execute() {
    build_hook_test_image

    local output
    output=$(docker run --rm "$TEST_IMAGE" bash -c '
        test -f /kubedoop/run/pre-hook
        echo TEST_MAIN_RAN
    ' 2>&1) || {
        echo "$output" >&2
        fail "root-owned hook image run failed"
    }

    assert_contains "$output" "TEST_PRE_HOOK_RAN" "pre hook did not run"
    assert_contains "$output" "TEST_MAIN_RAN" "main command did not run after pre hook"
    assert_contains "$output" "TEST_POST_HOOK_RAN" "post hook did not run"
    pass "root-owned pre/post hooks execute in the final image"
}

test_sigterm_is_forwarded() {
    local cid
    cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=2 "$IMAGE" bash -c '
        trap "echo TEST_CHILD_TERM; exit 42" TERM
        echo TEST_CHILD_READY
        while :; do sleep 1; done
    ') || fail "failed to start signal test container"
    CONTAINER_IDS+=("$cid")

    wait_for_log "$cid" "TEST_CHILD_READY" 10 || fail "signal test container did not become ready"
    docker stop -t 5 "$cid" >/dev/null || fail "docker stop failed for signal test container"

    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || true)
    [[ "$exit_code" == "42" ]] || fail "expected container exit code 42 after forwarded SIGTERM, got ${exit_code}"

    local logs
    logs=$(docker logs "$cid" 2>&1 || true)
    assert_contains "$logs" "TEST_CHILD_TERM" "child did not log SIGTERM handling"
    pass "SIGTERM reaches the main process through tini and the entrypoint"
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

cd "$REPO_DIR"

test_image_exists
test_entrypoint_metadata
test_runtime_files_and_user
test_exit_code_propagation
test_root_owned_hooks_execute
test_sigterm_is_forwarded
test_sigkill_after_timeout
