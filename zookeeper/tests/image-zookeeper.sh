#!/bin/bash
# Real default-command ZooKeeper, persisted znodes and exactly-once hooks.
set -euo pipefail
directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image=${1:?pass the full original locally built ZooKeeper image}
fixture="zookeeper-lifecycle-test:$(date +%s)-$$"
containers=()
cleanup() {
    for cid in "${containers[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$fixture" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
    echo "not ok - $*" >&2
    for cid in "${containers[@]}"; do
        docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$cid" >&2 || true
        docker logs "$cid" >&2 2>&1 || true
    done
    exit 1
}
docker image inspect "$image" >/dev/null
docker build --pull=false --build-arg BASE_IMAGE="$image" -t "$fixture" "$directory/fixtures"
ready() {
    local cid=$1 started
    started=$(docker inspect -f '{{.State.StartedAt}}' "$cid")
    for ((i=0;i<60;i++)); do
        if docker logs --since "$started" "$cid" 2>&1 | grep -F 'PrepRequestProcessor (sid:0) started' >/dev/null; then return 0; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$cid") == true ]] || break
        sleep 1
    done
    return 1
}
for identity in kubedoop root; do
    options=()
    [[ $identity != root ]] || options=(--user root)
    cid=$(docker run -d "${options[@]}" "$fixture")
    containers+=("$cid")
    node="/universal-process-$identity"
    value="persisted-$identity"
    for cycle in 1 2 3; do
        ready "$cid" || fail "$identity cycle$cycle readiness"
        [[ $(docker exec "$cid" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        if [[ $cycle == 1 ]]; then
            output=$(printf 'create %s %s\nquit\n' "$node" "$value" | timeout 20 docker exec -i "$cid" bin/zkCli.sh -server 127.0.0.1:2181 2>&1) || fail 'client create failed'
            grep -Fq "Created $node" <<< "$output" || fail 'persistent znode was not created'
        fi
        output=$(printf 'get %s\nquit\n' "$node" | timeout 20 docker exec -i "$cid" bin/zkCli.sh -server 127.0.0.1:2181 2>&1) || fail 'client get failed'
        grep -Fq SyncConnected <<< "$output" || fail 'client session not connected'
        grep -Fxq "$value" <<< "$output" || fail "$identity znode did not persist across restart"
        if [[ $cycle == 1 ]]; then
            docker kill --signal TERM "$cid" >/dev/null
        elif [[ $cycle == 2 ]]; then
            docker kill --signal INT "$cid" >/dev/null
        else
            docker stop -t 40 "$cid" >/dev/null
        fi
        status=$(timeout 45 docker wait "$cid") || fail 'shutdown was unbounded'
        [[ $status == 143 ]] || fail "$identity graceful status changed to $status"
        events=$(docker cp "$cid:/kubedoop/run/zookeeper-events" - | tar -xO | tr '\n' ',')
        expected=""
        for ((j=0;j<cycle;j++)); do expected+=PRE,POST,; done
        [[ $events == "$expected" ]] || fail "$identity pre/post order/count $events"
        logs=$(docker logs "$cid" 2>&1)
        if grep -Fq 'sending SIGKILL' <<< "$logs"; then fail "$identity JVM needed forced KILL"; fi
        if [[ $cycle -lt 3 ]]; then docker start "$cid" >/dev/null; fi
    done
    echo "ok - $identity actual default ZooKeeper, persisted znode, three same-CID starts/stops, TERM/INT/stop and ordered hooks"
done
