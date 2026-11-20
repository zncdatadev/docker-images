#!/bin/bash
# Real version-specific CLI and scheduler/database persistence without external services.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-airflow-lifecycle.sh IMAGE}"
TEST_IMAGE="airflow-lifecycle-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 100 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
version=$(docker run --rm "$IMAGE" airflow version)
case "$version" in
    2.*) executor=SequentialExecutor; frontend=webserver ;;
    3.*) executor=LocalExecutor; frontend=api-server ;;
    *) fail "unexpected Airflow version $version" ;;
esac
if [[ "$version" == 2.* ]]; then
    docker run --rm -e CONNECTION_CHECK_MAX_COUNT=0 "$IMAGE" sync-perm --help >/dev/null || fail 'native sync-perm short command failed'
fi
for role in "$frontend" scheduler triggerer dag-processor; do
    docker run --rm -e CONNECTION_CHECK_MAX_COUNT=0 "$IMAGE" airflow "$role" --help >/dev/null || fail "native $role help failed"
done
# Airflow 2 exposes executor CLI only for configured executors and rejects
# Celery+SQLite before parsing help. A valid dialect config with checks disabled
# exercises native help without starting or connecting to an external service.
docker run --rm -e CONNECTION_CHECK_MAX_COUNT=0 \
    -e AIRFLOW__CORE__EXECUTOR=CeleryExecutor \
    -e AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow@127.0.0.1:5432/airflow \
    "$IMAGE" airflow celery worker --help >/dev/null || fail 'native Celery worker CLI failed'
docker run --rm --user root "$IMAGE" airflow version >/dev/null || fail 'root lost project venv'
echo "ok - $version native frontend, scheduler, triggerer, dag-processor and Celery CLI"
docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "EXECUTOR=$executor" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
CID=$(docker run -d "$TEST_IMAGE" scheduler)
wait_scheduler() {
    local deadline=$((SECONDS + 90))
    while ((SECONDS < deadline)); do
        if docker exec "$CID" python -c "import sqlite3; c=sqlite3.connect('/kubedoop/airflow/airflow.db'); assert c.execute(\"select count(*) from job where job_type like '%Scheduler%' and state='running'\").fetchone()[0] > 0" >/dev/null 2>&1; then return; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail 'real scheduler exited during startup'
        sleep 1
    done
    fail 'real scheduler failed to register running job'
}
job_count() {
    docker exec "$CID" python -c "import sqlite3; c=sqlite3.connect('/kubedoop/airflow/airflow.db'); print(c.execute(\"select count(*) from job where job_type like '%Scheduler%'\").fetchone()[0])"
}
stop_scheduler() {
    local signal="$1" count="$2" status logs
    docker kill --signal "$signal" "$CID" >/dev/null
    timeout 40 docker wait "$CID" >/dev/null || fail 'real scheduler shutdown timeout'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "scheduler status $status"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_AIRFLOW_PRE$' <<< "$logs")" == "$count" ]] || fail 'pre-hook count'
    [[ "$(grep -c '^TEST_AIRFLOW_POST$' <<< "$logs")" == "$count" ]] || fail 'post-hook count or live child'
    ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'scheduler escalated or hooks failed'
}
wait_scheduler
first_count=$(job_count)
stop_scheduler TERM 1
docker start "$CID" >/dev/null
wait_scheduler
second_count=$(job_count)
((second_count > first_count)) || fail 'old scheduler database state lost on restart'
stop_scheduler INT 2
echo "ok - $version real scheduler job registration, persisted database restart, TERM/INT and exactly-once hooks"
