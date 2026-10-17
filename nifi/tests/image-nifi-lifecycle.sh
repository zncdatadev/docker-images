#!/bin/bash
# Validate the actual NiFi JVM/API and persisted flow across container restart.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-nifi-lifecycle.sh IMAGE}"
TEST_IMAGE="nifi-lifecycle-test:$(date +%s)-$$"
CID=""
CONTAINER_IDS=()

cleanup() {
    for cid in "${CONTAINER_IDS[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    if [[ -n "$CID" ]]; then
        docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CID" >&2 || true
        docker logs "$CID" --tail 100 >&2 || true
        docker cp "$CID:/kubedoop/nifi/logs/nifi-app.log" - 2>/dev/null | tar -xO 2>/dev/null | tail -100 >&2 || true
    fi
    echo "not ok - $*" >&2
    exit 1
}

api() {
    timeout --kill-after=2 25 docker exec "$CID" \
        timeout --kill-after=2 15 python3 /kubedoop/run/api.py "$@"
}

wait_for_server() {
    local deadline=$((SECONDS + 240))
    while (( SECONDS < deadline )); do
        if api ready >/dev/null 2>&1; then return 0; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail "NiFi exited during startup"
        sleep 2
    done
    fail "NiFi API did not become ready"
}

check_foreground_jvm() {
    local pid
    pid=$(docker logs "$CID" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "managed main PID was not reported"
    docker exec "$CID" bash -c '
        test "$(cat "/proc/$1/comm")" = java
        grep -aq org.apache.nifi.NiFi "/proc/$1/cmdline"
    ' bash "$pid" || fail "nifi.sh run did not hand off the managed PID to the NiFi JVM"
}

stop_and_check() {
    local expected_runs="$1" signal="${2:-TERM}" output rc
    if [[ "$signal" == stop ]]; then
        docker stop -t 50 "$CID" >/dev/null || fail "docker stop failed"
    else
        docker kill --signal "$signal" "$CID" >/dev/null || fail "shutdown signal failed"
        timeout 50 docker wait "$CID" >/dev/null || fail "signal-driven shutdown did not finish"
    fi
    rc=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$rc" == 0 || "$rc" == 143 ]] || fail "unexpected shutdown status $rc"
    output=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_NIFI_PRE_READY$' <<< "$output")" == "$expected_runs" ]] || fail "pre-hooks did not run once per start"
    [[ "$(grep -c '^TEST_NIFI_POST_DONE$' <<< "$output")" == "$expected_runs" ]] || fail "post-hooks did not finish once per shutdown"
    if grep -Eq 'sending SIGKILL|post-script: .*failed|NiFi JVM is still running' <<< "$output"; then
        fail "NiFi shutdown required escalation or post-hooks failed"
    fi
    local events expected="" i
    events=$(docker cp "$CID:/kubedoop/run/nifi-events" - | tar -xO | tr '\n' ',')
    for ((i=0;i<expected_runs;i++)); do expected+=PRE,POST,; done
    [[ "$events" == "$expected" ]] || fail "hook order/count changed: $events"
}

test_cli_deadlines() {
    local mode pid rc expected
    for mode in normal ignore-term; do
        rc=0
        pid=$(timeout --kill-after=2 12 docker exec -i "$CID" timeout --kill-after=2 1 bash -c '
            if [[ "$1" == ignore-term ]]; then trap "" TERM; fi
            echo $$
            exec sleep 60
        ' bash "$mode") || rc=$?
        expected=124
        [[ "$mode" != ignore-term ]] || expected=137
        [[ "$rc" == "$expected" && "$pid" =~ ^[1-9][0-9]*$ ]] || fail "CLI deadline failed ($mode, status $rc)"
        docker exec "$CID" bash -c '! kill -0 "$1" 2>/dev/null' bash "$pid" || fail "timed-out CLI remained running ($mode)"
    done
    echo 'ok - container CLI deadlines terminate normal and SIGTERM-ignoring commands'
}

for runtime_user in root kubedoop; do
    docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "RUNTIME_USER=$runtime_user" \
        -t "$TEST_IMAGE" "${SCRIPT_DIR}/fixtures" >/dev/null || fail "failed to build NiFi test image"
    # No command override: use the production default foreground nifi.sh run.
    CID=$(docker run -d "$TEST_IMAGE") || fail "failed to start NiFi"
    CONTAINER_IDS+=("$CID")
    for cycle in 1 2 3; do
        wait_for_server
        [[ $(docker exec "$CID" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        check_foreground_jvm
        if [[ "$cycle" == 1 ]]; then
            test_cli_deadlines
            root_before=$(api ready) || fail "failed to read root process group"
            group=$(api create) || fail "failed to create process group"
        fi
        [[ "$(api ready)" == "$root_before" ]] || fail "restart changed root process group identity"
        [[ "$(api check "$group")" == "$group" ]] || fail "restart lost persisted process group"
        signal=TERM
        [[ "$cycle" != 2 ]] || signal=INT
        [[ "$cycle" != 3 ]] || signal=stop
        stop_and_check "$cycle" "$signal"
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null || fail "failed to restart NiFi"; fi
    done
    echo "ok - $runtime_user NiFi default CMD API/persistence, three same-CID starts, TERM/INT/stop, unchanged root/group identity and exact hooks"
done
