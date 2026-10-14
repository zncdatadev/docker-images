#!/bin/bash
# Real HDFS storage continuity on a private network.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-hadoop-lifecycle.sh IMAGE}"
STAMP="$(date +%s)-$$"
TEST_IMAGE="hadoop-application-test:$STAMP"
NETWORK="hadoop-lifecycle-$STAMP"
IDS=()
cleanup() {
    local cid
    for cid in "${IDS[@]}"; do docker rm -f "$cid" >/dev/null 2>&1 || true; done
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
    local cid
    for cid in "${IDS[@]}"; do docker logs --tail 80 "$cid" >&2 || true; done
    echo "not ok - $*" >&2; exit 1
}
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
docker network create "$NETWORK" >/dev/null
check_jvm() {
    local cid="$1" class="$2" pid
    pid=$(docker logs "$cid" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$pid" =~ ^[0-9]+$ ]] || fail 'managed PID missing'
    docker exec "$cid" bash -c 'set -e; test "$(cat "/proc/$1/comm")" = java; grep -aq "$2" "/proc/$1/cmdline"' bash "$pid" "$class" || fail 'native launcher did not exec actual service JVM'
}
stop_service() {
    local cid="$1" signal="$2" count="$3" rc logs
    docker kill --signal "$signal" "$cid" >/dev/null
    timeout 45 docker wait "$cid" >/dev/null || fail 'service shutdown timed out'
    rc=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
    [[ "$rc" == 0 || "$rc" == 143 ]] || fail "service shutdown status $rc"
    logs=$(docker logs "$cid" 2>&1)
    [[ "$(grep -c '^TEST_HADOOP_PRE_READY$' <<< "$logs")" == "$count" ]] || fail 'pre-hook count changed'
    [[ "$(grep -c '^TEST_HADOOP_POST_DONE$' <<< "$logs")" == "$count" ]] || fail 'post-hook count changed'
    ! grep -Eq 'Main process did not exit|post-script: .*failed|service JVM is still running' <<< "$logs" || fail 'shutdown escalated or hooks failed'
}
unformatted=$(docker run -d --network "$NETWORK" --hostname namenode --network-alias namenode -e TEST_ROLE=namenode "$TEST_IMAGE")
IDS+=("$unformatted")
[[ "$(timeout 30 docker wait "$unformatted")" == 1 ]] || fail 'unformatted default NameNode did not fail safely'
unformatted_logs=$(docker logs "$unformatted" 2>&1)
grep -Fq 'NameNode is not formatted' <<< "$unformatted_logs" || fail 'default CMD did not preserve caller-owned formatting policy'
grep -Fq TEST_HADOOP_FORMAT_POLICY_PRESERVED <<< "$unformatted_logs" || fail 'unformatted default CMD created a storage VERSION'
docker rm "$unformatted" >/dev/null
IDS=()
echo 'ok - production default CMD with valid test config refuses unformatted NameNode instead of formatting data'
nn=$(docker run -d --network "$NETWORK" --hostname namenode --network-alias namenode -e TEST_ROLE=namenode -e TEST_FORMAT=true "$TEST_IMAGE")
IDS+=("$nn")
dn=$(docker run -d --network "$NETWORK" --hostname datanode --network-alias datanode -e TEST_ROLE=datanode "$TEST_IMAGE" hdfs datanode)
IDS+=("$dn")
wait_hdfs() {
    local deadline=$((SECONDS + 180)) report
    while ((SECONDS < deadline)); do
        report=$(timeout 15 docker exec "$nn" hdfs dfsadmin -report 2>/dev/null) || true
        if grep -Fq 'Live datanodes (1)' <<< "$report" && timeout 15 docker exec "$nn" hdfs dfs -ls / >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    fail 'HDFS NameNode/DataNode did not become ready'
}
wait_hdfs
check_jvm "$nn" org.apache.hadoop.hdfs.server.namenode.NameNode
check_jvm "$dn" org.apache.hadoop.hdfs.server.datanode.DataNode
printf 'TEST_HDFS_PERSISTED_DATA\n' | timeout 20 docker exec -i "$nn" hdfs dfs -put - /lifecycle-data || fail 'real HDFS streaming write failed'
[[ "$(timeout 20 docker exec "$nn" hdfs dfs -cat /lifecycle-data 2>/dev/null)" == TEST_HDFS_PERSISTED_DATA ]] || fail 'HDFS read mismatch'
cluster_before=$(docker exec "$nn" grep '^clusterID=' /kubedoop/run/name/current/VERSION)
stop_service "$dn" INT 1
stop_service "$nn" TERM 1
docker start "$nn" "$dn" >/dev/null
wait_hdfs
[[ "$(timeout 20 docker exec "$nn" hdfs dfs -cat /lifecycle-data 2>/dev/null)" == TEST_HDFS_PERSISTED_DATA ]] || fail 'restart lost HDFS blocks/data'
[[ "$(docker exec "$nn" grep '^clusterID=' /kubedoop/run/name/current/VERSION)" == "$cluster_before" ]] || fail 'NameNode cluster identity changed'
[[ "$(docker logs "$nn" 2>&1 | grep -c '^TEST_HADOOP_FORMAT_ONCE$')" == 1 ]] || fail 'NameNode was reformatted on restart'
stop_service "$dn" TERM 2
stop_service "$nn" INT 2
echo 'ok - default NameNode and foreground DataNode preserve real HDFS data/cluster identity across restart and handle TERM/INT'
