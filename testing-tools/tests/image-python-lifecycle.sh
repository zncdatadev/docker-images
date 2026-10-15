#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-python-lifecycle.sh IMAGE}"
TEST_IMAGE="testing-tools-python-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" python3 -c 'import requests, pandas, nipyapi, trino, gssapi, kerberos, thrift, bs4, pytest, kafka3; print("TEST_NATIVE_IMPORTS")'
docker run --rm "$IMAGE" python3 -m pip check
docker run --rm "$IMAGE" python3 -c 'from io import BytesIO; from kafka3.protocol.types import Int32; from kafka3.vendor.six.moves.urllib.parse import urlparse; assert Int32.decode(BytesIO(Int32.encode(42))) == 42; assert urlparse("https://localhost/test").path == "/test"; print("TEST_NATIVE_KAFKA_CODEC")'
docker build -q --build-arg "IMAGE=$IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
for user in kubedoop root; do
    docker run --rm --user "$user" "$IMAGE" bash -c '
        set -euo pipefail
        java -version 2>&1 | grep -q '\''version "11\.'\''
        kubectl version --client=true >/dev/null
        kcadm.sh help >/dev/null
        kcreg.sh help >/dev/null
        java17="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
        JAVA_HOME="$java17" kcadm.sh help >/dev/null
        JAVA="$java17/bin/java" /kubedoop/keycloak/bin/kcreg.sh help >/dev/null
        rc=0
        JAVA=/bin/false kcadm.sh help >/dev/null 2>&1 || rc=$?
        [[ "$rc" == 1 ]]
    ' || fail 'Java11 default or actual Keycloak/kubectl CLI failed'
    CID=$(docker run -d --user "$user" "$TEST_IMAGE")
    for cycle in 1 2; do
        for ((attempt=0; attempt<100; attempt++)); do
            if docker exec "$CID" python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",18991),timeout=1); s.close()' >/dev/null 2>&1; then break; fi
            sleep 0.1
        done
        output=$(docker exec "$CID" python3 -c 'import requests; print(requests.get("http://127.0.0.1:18991",timeout=5).json()["count"])') || fail 'native Python/requests HTTP operation failed'
        [[ "$output" == "$cycle" ]] || fail 'Python state did not survive restart'
        if [[ "$cycle" == 1 ]]; then signal=TERM; else signal=INT; fi
        docker kill --signal "$signal" "$CID" >/dev/null
        status=$(timeout 15 docker wait "$CID") || fail 'native Python shutdown timed out'
        [[ "$status" == 42 ]] || fail "Python shutdown status changed: $status"
        logs=$(docker logs "$CID" 2>&1)
        [[ "$(grep -c '^TEST_PYTHON_FLUSHED$' <<< "$logs")" == "$cycle" && "$(grep -c '^TEST_PYTHON_POST$' <<< "$logs")" == "$cycle" ]] || fail 'flush/post count invalid'
        ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'native Python escalated or post hook failed'
        if [[ "$cycle" == 1 ]]; then docker start "$CID" >/dev/null; fi
    done
    docker rm "$CID" >/dev/null
    CID=""
    echo "ok - actual Python/requests HTTP, persisted same-container restart, flushed TERM/INT before post hooks, status42 as $user"
done
