#!/bin/bash
# Real Gunicorn workers, private Superset metadata and in-flight request shutdown.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-superset-lifecycle.sh IMAGE}"
TEST_IMAGE="superset-lifecycle-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""; CLIENT_PID=""
cleanup() {
    [[ -z "$CLIENT_PID" ]] || kill "$CLIENT_PID" 2>/dev/null || true
    [[ -z "$CLIENT_PID" ]] || wait "$CLIENT_PID" 2>/dev/null || true
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 100 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
for role in worker beat; do
    docker run --rm "$TEST_IMAGE" "$role" --help >/dev/null || fail "native $role CLI failed"
done
docker run --rm "$TEST_IMAGE" superset version >/dev/null || fail 'native Superset CLI failed'
docker run --rm --user root "$TEST_IMAGE" superset version >/dev/null || fail 'root lost native venv'
echo 'ok - native Superset/root venv and Celery worker/beat CLI'
CID=$(docker run -d "$TEST_IMAGE")
wait_health() {
    local deadline=$((SECONDS + 90))
    while ((SECONDS < deadline)); do
        if docker exec "$CID" python -c "import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8088/health',timeout=2).read().strip()==b'OK'" >/dev/null 2>&1; then return; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail 'real Gunicorn exited during startup'
        sleep 1
    done
    fail 'real Superset Gunicorn health timeout'
}
metadata_identity() {
    docker exec "$CID" python -c "import sqlite3,hashlib; c=sqlite3.connect('/kubedoop/run/superset.db'); row=c.execute(\"select id,password from ab_user where username='lifecycle_admin'\").fetchone(); assert row is not None; print(hashlib.sha256(repr(row).encode()).hexdigest())"
}
stop_with_request() {
    local signal="$1" count="$2" deadline=$((SECONDS + 15)) logs status
    docker exec "$CID" python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8088/lifecycle/hold',timeout=15).read().decode())" >"$TMP_DIR/client" 2>"$TMP_DIR/client-error" & CLIENT_PID=$!
    while ! docker exec "$CID" test -e /kubedoop/run/hold-started; do
        ((SECONDS < deadline)) || fail 'in-flight HTTP request not ready'
        sleep 0.05
    done
    docker kill --signal "$signal" "$CID" >/dev/null
    wait "$CLIENT_PID" || fail 'real HTTP request was interrupted during shutdown'
    CLIENT_PID=""
    grep -Fxq REQUEST_COMPLETED "$TMP_DIR/client" || fail 'in-flight request response missing'
    timeout 30 docker wait "$CID" >/dev/null || fail 'Gunicorn shutdown timeout'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "Gunicorn status $status"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_SUPERSET_PRE$' <<< "$logs")" == "$count" ]] || fail 'pre-hook count'
    [[ "$(grep -c '^TEST_SUPERSET_POST$' <<< "$logs")" == "$count" ]] || fail 'post-hook count/live workers or interrupted request'
    ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'Gunicorn escalated or hooks failed'
}
wait_health
identity=$(metadata_identity)
stop_with_request TERM 1
docker start "$CID" >/dev/null
wait_health
[[ "$(metadata_identity)" == "$identity" ]] || fail 'native Superset user metadata lost on restart'
stop_with_request INT 2
echo 'ok - real Superset/Gunicorn health, persisted metadata, same-container restart, TERM/INT with in-flight HTTP completion and hooks after workers stop'
