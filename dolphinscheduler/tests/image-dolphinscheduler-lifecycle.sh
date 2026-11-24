#!/bin/bash
# Real standalone API/H2 behavior under UID1001/root and three same-CID starts.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-dolphinscheduler-lifecycle.sh IMAGE}"
TEST_IMAGE="dolphin-application-test:$(date +%s)-$$"
CID=""
SESSION=""
CONTAINER_IDS=()
cleanup() {
    local cid
    for cid in "${CONTAINER_IDS[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
    [[ -z "$CID" ]] || docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CID" >&2 || true
    [[ -z "$CID" ]] || docker logs --tail 120 "$CID" >&2 || true
    echo "not ok - $*" >&2
    exit 1
}
command -v jq >/dev/null || { echo 'jq is required on the test host' >&2; exit 1; }
api() {
    local path="$1"; shift
    timeout --kill-after=2 15 docker exec "$CID" timeout --kill-after=2 12 curl -fsS --connect-timeout 2 --max-time 8 \
        "http://127.0.0.1:12345/dolphinscheduler/$path" "$@"
}
login() {
    local response
    response=$(api login -X POST --data-urlencode userName=admin --data-urlencode userPassword=dolphinscheduler123) || return 1
    SESSION=$(jq -er 'select(.code==0) | .data.sessionId | select(type=="string" and length>0)' <<< "$response")
}
wait_ready() {
    local deadline=$((SECONDS + 240))
    while ((SECONDS < deadline)); do
        if login >/dev/null 2>&1; then return 0; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail 'standalone exited during startup'
        sleep 2
    done
    fail 'real API login never became ready'
}
check_jvm() {
    local pid
    pid=$(docker logs "$CID" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'managed PID missing'
    docker exec "$CID" bash -c '
        test "$(cat "/proc/$1/comm")" = java
        grep -aq org.apache.dolphinscheduler.StandaloneServer "/proc/$1/cmdline"
    ' bash "$pid" || fail 'launcher did not hand off managed PID to real standalone JVM'
}
stop_and_check() {
    local signal="$1" count="$2" rc logs events expected="" i
    if [[ "$signal" == stop ]]; then
        docker stop -t 45 "$CID" >/dev/null || fail 'docker stop timed out'
    else
        docker kill --signal "$signal" "$CID" >/dev/null || fail 'shutdown signal failed'
        timeout 45 docker wait "$CID" >/dev/null || fail 'signal shutdown timed out'
    fi
    rc=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$rc" == 0 || "$rc" == 143 ]] || fail "unexpected shutdown status $rc"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_DOLPHIN_PRE_READY$' <<< "$logs")" == "$count" ]] || fail 'pre-hook count changed'
    [[ "$(grep -c '^TEST_DOLPHIN_POST_DONE$' <<< "$logs")" == "$count" ]] || fail 'post-hook count changed'
    ! grep -Eq 'sending SIGKILL|post-script: .*failed|standalone JVM is still running' <<< "$logs" || fail 'shutdown escalated or cleanup failed'
    events=$(docker cp "$CID:/kubedoop/run/dolphin-events" - | tar -xO | tr '\n' ',')
    for ((i=0;i<count;i++)); do expected+=PRE,POST,; done
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
for runtime_user in kubedoop root; do
    docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "RUNTIME_USER=$runtime_user" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
    # No command override: exercise production default CMD.
    CID=$(docker run -d "$TEST_IMAGE")
    CONTAINER_IDS+=("$CID")
    for cycle in 1 2 3; do
        wait_ready
        expected_uid=1001
        [[ "$runtime_user" != root ]] || expected_uid=0
        [[ $(docker exec "$CID" id -u) == "$expected_uid" ]] || fail 'runtime identity changed'
        [[ $(docker exec "$CID" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        check_jvm
        if [[ "$cycle" == 1 ]]; then
            test_cli_deadlines
            response=$(api projects -X POST -H "sessionId: $SESSION" --data-urlencode projectName=universal_lifecycle --data-urlencode description=persisted_after_restart) || fail 'real project creation failed'
            code=$(jq -er 'select(.code==0) | .data.code' <<< "$response") || fail 'project was not created'
        fi
        response=$(api "projects/$code" -H "sessionId: $SESSION") || fail 'project read after start failed'
        jq -e '(.code==0) and (.data.name=="universal_lifecycle") and (.data.description=="persisted_after_restart")' <<< "$response" >/dev/null || fail 'restart lost project identity/data'
        signal=TERM
        [[ "$cycle" != 2 ]] || signal=INT
        [[ "$cycle" != 3 ]] || signal=stop
        stop_and_check "$signal" "$cycle"
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null || fail 'standalone restart failed'; fi
    done
    echo "ok - DolphinScheduler $runtime_user default CMD real API/H2 persists project across three same-CID starts TERM/INT/stop with exact hooks"
done
