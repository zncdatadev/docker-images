#!/bin/bash
# Real krb5kdc/kadmind, ticket issuance, admin RPC, persistence and both init modes.
set -euo pipefail
directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image="${1:-quay.io/zncdatadev/krb5:1.21.1-kubedoop0.0.0-dev}"
fixture="krb5-kdc-test:$(date +%s)-$$"
containers=()
cleanup() {
    for cid in "${containers[@]}"; do docker rm -fv "$cid" >/dev/null 2>&1 || true; done
    docker image rm "$fixture" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
    echo "not ok - $*" >&2
    for cid in "${containers[@]}"; do
        docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' "$cid" >&2 || true
        docker logs "$cid" >&2 2>&1 || true
        # Process names/states only: never dump setup arguments containing passwords.
        docker exec "$cid" ps -eo pid,ppid,pgid,stat,comm >&2 2>&1 || true
    done
    exit 1
}
docker build --pull=false --build-arg BASE_IMAGE="$image" -t "$fixture" "$directory/fixtures"
# Reproduce the old pgrep false positive independently of supervisor scheduling:
# a deliberately non-reaping Python test parent keeps either a live or zombie
# process with each daemon's comm name. These are assertion probes, not KDCs.
for daemon in krb5kdc kadmind; do
    for live in false true; do
        cid=$(docker run -d -e TEST_DAEMON_NAME="$daemon" -e TEST_LIVE="$live" \
            --entrypoint /usr/bin/python3 "$fixture" -c '
import ctypes, os, time
child = os.fork()
if child == 0:
    if ctypes.CDLL(None).prctl(15, os.environ["TEST_DAEMON_NAME"].encode(), 0, 0, 0) != 0:
        os._exit(2)
    if os.environ["TEST_LIVE"] == "false":
        os._exit(0)
time.sleep(120)
')
        containers+=("$cid")
        matched=false
        for ((i=0;i<50;i++)); do
            state=$(docker exec "$cid" ps -C "$daemon" -o stat= || true)
            if [[ $live == false && $state == Z* ]] || [[ $live == true && $state == S* ]]; then
                matched=true
                break
            fi
            sleep 0.1
        done
        [[ $matched == true ]] || fail "$daemon live=$live assertion-probe readiness"
        rc=0
        docker exec "$cid" /kubedoop/mount/post-script/10-post.sh || rc=$?
        if [[ $live == true ]]; then
            [[ $rc == 1 ]] || fail "$daemon live process was accepted by post-hook"
            docker exec "$cid" test ! -e /kubedoop/run/events || fail 'rejected post-hook recorded success'
        else
            [[ $rc == 0 ]] || fail "$daemon zombie was rejected by post-hook"
            [[ $(docker exec "$cid" cat /kubedoop/run/events) == POST ]] || fail 'zombie post-hook marker'
        fi
        docker rm -fv "$cid" >/dev/null
    done
done
echo 'ok - post-hook rejects live daemons but accepts terminated zombies'
ready() {
    local cid=$1
    for ((i=0;i<90;i++)); do
        if printf '%s\n' test-admin-password | docker exec -i "$cid" kinit admin/admin@LIFECYCLE.TEST >/dev/null 2>&1; then
            docker exec "$cid" klist -s && return 0
        fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" == true ]] || break
        sleep 1
    done
    docker logs "$cid" 2>&1 | tail -n 25 >&2
    return 1
}
for mode in foreground systemd; do
    options=()
    command=()
    if [[ $mode == foreground ]]; then command=(--foreground); else options=(--privileged --cgroupns=private); fi
    cid=$(docker run -d --hostname kdc.lifecycle.test "${options[@]}" "$fixture" "${command[@]}" \
        --password test-master-password --kadmin-password test-admin-password --realm LIFECYCLE.TEST --domain lifecycle.test)
    containers+=("$cid")
    ready "$cid" || fail "$mode KDC readiness"
    comm=$(docker exec "$cid" cat /proc/1/comm)
    if [[ $mode == systemd ]]; then
        [[ $comm == systemd ]] || fail 'default systemd PID1 changed'
        docker exec "$cid" systemctl is-active krb5kdc kadmin kubedoop-lifecycle.service
    else
        [[ $comm == tini ]] || fail 'foreground Tini missing'
    fi
    docker exec "$cid" bash -c 'test "$(stat -c %a /tmp/krb5kdc_admin_password)" = 600'
    startup_logs=$(docker logs "$cid" 2>&1)
    [[ $startup_logs != *test-master-password* && $startup_logs != *test-admin-password* ]] || fail "$mode password logging"
    # Authenticated administrative RPC, not just local database access.
    docker exec "$cid" kadmin -p admin/admin@LIFECYCLE.TEST -w test-admin-password \
        -q 'addprinc -pw persistent-user-password persistent@LIFECYCLE.TEST'
    docker exec "$cid" kadmin.local -q 'getprinc persistent@LIFECYCLE.TEST' | grep -q 'Principal: persistent@LIFECYCLE.TEST'
    # Repeat the full TERM/INT/native-stop sequence three times in the same CID.
    # A single sequence missed an intermittent native ARM post-hook failure.
    for ((cycle=1;cycle<=9;cycle++)); do
        printf '%s\n' persistent-user-password | docker exec -i "$cid" kinit persistent@LIFECYCLE.TEST >/dev/null
        docker exec "$cid" klist -s
        stop_started=$SECONDS
        if [[ $((cycle % 3)) == 1 && $mode == foreground ]]; then
            docker kill --signal TERM "$cid" >/dev/null
        elif [[ $((cycle % 3)) == 2 && $mode == foreground ]]; then
            docker kill --signal INT "$cid" >/dev/null
        else
            docker stop -t 45 "$cid" >/dev/null
        fi
        status=$(docker wait "$cid")
        [[ $status != 137 ]] || fail "$mode forced KILL"
        events=$(docker cp "$cid:/kubedoop/run/events" - | tar -xO | tr '\n' ',')
        expected=""
        for ((j=0;j<cycle;j++)); do expected+=PRE,POST,; done
        [[ $events == "$expected" ]] || fail "$mode cycle=$cycle status=$status stop_seconds=$((SECONDS - stop_started)) hook order/count $events"
        if [[ $cycle -lt 9 ]]; then
            docker start "$cid" >/dev/null
            ready "$cid" || fail "$mode restart"
        fi
    done
    if [[ $mode == foreground ]]; then
        docker start "$cid" >/dev/null
        ready "$cid" || fail 'foreground failure-case restart'
        docker exec "$cid" pkill -TERM -x krb5kdc
        [[ "$(docker wait "$cid")" == 1 ]] || fail 'unexpected clean daemon exit must fail container'
        events=$(docker cp "$cid:/kubedoop/run/events" - | tar -xO | tr '\n' ',')
        expected+=PRE,POST,
        [[ $events == "$expected" ]] || fail 'daemon failure did not drain peer before post'
    fi
    echo "ok - $mode real KDC tickets/admin RPC, same-CID principal persistence, nine orderly stops and hooks"
done
