#!/bin/bash
# Real standalone default CMD, internal ZooKeeper/RegionServer and persisted table data.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-hbase-lifecycle.sh IMAGE}"
TEST_IMAGE="hbase-application-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 100 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
CID=$(docker run -d --hostname hbase "$TEST_IMAGE")
shell() { printf '%s\n' "$1" | timeout 45 docker exec -i "$CID" hbase shell -n; }
wait_ready() {
    local deadline=$((SECONDS + 240)) output
    while ((SECONDS < deadline)); do
        if output=$(shell "status 'simple'" 2>&1) && grep -Eq '[1-9][0-9]* live servers' <<< "$output"; then return 0; fi
        sleep 2
    done
    fail 'real standalone HBase did not become ready'
}
stop_service() {
    local signal="$1" count="$2" status logs
    docker kill --signal "$signal" "$CID" >/dev/null
    timeout 45 docker wait "$CID" >/dev/null || fail 'shutdown timed out'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "unexpected service status $status"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_HBASE_PRE_READY$' <<< "$logs")" == "$count" ]] || fail 'pre-hook count changed'
    [[ "$(grep -c '^TEST_HBASE_POST_DONE$' <<< "$logs")" == "$count" ]] || fail 'post-hook count changed'
    ! grep -Eq 'Main process did not exit|post-script: .*failed|service JVM is still running' <<< "$logs" || fail 'shutdown escalated or hook failed'
}
wait_ready
logs=$(docker logs "$CID" 2>&1)
managed=$(awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' <<< "$logs" | tail -1)
[[ "$managed" =~ ^[0-9]+$ ]] || fail 'managed PID missing'
docker exec "$CID" bash -c 'test "$(cat "/proc/$1/comm")" = java && grep -aq org.apache.hadoop.hbase.master.HMaster "/proc/$1/cmdline"' bash "$managed" || fail 'default CMD did not exec actual HMaster JVM'
shell "create 'lifecycle', 'cf'; put 'lifecycle', 'row', 'cf:value', 'TEST_HBASE_PERSISTED_DATA'; flush 'lifecycle'" >/dev/null || fail 'table create/write/flush failed'
readback=$(shell "get 'lifecycle', 'row', 'cf:value'")
grep -Fq TEST_HBASE_PERSISTED_DATA <<< "$readback" || fail 'real HBase read mismatch'
identity_before=$(docker exec "$CID" sha256sum /kubedoop/run/data/hbase.id | awk '{print $1}')
stop_service TERM 1
docker start "$CID" >/dev/null
wait_ready
readback=$(shell "get 'lifecycle', 'row', 'cf:value'")
grep -Fq TEST_HBASE_PERSISTED_DATA <<< "$readback" || fail 'restart lost table data'
[[ "$(docker exec "$CID" sha256sum /kubedoop/run/data/hbase.id | awk '{print $1}')" == "$identity_before" ]] || fail 'HBase cluster identity changed'
stop_service INT 2
echo 'ok - real default HMaster standalone stores/reads table data, persists identity/data across restart and handles TERM/INT once'
