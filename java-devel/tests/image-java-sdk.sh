#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-java-sdk.sh IMAGE VERSION}"
VERSION="${2:?Expected JDK major version}"
TEST_IMAGE="java-devel-native-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
for user in kubedoop root; do
    docker run --rm --user "$user" "$IMAGE" bash -c '
        set -euo pipefail
        test "$JAVA_VERSION" = "$1"
        test "$JAVA_HOME" = "/usr/lib/jvm/temurin-$1-jdk"
        test "$LOG4J_FORMAT_MSG_NO_LOOKUPS" = true
        home=$(readlink -f "$JAVA_HOME")
        for tool in java javac jar javadoc javap; do
            test "$(readlink -f "$(type -P "$tool")")" = "$home/bin/$tool"
        done
        if [[ "$1" == 8 ]]; then expected=1.8; else expected="$1"; fi
        actual=$(java -XshowSettings:properties -version 2>&1)
        grep -Eq "java.specification.version = ${expected//./\\.}$" <<< "$actual"
        javac -version 2>&1 | grep -Eq "^javac ${expected//./\\.}\\."
        actual=$(mvn -B -Dstyle.color=never --version 2>&1)
        grep -Eq "Java version: ${expected//./\\.}\\." <<< "$actual"
    ' bash "$VERSION" || fail "JDK/Maven tools or JAVA_HOME mismatched as $user"
    docker build -q --build-arg "IMAGE=$IMAGE" --build-arg "COMPILE_USER=$user" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null || fail "actual offline JDK$VERSION compile/jar/javadoc failed as $user"
    CID=$(docker run -d --user "$user" "$TEST_IMAGE")
    expected_order=""
    for cycle in 1 2 3; do
        for ((attempt=0; attempt<100; attempt++)); do
            logs=$(docker logs "$CID" 2>&1)
            if [[ "$(grep -c '^TEST_JAVA_READY$' <<< "$logs")" == "$cycle" ]]; then break; fi
            sleep 0.1
        done
        [[ "$(grep -c '^TEST_JAVA_READY$' <<< "$logs")" == "$cycle" ]] || fail 'compiled JAR not ready'
        case "$cycle" in
            1) docker kill --signal TERM "$CID" >/dev/null ;;
            2) docker kill --signal INT "$CID" >/dev/null ;;
            3) docker stop -t 15 "$CID" >/dev/null ;;
        esac
        status=$(timeout 15 docker wait "$CID") || fail 'JVM shutdown timed out'
        # The supervisor turns either container TERM or INT into graceful TERM.
        [[ "$status" == 143 ]] || fail "JVM SIGTERM exit status changed: $status"
        logs=$(docker logs "$CID" 2>&1)
        order=$(grep -E '^TEST_JAVA_(READY|FLUSHED|POST)$' <<< "$logs")
        [[ "$cycle" == 1 ]] || expected_order+=$'\n'
        expected_order+=$'TEST_JAVA_READY\nTEST_JAVA_FLUSHED\nTEST_JAVA_POST'
        [[ "$order" == "$expected_order" ]] || fail 'JVM shutdown persistence/post hooks duplicated or reordered'
        ! grep -Eq 'sending SIGKILL|post-script: .*failed' <<< "$logs" || fail 'JVM escalated or hook failed'
        docker cp "$CID:/kubedoop/run/java-state" "$TMP_DIR/state"
        [[ "$(cat "$TMP_DIR/state")" == "$cycle" ]] || fail 'compiled JAR state lost on restart'
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null; fi
    done
    docker rm "$CID" >/dev/null
    CID=""
    rc=0
    output=$(docker run --rm --user "$user" "$TEST_IMAGE" java -jar /kubedoop/run/workload.jar exit42 2>&1) || rc=$?
    [[ "$rc" == 42 ]] || fail "JVM System.exit42 changed: $rc"
    grep -qx TEST_JAVA_POST <<< "$output" || fail 'normal-exit JVM post hook missing'
    echo "ok - actual JDK$VERSION javac/jar/javadoc/javap/Maven, inherited child CMD, 3 persisted starts, container TERM/INT/stop, JVM143/42 and flush-before-post as $user"
done
