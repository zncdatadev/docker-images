#!/bin/bash
# Real PySpark compute/event logs and HistoryServer restart; private disposable filesystem only.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-spark-lifecycle.sh IMAGE}"
TEST_IMAGE="spark-application-test:$(date +%s)-$$"
CID=""
HISTORY_IMAGE=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    [[ -z "$HISTORY_IMAGE" ]] || docker image rm "$HISTORY_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 100 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
CID=$(docker run -d -e SPARK_DRIVER_BIND_ADDRESS=127.0.0.1 "$TEST_IMAGE" driver \
    --master 'local[2]' --driver-memory 512m \
    --conf spark.driver.extraJavaOptions=-XX:ActiveProcessorCount=2 \
    --conf spark.eventLog.enabled=true --conf spark.eventLog.dir=file:///kubedoop/run/events \
    /kubedoop/run/job.py)
[[ "$(timeout 120 docker wait "$CID")" == 0 ]] || fail 'real PySpark driver job failed'
logs=$(docker logs "$CID" 2>&1)
grep -Fq TEST_SPARK_REAL_COMPUTE_AND_PERSISTENCE_OK <<< "$logs" || fail 'real compute/data check missing'
[[ "$(grep -c '^TEST_SPARK_PRE_READY$' <<< "$logs")" == 1 ]] || fail 'job pre-hook count wrong'
[[ "$(grep -c '^TEST_SPARK_POST_DONE$' <<< "$logs")" == 1 ]] || fail 'job post-hook count wrong'
docker start "$CID" >/dev/null
[[ "$(timeout 120 docker wait "$CID")" == 0 ]] || fail 'same-container driver rerun failed'
logs=$(docker logs "$CID" 2>&1)
[[ "$(grep -c '^TEST_SPARK_REAL_COMPUTE_AND_PERSISTENCE_OK$' <<< "$logs")" == 2 ]] || fail 'persisted Parquet data not reread on restart'
echo 'ok - real driver PySpark compute, Parquet persistence and same-container rerun'
# Reuse completed event logs in a private derived container to exercise HistoryServer.
HISTORY_IMAGE="spark-history-data:$(date +%s)-$$"
docker commit "$CID" "$HISTORY_IMAGE" >/dev/null
docker rm "$CID" >/dev/null; CID=""
CID=$(docker run -d "$HISTORY_IMAGE" history)
wait_history() {
    local deadline=$((SECONDS + 90)) response
    while ((SECONDS < deadline)); do
        response=$(docker exec "$CID" curl -fsS http://127.0.0.1:18080/api/v1/applications 2>/dev/null) || response=""
        if grep -Fq universal-process-regression <<< "$response"; then return 0; fi
        sleep 1
    done
    fail 'HistoryServer failed to load real application event log'
}
stop_history() {
    local signal="$1" count="$2" status output
    docker kill --signal "$signal" "$CID" >/dev/null
    timeout 40 docker wait "$CID" >/dev/null || fail 'HistoryServer shutdown timeout'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "HistoryServer status $status"
    output=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_SPARK_PRE_READY$' <<< "$output")" == "$count" ]] || fail 'history pre-hook count'
    [[ "$(grep -c '^TEST_SPARK_POST_DONE$' <<< "$output")" == "$count" ]] || fail 'history post-hook count'
    ! grep -Eq 'Main process did not exit|post-script: .*failed' <<< "$output" || fail 'history escalated or hooks failed'
}
wait_history
stop_history TERM 1
docker start "$CID" >/dev/null
wait_history
stop_history INT 2
docker rm "$CID" >/dev/null; CID=""
docker image rm "$HISTORY_IMAGE" >/dev/null
HISTORY_IMAGE=""
echo 'ok - real HistoryServer reads persisted event log, restarts and handles TERM/INT once'

# PythonRunner's child must stop before post-hooks, not only its Java parent.
CID=$(docker run -d -e SPARK_DRIVER_BIND_ADDRESS=127.0.0.1 "$TEST_IMAGE" driver \
    --master 'local[2]' --driver-memory 512m \
    --conf spark.driver.extraJavaOptions=-XX:ActiveProcessorCount=2 \
    --conf spark.eventLog.enabled=true --conf spark.eventLog.dir=file:///kubedoop/run/events \
    /kubedoop/run/job.py --hold)
count=0
for signal in TERM INT; do
    count=$((count + 1))
    deadline=$((SECONDS + 90))
    ready=false
    while ((SECONDS < deadline)); do
        logs=$(docker logs "$CID" 2>&1)
        if [[ "$(grep -c '^TEST_SPARK_REAL_COMPUTE_AND_PERSISTENCE_OK$' <<< "$logs" || true)" == "$count" ]]; then
            ready=true; break
        fi
        sleep 1
    done
    [[ "$ready" == true ]] || fail 'long-running real Python driver not ready'
    docker kill --signal "$signal" "$CID" >/dev/null
    timeout 40 docker wait "$CID" >/dev/null || fail 'Python driver group shutdown timeout'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "Python driver status $status"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_SPARK_PRE_READY$' <<< "$logs")" == "$count" ]] || fail 'driver pre-hook count'
    [[ "$(grep -c '^TEST_SPARK_POST_DONE$' <<< "$logs")" == "$count" ]] || fail 'post-hook ran while Java/Python child was alive'
    ! grep -Eq 'Main process.*did not exit|post-script: .*failed|Spark Python driver still' <<< "$logs" || fail 'driver group escalated or hooks failed'
    [[ "$signal" != TERM ]] || docker start "$CID" >/dev/null
done
docker rm "$CID" >/dev/null; CID=""
echo 'ok - real long-running PySpark driver TERM/INT and restart drain Python children before post-hooks'
