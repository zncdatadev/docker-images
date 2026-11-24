#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-inheritance.sh SOURCE_BUILT_BASE_IMAGE}"
TEST_IMAGE="kubedoop-base-child-test:$(date +%s)-$$"
OVERRIDE_IMAGE="kubedoop-base-override-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" "$OVERRIDE_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker build -q --target inherited --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
docker build -q --target overridden --build-arg "IMAGE=$IMAGE" -t "$OVERRIDE_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
metadata=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{.Config.User}} {{.Config.WorkingDir}}' "$TEST_IMAGE")
[[ "$metadata" == *'/usr/local/libexec/kubedoop-base/bin/entrypoint.sh'* && "$metadata" == *'kubedoop /kubedoop/run' ]] || fail 'child ENTRYPOINT/USER/working-directory inheritance invalid'
output=$(docker run --rm "$OVERRIDE_IMAGE") || fail 'explicit child ENTRYPOINT override failed'
[[ "$output" == TEST_OVERRIDE_ENTRYPOINT ]] || fail 'base supervisor intercepted explicit ENTRYPOINT override'
for user in kubedoop root; do
    CID=$(docker run -d --user "$user" -e KUBEDOOP_KILL_TIMEOUT=2 "$TEST_IMAGE")
    expected_order=""
    for cycle in 1 2 3; do
        for ((attempt=0; attempt<100; attempt++)); do
            logs=$(docker logs "$CID" 2>&1)
            if [[ "$(grep -c '^TEST_BASE_READY$' <<< "$logs")" == "$cycle" ]]; then break; fi
            sleep 0.1
        done
        [[ "$(grep -c '^TEST_BASE_READY$' <<< "$logs")" == "$cycle" ]] || fail 'inherited child CMD not ready'
        case "$cycle" in
            1) docker kill --signal TERM "$CID" >/dev/null ;;
            2) docker kill --signal INT "$CID" >/dev/null ;;
            3) docker stop -t 10 "$CID" >/dev/null ;;
        esac
        status=$(timeout 15 docker wait "$CID") || fail 'inherited child shutdown timed out'
        [[ "$status" == 42 ]] || fail "child exit42 changed: $status"
        logs=$(docker logs "$CID" 2>&1)
        order=$(grep -E '^TEST_BASE_(READY|FLUSHED|POST)$' <<< "$logs")
        [[ "$cycle" == 1 ]] || expected_order+=$'\n'
        expected_order+=$'TEST_BASE_READY\nTEST_BASE_FLUSHED\nTEST_BASE_POST'
        [[ "$order" == "$expected_order" ]] || fail 'inherited lifecycle flush/post hooks duplicated or reordered'
        ! grep -Eq 'TEST_UNEXPECTED_LEGACY|sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'legacy COPY hijack, forced kill or post-hook failure'
        docker cp "$CID:/kubedoop/run/base-state" "$TMP_DIR/state"
        [[ "$(cat "$TMP_DIR/state")" == "$cycle" ]] || fail 'child lost state on same-container restart'
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null; fi
    done
    docker rm "$CID" >/dev/null
    CID=""
    echo "ok - inherited child CMD/USER, private helpers versus legacy COPY, 3 persisted starts TERM/INT/stop and exactly-once flush-before-post as $user"
done
echo 'ok - explicit child ENTRYPOINT override remains supported without nested supervisors'
