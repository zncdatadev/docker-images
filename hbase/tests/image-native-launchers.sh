#!/bin/bash
# Actual native HBase launcher paths; instrumented JVM wiring, not deployment acceptance.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-native-launchers.sh IMAGE}"
TEST_IMAGE="hbase-role-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
version=$(docker run --rm "$IMAGE" hbase version)
grep -Eq '^HBase 2\.6\.' <<< "$version" || fail 'native version CLI broken'
docker build -q --build-arg "IMAGE=$IMAGE" -f "$SCRIPT_DIR/fixtures/role-Dockerfile" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
for spec in \
    master:org.apache.hadoop.hbase.master.HMaster:HBASE_MASTER_OPTS \
    regionserver:org.apache.hadoop.hbase.regionserver.HRegionServer:HBASE_REGIONSERVER_OPTS \
    rest:org.apache.hadoop.hbase.rest.RESTServer:HBASE_REST_OPTS \
    thrift:org.apache.hadoop.hbase.thrift.ThriftServer:HBASE_THRIFT_OPTS \
    thrift2:org.apache.hadoop.hbase.thrift2.ThriftServer:HBASE_THRIFT_OPTS \
    zookeeper:org.apache.hadoop.hbase.zookeeper.HQuorumPeer:HBASE_ZOOKEEPER_OPTS; do
    IFS=: read -r role class role_options <<< "$spec"
    CID=$(docker run -d -e HBASE_OPTS=-Dtest-credential=not-for-logs -e "$role_options=-Dtest-role=$role" "$TEST_IMAGE" hbase "$role" start 'arg with spaces')
    ready=false
    for ((i=0;i<50;i++)); do
        logs=$(docker logs "$CID" 2>&1)
        if grep -Fq TEST_JVM_READY <<< "$logs"; then ready=true; break; fi
        sleep 0.1
    done
    [[ "$ready" == true ]] || fail "native $role never reached JVM"
    managed=$(awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' <<< "$logs" | tail -1)
    [[ "$(docker exec "$CID" cat /kubedoop/run/mock-pid)" == "$managed" ]] || fail 'native launcher did not exec JVM'
    args=$(docker exec "$CID" cat /kubedoop/run/mock-args)
    grep -Fxq "$class" <<< "$args" || fail "incorrect class for $role"
    grep -Fxq start <<< "$args" || fail 'native start argument lost'
    grep -Fxq 'arg with spaces' <<< "$args" || fail 'argv boundary lost'
    grep -Fxq -- '-Dtest-credential=not-for-logs' <<< "$args" || fail 'HBASE_OPTS lost'
    grep -Fxq -- "-Dtest-role=$role" <<< "$args" || fail 'role-specific JVM options lost'
    ! grep -Fq not-for-logs <<< "$logs" || fail 'default launcher logged sensitive options'
    docker kill --signal INT "$CID" >/dev/null
    [[ "$(timeout 10 docker wait "$CID")" == 42 ]] || fail 'signal exit status lost'
    docker rm "$CID" >/dev/null; CID=""
    rc=0
    docker run --rm -e TEST_JVM_EXIT=42 "$TEST_IMAGE" hbase "$role" start >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 42 ]] || fail 'normal JVM status lost'
    echo "ok - native $role class/options/argv, exec PID and normal/signal status"
done
