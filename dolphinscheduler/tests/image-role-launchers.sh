#!/bin/bash
# Native role launchers with an instrumented JVM; not a distributed service test.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-role-launchers.sh IMAGE}"
TEST_IMAGE="dolphin-role-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker build -q --build-arg "IMAGE=$IMAGE" -f "$SCRIPT_DIR/fixtures/role-Dockerfile" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
docker run --rm --entrypoint bash "$IMAGE" -c '
    set -euo pipefail
    for role in standalone-server api-server master-server worker-server alert-server; do
        bin="/kubedoop/dolphinscheduler/$role/bin"
        test "$(grep -c '\''^\$JAVA_HOME/bin/java '\'' "$bin/start.sh")" = 1
        test "$(grep -c '\''^exec "\$JAVA_HOME/bin/java" '\'' "$bin/start-foreground.sh")" = 1
    done
' || fail 'legacy native launchers were modified or foreground copies are missing'
for role in standalone-server api-server master-server worker-server alert-server; do
    case "$role" in
        standalone-server) class=org.apache.dolphinscheduler.StandaloneServer ;;
        api-server) class=org.apache.dolphinscheduler.api.ApiApplicationServer ;;
        master-server) class=org.apache.dolphinscheduler.server.master.MasterServer ;;
        worker-server) class=org.apache.dolphinscheduler.server.worker.WorkerServer ;;
        alert-server) class=org.apache.dolphinscheduler.alert.AlertServer ;;
    esac
    CID=$(docker run -d -e JAVA_OPTS=-Dtest-credential=not-for-logs "$TEST_IMAGE" run-dolphinscheduler "$role" 'arg with spaces')
    ready=false
    for ((i=0;i<50;i++)); do
        if docker logs "$CID" 2>&1 | grep -F TEST_JVM_READY >/dev/null; then ready=true; break; fi
        sleep 0.1
    done
    [[ "$ready" == true ]] || fail "native role launcher did not reach JVM: $role"
    managed=$(docker logs "$CID" 2>&1 | awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' | tail -1)
    [[ "$(docker exec "$CID" cat /kubedoop/run/mock-pid)" == "$managed" ]] || fail "role did not exec JVM"
    args=$(docker exec "$CID" cat /kubedoop/run/mock-args)
    grep -Fxq "$class" <<< "$args" || fail "wrong native role class"
    grep -Fxq 'arg with spaces' <<< "$args" || fail "role lost application argument boundaries"
    grep -Fxq -- '-Dtest-credential=not-for-logs' <<< "$args" || fail "JAVA_OPTS lost"
    ! docker logs "$CID" 2>&1 | grep -F not-for-logs >/dev/null || fail "native launcher leaked JAVA_OPTS"
    docker kill --signal INT "$CID" >/dev/null
    [[ "$(timeout 10 docker wait "$CID")" == 42 ]] || fail "role JVM shutdown status lost"
    docker rm "$CID" >/dev/null; CID=""
    rc=0
    docker run --rm -e TEST_JVM_EXIT=42 "$TEST_IMAGE" run-dolphinscheduler "$role" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 42 ]] || fail "native role normal exit status lost"
    echo "ok - native $role retains class/options/args, execs JVM and preserves normal/signal status"
done
docker run --rm -e JAVA_HOME=/kubedoop/run/legacy-java --entrypoint tini "$TEST_IMAGE" -- bash -c '
    set -euo pipefail
    daemon=/kubedoop/dolphinscheduler/bin/dolphinscheduler-daemon.sh
    "$daemon" start master-server
    for ((i=0;i<50;i++)); do
        [[ ! -f /kubedoop/run/mock-pid ]] || break
        sleep 0.1
    done
    child=$(cat /kubedoop/run/mock-pid)
    "$daemon" status master-server | grep -Fq RUNNING
    timeout 15 "$daemon" stop master-server
    for ((i=0;i<50;i++)); do
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        sleep 0.1
    done
    ! kill -0 "$child" 2>/dev/null
    test ! -f /kubedoop/dolphinscheduler/master-server/pid
' >/dev/null 2>&1 || fail 'legacy daemon start/status/stop no longer manages its native child'
echo 'ok - unchanged legacy daemon start/status/stop still manages the native launcher child'
