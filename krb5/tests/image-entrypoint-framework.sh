#!/bin/bash
set -euo pipefail
directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image="${1:-quay.io/zncdatadev/krb5:1.21.1-kubedoop0.0.0-dev}"
fixture="krb5-framework-test:$(date +%s)-$$"
containers=()
cleanup() {
    for cid in "${containers[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$fixture" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
expect() {
    local expected=$1 status=0; shift
    "$@" || status=$?
    [[ $status == "$expected" ]] || fail "expected $expected, got $status"
}
wait_marker() {
    local cid=$1 marker=$2
    for ((i=0;i<100;i++)); do
        if docker exec "$cid" test -f "$marker" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}
[[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" == '["/usr/local/sbin/init"]' ]] || fail ENTRYPOINT
[[ "$(docker image inspect -f '{{.Config.StopSignal}}' "$image")" == SIGRTMIN+3 ]] || fail STOPSIGNAL
for relative in bin/init.sh bin/command.sh bin/foreground.sh bin/post.sh bin/setup.sh lib/log.sh lib/run.sh lib/signal.sh; do
    source_file="$directory/../kubedoop/$relative"
    if [[ $relative == bin/setup.sh ]]; then source_file="$directory/../krb5-setup"; fi
    expected=$(sha256sum "$source_file" | awk '{print $1}')
    actual=$(docker run --rm --entrypoint sha256sum "$image" "/usr/local/libexec/kubedoop-krb5/$relative" | awk '{print $1}')
    [[ $expected == "$actual" ]] || fail "stale $relative"
done
output=$(printf 'CLEAN_STDIN\n' | docker run --rm -i "$image" --exec cat)
[[ "$output" == CLEAN_STDIN ]] || fail stdin
expect 7 docker run --rm "$image" --exec bash -c 'exit 7'
expect 127 docker run --rm "$image" --exec bash -c 'exit 127'
output=$(printf 'UNPRIVILEGED_STDIN\n' | docker run --rm -i --user 65534:65534 "$image" --exec cat)
[[ "$output" == UNPRIVILEGED_STDIN ]] || fail 'unprivileged stdin'
docker run --rm --user 65534:65534 --entrypoint bash "$image" -c '
    set -euo pipefail
    for path in /usr/local/libexec/kubedoop-krb5 /usr/local/libexec/kubedoop-krb5/bin /usr/local/libexec/kubedoop-krb5/lib /kubedoop/mount; do
        test ! -w "$path"
    done
    test -w /kubedoop/run
'
expect 1 docker run --rm -e KUBEDOOP_KILL_TIMEOUT=bad "$image" --exec true
expect 2 docker run --rm "$image" --realm
docker run --rm "$image" --help >/dev/null
docker build --pull=false --build-arg BASE_IMAGE="$image" -t "$fixture" "$directory/fixtures"
expect 1 docker run --rm -e TEST_FAIL_PRE=true "$fixture" --exec true
expect 1 docker run --rm -e TEST_FAIL_PRE=true "$fixture"
expect 7 docker run --rm -e TEST_FAIL_POST=true "$fixture" --exec bash -c 'exit 7'
for signal in TERM INT RTMIN+3; do
    cid=$(docker run -d "$fixture" --exec bash -c '
        trap '\''echo FLUSH >> /kubedoop/run/events; exit 42'\'' TERM
        touch /kubedoop/run/ready
        while :; do sleep 0.1; done
    ')
    containers+=("$cid")
    wait_marker "$cid" /kubedoop/run/ready || fail readiness
    docker kill --signal="$signal" "$cid" >/dev/null
    [[ "$(docker wait "$cid")" == 42 ]] || fail "$signal exit status"
    events=$(docker cp "$cid:/kubedoop/run/events" - | tar -xO | tr '\n' ',')
    [[ $events == PRE,FLUSH,POST, ]] || fail "$signal hook order"
done
cid=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT=1 "$fixture" --exec bash -c '
    trap "" TERM
    touch /kubedoop/run/ready
    while :; do sleep 0.1; done
')
containers+=("$cid")
wait_marker "$cid" /kubedoop/run/ready || fail readiness
docker stop -t 8 "$cid" >/dev/null
[[ "$(docker wait "$cid")" == 137 ]] || fail timeout
events=$(docker cp "$cid:/kubedoop/run/events" - | tar -xO | tr '\n' ',')
[[ $events == PRE,POST, ]] || fail "timeout post hook"
cid=$(docker run -d "$image" --exec sleep 60)
containers+=("$cid")
[[ "$(docker exec "$cid" cat /proc/1/comm)" == tini ]] || fail "opt-in PID1"
orphan=$(docker exec "$cid" bash -c 'sleep 0.2 & echo $!')
sleep 1
docker exec "$cid" test ! -e "/proc/$orphan" || fail "orphan reaping"
docker stop -t 5 "$cid" >/dev/null
secret=TEST_SECRET_NOT_LOGGED_$(date +%s)
output=$(docker run --rm "$image" --exec true "$secret" 2>&1)
[[ $output != *"$secret"* ]] || fail "argv logging"
echo 'ok - packaging, stdin/stdout, statuses, projected hooks, TERM/INT/stop, KILL, reaping, secret logging'
