#!/bin/bash
# Test the real launcher/JVM, not only a shell surrogate.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-trino-lifecycle.sh IMAGE}"
TMP_DIR=$(mktemp -d)
TEST_IMAGE="trino-lifecycle-test:$(date +%s)-$$"
CID=""
CONTAINER_IDS=()

cleanup() {
    for cid in "${CONTAINER_IDS[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    if [[ -n "$CID" ]]; then
        docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CID" >&2 || true
        docker logs "$CID" --tail 100 >&2 || true
    fi
    echo "not ok - $*" >&2
    exit 1
}

exec_with_timeout() {
    local seconds="$1"
    shift
    timeout --kill-after=2 "$((seconds + 10))" docker exec -i "$CID" \
        timeout --kill-after=2 "$seconds" "$@"
}

query() {
    exec_with_timeout 20 trino-cli --server http://127.0.0.1:8080 \
        --output-format TSV --execute "$1"
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wait-for-server.sh"

check_sql() {
    local output
    output=$(query 'SELECT 1 + 1') || fail "constant SQL query failed"
    [[ "$output" == 2 ]] || fail "unexpected constant SQL result: $output"
    output=$(query 'SELECT count(*) FROM tpch.tiny.nation') || fail "TPCH query failed"
    [[ "$output" == 25 ]] || fail "unexpected query result: $output"
}

test_cli_deadlines() {
    local mode pid rc expected
    for mode in normal ignore-term; do
        rc=0
        pid=$(exec_with_timeout 1 bash -c '
            if [[ "$1" == ignore-term ]]; then trap "" TERM; fi
            echo $$
            exec sleep 60
        ' bash "$mode") || rc=$?
        expected=124
        if [[ "$mode" == ignore-term ]]; then expected=137; fi
        [[ "$rc" == "$expected" && "$pid" =~ ^[0-9]+$ ]] || fail "CLI deadline failed ($mode, status $rc)"
        docker exec "$CID" bash -c '! kill -0 "$1" 2>/dev/null' bash "$pid" || fail "timed-out CLI remained running ($mode)"
    done
    echo 'ok - container CLI deadlines terminate normal and SIGTERM-ignoring commands'
}

stop_and_check() {
    local expected_runs="$1" output rc
    case "$expected_runs" in
        1) docker kill --signal TERM "$CID" >/dev/null || fail 'TERM failed' ;;
        2) docker kill --signal INT "$CID" >/dev/null || fail 'INT failed' ;;
        3) docker stop -t 40 "$CID" >/dev/null || fail 'docker stop failed' ;;
    esac
    rc=$(timeout 45 docker wait "$CID") || fail 'Trino shutdown was unbounded'
    # The real Trino JVM may exit cleanly or report its SIGTERM status.
    [[ "$rc" == 0 || "$rc" == 143 ]] || fail "unexpected shutdown status $rc"
    output=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_TRINO_PRE_READY$' <<< "$output")" == "$expected_runs" ]] || fail "pre-hooks did not run once per start"
    [[ "$(grep -c '^TEST_TRINO_POST_DONE$' <<< "$output")" == "$expected_runs" ]] || fail "post-hooks did not finish once per shutdown"
    if grep -Eq 'sending SIGKILL|post-script: .*failed|Trino JVM is still running' <<< "$output"; then
        fail "Trino shutdown required escalation or post-hooks failed"
    fi
    local events expected="" i
    events=$(docker cp "$CID:/kubedoop/run/trino-events" - | tar -xO | tr '\n' ',')
    for ((i=0;i<expected_runs;i++)); do expected+=PRE,POST,; done
    [[ "$events" == "$expected" ]] || fail "hook order/count changed: $events"
}

docker image inspect "$IMAGE" >/dev/null || fail 'source-built image missing locally'
cp -R "${SCRIPT_DIR}/fixtures/etc" "$TMP_DIR/etc"
cp "${SCRIPT_DIR}/fixtures/10-prepare.sh" "$TMP_DIR/10-pre.sh"
cp "${SCRIPT_DIR}/fixtures/10-check-stopped.sh" "$TMP_DIR/10-post.sh"
cat > "$TMP_DIR/Dockerfile" <<EOF
FROM ${IMAGE}
USER root
COPY --chown=kubedoop:kubedoop etc/ /kubedoop/trino-server/etc/
COPY --chown=root:root --chmod=0755 10-pre.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY --chown=root:root --chmod=0755 10-post.sh /kubedoop/mount/post-script/10-check-stopped.sh
USER kubedoop
EOF
docker build -q -t "$TEST_IMAGE" "$TMP_DIR" >/dev/null || fail "failed to build Trino test image"
# No command override: exercise the production default launcher run CMD.
for identity in kubedoop root; do
    options=()
    [[ "$identity" != root ]] || options=(--user root)
    CID=$(docker run -d "${options[@]}" "$TEST_IMAGE") || fail 'failed to start Trino'
    CONTAINER_IDS+=("$CID")
    for cycle in 1 2 3; do
        wait_for_server
        [[ $(docker exec "$CID" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        if [[ "$cycle" == 1 ]]; then
            test_cli_deadlines
            identity_before=$(docker exec "$CID" sha256sum /kubedoop/trino-server/etc/node.properties)
        fi
        check_sql
        identity_after=$(docker exec "$CID" sha256sum /kubedoop/trino-server/etc/node.properties)
        [[ "$identity_after" == "$identity_before" ]] || fail 'restart changed configured node identity'
        stop_and_check "$cycle"
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null || fail 'failed to restart Trino'; fi
    done
    echo "ok - $identity Trino default CMD SQL/TPCH, three same-CID starts, TERM/INT/stop, unchanged identity and exact hooks"
done
