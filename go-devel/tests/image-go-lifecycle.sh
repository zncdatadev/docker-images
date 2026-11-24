#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-go-lifecycle.sh IMAGE VERSION}"
VERSION="${2:?Expected Go version}"
TEST_IMAGE="go-devel-native-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" go version | grep -Fq "go$VERSION " || fail 'SDK version changed'
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null || fail 'actual offline nonroot Go compile failed'
for user in kubedoop root; do
    CID=$(docker run -d --user "$user" "$TEST_IMAGE")
    for cycle in 1 2; do
        for ((attempt=0; attempt<100; attempt++)); do
            logs=$(docker logs "$CID" 2>&1)
            if [[ "$(grep -c '^TEST_GO_READY$' <<< "$logs")" == "$cycle" ]]; then break; fi
            sleep 0.1
        done
        [[ "$(grep -c '^TEST_GO_READY$' <<< "$logs")" == "$cycle" ]] || fail 'Go binary not ready'
        if [[ "$cycle" == 1 ]]; then signal=TERM; else signal=INT; fi
        docker kill --signal "$signal" "$CID" >/dev/null
        status=$(timeout 15 docker wait "$CID") || fail 'Go binary shutdown timed out'
        [[ "$status" == 42 ]] || fail "Go application exit status changed: $status"
        logs=$(docker logs "$CID" 2>&1)
        [[ "$(grep -c '^TEST_GO_FLUSHED$' <<< "$logs")" == "$cycle" && "$(grep -c '^TEST_GO_POST$' <<< "$logs")" == "$cycle" ]] || fail 'Go flush/post count invalid'
        ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'Go binary escalated or hook failed'
        docker cp "$CID:/kubedoop/run/go-state" "$TMP_DIR/state"
        [[ "$(cat "$TMP_DIR/state")" == "$cycle" ]] || fail 'compiled Go state lost on restart'
        if [[ "$cycle" == 1 ]]; then docker start "$CID" >/dev/null; fi
    done
    docker rm "$CID" >/dev/null
    CID=""
    echo "ok - actual Go$VERSION compile, persisted same-container restart and TERM/INT status42/flush-before-hooks as $user"
done
