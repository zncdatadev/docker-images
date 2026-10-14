#!/bin/bash
# Real shipped HDFS launchers with an instrumented JVM.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-native-launchers.sh IMAGE}"
TEST_IMAGE="hadoop-role-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" hadoop version | grep -E '^Hadoop 3\.' >/dev/null || fail 'native CLI version command no longer works'
docker run --rm --entrypoint bash "$IMAGE" -c '
    test -x "$HADOOP_HOME/bin/hadoop" && test -x "$HADOOP_HOME/bin/hdfs" &&
    test ! -e "$HADOOP_HOME/bin/yarn" && test ! -e "$HADOOP_HOME/bin/mapred"
' || fail 'existing HDFS-focused distribution command surface changed'
docker build -q --build-arg "IMAGE=$IMAGE" -f "$SCRIPT_DIR/fixtures/role-Dockerfile" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
for spec in \
    hdfs:namenode:org.apache.hadoop.hdfs.server.namenode.NameNode \
    hdfs:datanode:org.apache.hadoop.hdfs.server.datanode.DataNode \
    hdfs:journalnode:org.apache.hadoop.hdfs.qjournal.server.JournalNode \
    hdfs:zkfc:org.apache.hadoop.hdfs.tools.DFSZKFailoverController; do
    IFS=: read -r command role class <<< "$spec"
    CID=$(docker run -d -e HADOOP_OPTS=-Dtest-credential=not-for-logs "$TEST_IMAGE" "$command" "$role" 'arg with spaces')
    ready=false
    for ((i=0;i<50;i++)); do
        if docker logs "$CID" 2>&1 | grep -Fq TEST_JVM_READY; then ready=true; break; fi
        sleep 0.1
    done
    [[ "$ready" == true ]] || fail "native $command $role did not reach JVM"
    managed=$(docker logs "$CID" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$(docker exec "$CID" cat /kubedoop/run/mock-pid)" == "$managed" ]] || fail 'native launcher did not exec JVM'
    args=$(docker exec "$CID" cat /kubedoop/run/mock-args)
    grep -Fxq "$class" <<< "$args" || fail "incorrect native class for $role"
    grep -Fxq 'arg with spaces' <<< "$args" || fail 'application argument boundary lost'
    grep -Fxq -- '-Dtest-credential=not-for-logs' <<< "$args" || fail 'native HADOOP_OPTS lost'
    logs=$(docker logs "$CID" 2>&1)
    ! grep -Fq not-for-logs <<< "$logs" || fail 'native default launcher logged options'
    docker kill --signal INT "$CID" >/dev/null
    [[ "$(timeout 10 docker wait "$CID")" == 42 ]] || fail 'signal-driven JVM status lost'
    docker rm "$CID" >/dev/null; CID=""
    rc=0
    docker run --rm -e TEST_JVM_EXIT=42 "$TEST_IMAGE" "$command" "$role" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 42 ]] || fail 'normal JVM status lost'
    echo "ok - native $command $role retains class/options/argv and execs managed JVM"
done
