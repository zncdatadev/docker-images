#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-java-lifecycle.sh IMAGE VERSION SOURCE_BUILT_JDK8_IMAGE}"
VERSION="${2:?Expected Java major version}"
SDK_IMAGE="${3:?Source-built JDK8 image}"
TEST_IMAGE="java-base-native-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" bash -c '
    set -euo pipefail
    test "$JAVA_VERSION" = "$1"
    test "$JAVA_HOME" = "/usr/lib/jvm/temurin-$1-jre"
    test "$LOG4J_FORMAT_MSG_NO_LOOKUPS" = true
    test -x "$JAVA_HOME/bin/java"
    if [[ "$1" == 8 ]]; then expected=1.8; else expected="$1"; fi
    for executable in "$JAVA_HOME/bin/java" "$(command -v java)"; do
        actual=$("$executable" -XshowSettings:properties -version 2>&1)
        grep -Eq "java.specification.version = ${expected//./\\.}$" <<< "$actual"
    done
    java -version
' bash "$VERSION" || fail 'actual JAVA_HOME or JRE version/mitigation changed'
docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "SDK_IMAGE=$SDK_IMAGE" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null || fail 'Java8 bytecode compilation failed'
for user in kubedoop root; do
    CID=$(docker run -d --user "$user" "$TEST_IMAGE")
    for cycle in 1 2; do
        for ((attempt=0; attempt<100; attempt++)); do
            logs=$(docker logs "$CID" 2>&1)
            if [[ "$(grep -c '^TEST_JAVA_READY$' <<< "$logs")" == "$cycle" ]]; then break; fi
            sleep 0.1
        done
        [[ "$(grep -c '^TEST_JAVA_READY$' <<< "$logs")" == "$cycle" ]] || fail 'real JVM not ready'
        if [[ "$cycle" == 1 ]]; then docker kill --signal TERM "$CID" >/dev/null; else docker stop -t 15 "$CID" >/dev/null; fi
        status=$(timeout 15 docker wait "$CID") || fail 'JVM shutdown timed out'
        [[ "$status" == 143 ]] || fail "JVM SIGTERM exit status changed: $status"
        logs=$(docker logs "$CID" 2>&1)
        order=$(grep -E '^TEST_JAVA_(READY|FLUSHED|POST)$' <<< "$logs")
        expected=$'TEST_JAVA_READY\nTEST_JAVA_FLUSHED\nTEST_JAVA_POST'
        if [[ "$cycle" == 2 ]]; then expected+=$'\nTEST_JAVA_READY\nTEST_JAVA_FLUSHED\nTEST_JAVA_POST'; fi
        [[ "$order" == "$expected" ]] || fail 'JVM persistence and post hooks out of order or duplicated'
        ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'JVM escalated or post hook failed'
        docker cp "$CID:/kubedoop/run/java-state" "$TMP_DIR/state"
        [[ "$(cat "$TMP_DIR/state")" == "$cycle" ]] || fail 'JVM persisted state lost on restart'
        if [[ "$cycle" == 1 ]]; then docker start "$CID" >/dev/null; fi
    done
    docker rm "$CID" >/dev/null
    CID=""
    rc=0
    output=$(docker run --rm --user "$user" "$TEST_IMAGE" java -cp /kubedoop/run Workload exit42 2>&1) || rc=$?
    [[ "$rc" == 42 ]] || fail "JVM System.exit42 changed: $rc"
    grep -qx TEST_JAVA_POST <<< "$output" || fail 'normal-exit JVM post hook missing'
    echo "ok - actual JRE$VERSION Java8 bytecode, private child inheritance, persisted restart, TERM143/exit42/flush-before-post as $user"
done
