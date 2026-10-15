#!/bin/bash
# Actual native file/VRL/sink checkpoints and inherited child entrypoint behavior.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-vector-lifecycle.sh IMAGE}"
TEST_IMAGE="vector-lifecycle-test:$(date +%s)-$$"
LEGACY_IMAGE="$TEST_IMAGE-legacy"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" "$LEGACY_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 100 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" vector --version | grep -Fq 0.47.0 || fail 'native Vector version'
docker run --rm "$IMAGE" bash -c '
    set -euo pipefail
    directory=$(mktemp -d)
    trap '\''rm -rf "$directory"'\'' EXIT
    inotifywait -t 10 -e create "$directory" >"$directory.events" 2>"$directory.ready" & watcher=$!
    for ((attempt=0; attempt<100; attempt++)); do
        grep -q "Watches established" "$directory.ready" && break
        sleep 0.05
    done
    grep -q "Watches established" "$directory.ready"
    touch "$directory/observed"
    wait "$watcher"
    grep -q "CREATE observed" "$directory.events"
    rm -f "$directory.events" "$directory.ready"
' >/dev/null || fail 'native inotify event observation failed'
[[ "$(docker run --rm "$IMAGE" gomplate -i '{{ "ok" }}')" == ok ]] || fail 'native gomplate template'
docker build -q --build-arg "IMAGE=$IMAGE" -f "$SCRIPT_DIR/fixtures/LegacyDockerfile" -t "$LEGACY_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
rc=0
docker run --rm "$LEGACY_IMAGE" >"$TMP_DIR/legacy" 2>&1 || rc=$?
[[ "$rc" == 42 ]] || fail 'legacy child ENTRYPOINT status lost'
[[ "$(grep -c '^TEST_LEGACY_PRODUCT_ENTRYPOINT$' "$TMP_DIR/legacy")" == 1 ]] || fail 'legacy child script not invoked exactly once'
[[ "$(grep -c '^TEST_VECTOR_PRE$' "$TMP_DIR/legacy")" == 1 && "$(grep -c '^TEST_VECTOR_POST$' "$TMP_DIR/legacy")" == 1 ]] || fail 'inherited hooks not exactly once'
echo 'ok - inherited supervisor survives legacy product entrypoint replacement and retains child status'
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
CID=$(docker run -d "$TEST_IMAGE")
wait_records() {
    local count="$1" deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        if docker exec "$CID" bash -c 'test -f /kubedoop/run/output.json && [[ "$(wc -l < /kubedoop/run/output.json)" -ge "$1" ]]' bash "$count" >/dev/null 2>&1; then return; fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail 'Vector exited during native pipeline'
        sleep 0.2
    done
    fail 'native Vector file/VRL/sink pipeline timeout'
}
stop_vector() {
    local signal="$1" count="$2" logs status
    docker kill --signal "$signal" "$CID" >/dev/null
    timeout 40 docker wait "$CID" >/dev/null || fail 'Vector flush shutdown timeout'
    status=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
    [[ "$status" == 0 || "$status" == 143 ]] || fail "Vector status $status"
    logs=$(docker logs "$CID" 2>&1)
    [[ "$(grep -c '^TEST_VECTOR_PRE$' <<< "$logs")" == "$count" && "$(grep -c '^TEST_VECTOR_POST$' <<< "$logs")" == "$count" ]] || fail 'hook count or live Vector before post'
    ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'Vector escalated or hook failed'
}
wait_records 2
stop_vector TERM 1
docker start "$CID" >/dev/null
docker exec "$CID" bash -c 'printf "gamma\n" >> /kubedoop/run/input.log'
wait_records 3
stop_vector INT 2
docker cp "$CID:/kubedoop/run/output.json" "$TMP_DIR/output.json"
[[ "$(wc -l < "$TMP_DIR/output.json")" == 3 ]] || fail 'file checkpoint restart duplicated or lost records'
for message in alpha beta gamma; do
    [[ "$(grep -Ec "\"message\"[[:space:]]*:[[:space:]]*\"$message\"" "$TMP_DIR/output.json")" == 1 ]] || fail "native record $message count"
done
[[ "$(grep -Ec '"managed"[[:space:]]*:[[:space:]]*true' "$TMP_DIR/output.json")" == 3 ]] || fail 'native VRL transform missing'
echo 'ok - real Vector file/VRL/sink, persisted checkpoints without duplicates, same-container restart and TERM/INT flushed before post-hooks'
