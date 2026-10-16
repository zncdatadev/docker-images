#!/bin/bash
# Real KRaft broker acceptance: hook initialization, messages, shutdown, restart.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?usage: image-kafka-lifecycle.sh IMAGE}"
TEST_IMAGE="kafka-broker-lifecycle-test:$(date +%s)-$$"
TMP_DIR=$(mktemp -d)
CID=""
CONTAINER_IDS=()

cleanup() {
    for cid in "${CONTAINER_IDS[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

exec_with_timeout() {
    local seconds="$1"
    shift
    # A host-only timeout kills the Docker client but leaves docker exec's JVM
    # running. Enforce the deadline inside the container, with a longer outer
    # watchdog for an unresponsive Docker API. Preserve stdin for the producer.
    timeout --kill-after=2 "$((seconds + 10))" docker exec -i "$CID" \
        timeout --kill-after=2 "$seconds" "$@"
}

fail() {
    if [[ -n "$CID" ]]; then
        docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CID" >&2 || true
        docker logs "$CID" --tail 80 >&2 || true
    fi
    echo "not ok - $*" >&2
    exit 1
}

wait_for_broker() {
    local attempt
    for ((attempt=0; attempt<12; attempt++)); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail "broker exited before readiness"
        if exec_with_timeout 10 kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "broker did not become ready"
}

read_messages() {
    local output
    output=$(exec_with_timeout 30 kafka-console-consumer.sh \
        --bootstrap-server 127.0.0.1:9092 --topic lifecycle-test \
        --from-beginning --max-messages 2 --timeout-ms 20000 2>/dev/null) || fail "failed to consume messages"
    [[ "$output" == $'lifecycle-first\nlifecycle-second' ]] || fail "message content or order changed: $output"
}

test_cli_timeout() {
    local pid rc expected mode
    for mode in normal ignore-term; do
        rc=0
        pid=$(exec_with_timeout 1 bash -c '
            if [[ "$1" == ignore-term ]]; then trap "" TERM; fi
            echo $$
            exec sleep 60
        ' bash "$mode") || rc=$?
        expected=124
        if [[ "$mode" == ignore-term ]]; then expected=137; fi
        [[ "$rc" == "$expected" && "$pid" =~ ^[0-9]+$ ]] || fail "CLI timeout did not enforce its deadline ($mode, status $rc)"
        docker exec "$CID" bash -c '! kill -0 "$1" 2>/dev/null' bash "$pid" || fail "timed-out CLI process remained running ($mode)"
    done
    echo 'ok - CLI deadlines terminate container processes, including SIGTERM-ignoring commands'
}

stop_and_check() {
    local expected_runs="$1" output
    case "$expected_runs" in
        1) docker kill --signal TERM "$CID" >/dev/null || fail 'TERM failed' ;;
        2) docker kill --signal INT "$CID" >/dev/null || fail 'INT failed' ;;
        3) docker stop -t 40 "$CID" >/dev/null || fail 'docker stop failed' ;;
    esac
    output=$(timeout 45 docker wait "$CID") || fail 'broker shutdown was unbounded'
    [[ "$output" == 143 ]] || fail "broker exit status changed to $output"
    output=$(docker logs "$CID" 2>&1)
    [[ "$(grep -xc TEST_KAFKA_POST_DONE <<< "$output")" == "$expected_runs" ]] || fail "post-script did not run after broker shutdown"
    [[ "$(grep -c '\[kubedoop\] \[INFO\] Shutdown complete$' <<< "$output")" == "$expected_runs" ]] || fail "framework cleanup did not finish exactly once"
    if grep -Fq 'sending SIGKILL' <<< "$output"; then fail "broker required SIGKILL escalation"; fi
    local events expected="" i
    events=$(docker cp "$CID:/kubedoop/run/kafka-events" - | tar -xO | tr '\n' ',')
    for ((i=0;i<expected_runs;i++)); do expected+=PRE,POST,; done
    [[ "$events" == "$expected" ]] || fail "hook order/count changed: $events"
}

docker image inspect "$IMAGE" >/dev/null || fail 'source-built image missing locally'
cp "$SCRIPT_DIR"/fixtures/* "$TMP_DIR/"
cat > "$TMP_DIR/Dockerfile" <<EOF
FROM ${IMAGE}
USER root
COPY --chown=root:root server.properties /kubedoop/run/server.properties
COPY --chown=root:root 10-format.sh /kubedoop/mount/pre-script/10-format.sh
COPY --chown=root:root 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-format.sh /kubedoop/mount/post-script/10-check-stopped.sh
USER kubedoop
ENV KAFKA_HEAP_OPTS="-Xms256m -Xmx512m"
CMD ["kafka-server-start.sh", "/kubedoop/run/server.properties"]
EOF
docker build -q -t "$TEST_IMAGE" "$TMP_DIR" >/dev/null || fail "failed to build broker test image"
for identity in kubedoop root; do
    options=()
    [[ "$identity" != root ]] || options=(--user root)
    CID=$(docker run -d "${options[@]}" "$TEST_IMAGE") || fail 'failed to start broker'
    CONTAINER_IDS+=("$CID")
    for cycle in 1 2 3; do
        wait_for_broker
        [[ $(docker exec "$CID" cat /proc/1/comm) == tini ]] || fail 'Tini PID1 changed'
        if [[ "$cycle" == 1 ]]; then
            test_cli_timeout
            exec_with_timeout 30 kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
                --create --topic lifecycle-test --partitions 1 --replication-factor 1 >/dev/null || fail 'failed to create topic'
            printf 'lifecycle-first\nlifecycle-second\n' | exec_with_timeout 30 kafka-console-producer.sh \
                --bootstrap-server 127.0.0.1:9092 --topic lifecycle-test || fail 'failed to produce messages'
            metadata_before=$(docker exec "$CID" sha256sum /kubedoop/run/data/meta.properties)
        fi
        read_messages
        metadata_after=$(docker exec "$CID" sha256sum /kubedoop/run/data/meta.properties)
        [[ "$metadata_before" == "$metadata_after" ]] || fail 'KRaft identity changed after restart'
        stop_and_check "$cycle"
        if [[ "$cycle" -lt 3 ]]; then docker start "$CID" >/dev/null || fail 'failed to restart broker'; fi
    done
    echo "ok - $identity Kafka persists identity/messages, three same-CID starts, TERM/INT/stop, exactly-once ordered hooks"
done
