#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRODUCT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
IMAGE="${1:?Usage: image-downstream-zookeeper.sh SOURCE_BUILT_ZOOKEEPER_IMAGE}"
TEST_IMAGE="kubedoop-base-zookeeper-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() {
    [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2
    for logfile in "$TMP_DIR"/client-*.log; do
        [[ ! -f "$logfile" ]] || tail -n 40 "$logfile" >&2
    done
    echo "not ok - $*" >&2
    exit 1
}
metadata=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMAGE")
[[ "$metadata" == '["/usr/bin/tini","--","/usr/local/libexec/kubedoop-base/bin/entrypoint.sh"]' ]] || fail 'downstream did not inherit current kubedoop-base entrypoint'
for relative in bin/entrypoint.sh lib/log.sh lib/run.sh lib/signal.sh; do
    expected=$(sha256sum "$PRODUCT_DIR/kubedoop/$relative" | awk '{print $1}')
    actual=$(docker run --rm --pull=never --entrypoint sha256sum "$IMAGE" "/usr/local/libexec/kubedoop-base/$relative" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || fail "downstream has stale kubedoop-base source: $relative"
done
cat > "$TMP_DIR/Dockerfile" <<EOF
FROM $IMAGE
USER root
RUN mkdir -p /kubedoop/run/zk-data \
    && printf '%s\n' 'tickTime=2000' 'dataDir=/kubedoop/run/zk-data' 'clientPort=2181' 'admin.enableServer=false' '4lw.commands.whitelist=ruok' > /kubedoop/run/zoo.cfg \
    && chown -R kubedoop:kubedoop /kubedoop/run
USER kubedoop
CMD ["/kubedoop/zookeeper/bin/zkServer.sh", "start-foreground", "/kubedoop/run/zoo.cfg"]
EOF
docker build -q -t "$TEST_IMAGE" "$TMP_DIR" >/dev/null
CID=$(docker run -d "$TEST_IMAGE")
for cycle in 1 2; do
    ready=false
    for ((attempt=0; attempt<60; attempt++)); do
        if docker exec "$CID" bash -c 'exec 3<>/dev/tcp/127.0.0.1/2181; printf ruok >&3; IFS= read -r -n 4 reply <&3; test "$reply" = imok' >/dev/null 2>&1; then ready=true; break; fi
        sleep 1
    done
    [[ "$ready" == true ]] || fail 'native ZooKeeper not ready'
    if [[ "$cycle" == 1 ]]; then
        printf 'create /kubedoop-base-regression persisted\nquit\n' | docker exec -i "$CID" /kubedoop/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181 > "$TMP_DIR/client-create.log" 2>&1
        grep -Fq 'Created /kubedoop-base-regression' "$TMP_DIR/client-create.log" || fail 'native znode create failed'
    else
        printf 'get /kubedoop-base-regression\nquit\n' | docker exec -i "$CID" /kubedoop/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181 > "$TMP_DIR/client-read.log" 2>&1
        grep -qx persisted "$TMP_DIR/client-read.log" || fail 'native znode lost after restart'
    fi
    docker stop -t 20 "$CID" >/dev/null
    [[ "$(docker inspect -f '{{.State.ExitCode}}' "$CID")" == 143 ]] || fail 'downstream JVM shutdown exit changed'
    logs=$(docker logs "$CID" 2>&1)
    ! grep -Fq 'sending SIGKILL' <<< "$logs" || fail 'downstream JVM forced kill'
    if [[ "$cycle" == 1 ]]; then docker start "$CID" >/dev/null; fi
done
echo 'ok - original source-built ZooKeeper actual foreground lifecycle and persisted znode after same-container restart'
