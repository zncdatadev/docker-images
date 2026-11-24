#!/bin/bash
# Real metastore Thrift operations and Derby persistence across process restart.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-hive-lifecycle.sh IMAGE}"
TEST_IMAGE="hive-lifecycle-test:$(date +%s)-$$"
CID=""
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
client() {
    timeout --kill-after=2 25 docker exec "$CID" timeout --kill-after=2 15 bash -c '
        classpath="/kubedoop/run/client:$HIVE_HOME/lib/*:$HADOOP_HOME/share/hadoop/common/*:$HADOOP_HOME/share/hadoop/common/lib/*"
        exec java -cp "$classpath" MetastoreClient "$@"
    ' bash "$@"
}
wait_for_server() {
    local deadline=$((SECONDS + 180))
    while ((SECONDS < deadline)); do
        if client ready >/dev/null 2>&1; then return 0; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail "metastore exited during startup"
        sleep 2
    done
    client ready >&2 || true
    fail "metastore Thrift API did not become ready"
}
check_foreground_jvm() {
    local pid
    pid=$(docker logs "$CID" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "managed main PID not reported"
    docker exec "$CID" bash -c '
        test "$(cat "/proc/$1/comm")" = java
        grep -aq org.apache.hadoop.hive.metastore.HiveMetaStore "/proc/$1/cmdline"
    ' bash "$pid" || fail "native launcher did not hand off the managed PID to the metastore JVM"
}
stop_and_check() {
    local count="$1" signal="$2" output rc
    if [[ "$signal" == stop ]]; then
        docker stop -t 45 "$CID" >/dev/null || fail "docker stop failed"
    else
        docker kill --signal "$signal" "$CID" >/dev/null || fail "shutdown signal failed"
        timeout 45 docker wait "$CID" >/dev/null || fail "signal-driven shutdown did not finish"
    fi
    rc=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$rc" == 0 || "$rc" == 143 ]] || fail "unexpected shutdown status $rc"
    output=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_HIVE_PRE_READY$' <<< "$output")" == "$count" ]] || fail "pre-hooks did not run once per start"
    [[ "$(grep -c '^TEST_HIVE_POST_DONE$' <<< "$output")" == "$count" ]] || fail "post-hooks did not run once per stop"
    ! grep -Eq 'sending SIGKILL|post-script: .*failed|metastore JVM is still running' <<< "$output" || fail "shutdown escalated or post-hooks failed"
    local events expected="" i
    events=$(docker cp "$CID:/kubedoop/run/hive-events" - | tar -xO | tr '\n' ',')
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
docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "RUNTIME_USER=$runtime_user" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null || fail "fixture/client build failed"
for mode in native wrapper; do
    if [[ "$mode" == native ]]; then
        # Exercise production default CMD; test-only hook explicitly prepares Derby.
        CID=$(docker run -d -e TEST_NATIVE_CMD=true "$TEST_IMAGE")
    else
        CID=$(docker run -d "$TEST_IMAGE" start-metastore --db-type derby \
            --config /kubedoop/run/conf --hive-bin-dir /kubedoop/hive-metastore/bin)
    fi
    CONTAINER_IDS+=("$CID")
    db="lifecycle_$mode"
    for cycle in 1 2 3; do
        wait_for_server
        expected_uid=1001
        [[ "$runtime_user" != root ]] || expected_uid=0
        [[ $(docker exec "$CID" id -u) == "$expected_uid" ]] || fail 'runtime identity changed'
        [[ $(docker exec "$CID" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        check_foreground_jvm
        if [[ "$cycle" == 1 ]]; then
            test_cli_deadlines
            client create "$db" >/dev/null || fail "Thrift database creation failed"
        fi
        [[ "$(client check "$db" 2>/dev/null | tail -1)" == "$db" ]] || fail "restart lost database identity or contents"
        signal=TERM
        [[ "$cycle" != 2 ]] || signal=INT
        [[ "$cycle" != 3 ]] || signal=stop
        stop_and_check "$cycle" "$signal"
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null || fail "metastore restart failed"; fi
    done
    logs=$(docker logs "$CID" 2>&1)
    if [[ "$mode" == native ]]; then
        [[ "$(grep -c '^TEST_HIVE_SCHEMA_INIT$' <<< "$logs")" == 1 ]] || fail "schema was recreated on restart"
    else
        [[ "$(grep -c '^No valid schema found, initializing schema' <<< "$logs")" == 1 ]] || fail "wrapper recreated a valid schema"
    fi
    echo "ok - Hive $runtime_user $mode real Thrift/Derby persistence, three same-CID starts TERM/INT/stop and exact hooks"
done
done
