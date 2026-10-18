#!/bin/bash
# Test helper cancellation through the real image's Tini/universal lifecycle.
set -euo pipefail
IMAGE="${1:?Usage: image-schema-cancellation.sh IMAGE}"
CID=""
cleanup() { [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { docker logs "$CID" >&2 || true; echo "not ok - $*" >&2; exit 1; }
for budget in 1 4; do
    for signal in TERM INT; do
        CID=$(docker run -d -e KUBEDOOP_KILL_TIMEOUT="$budget" "$IMAGE" bash -c '
            mkdir -p /kubedoop/run/schema-test/bin /kubedoop/run/schema-test/conf
            printf "%s\n" "#!/bin/bash" "trap '\'' '\'' TERM" \
                "echo TEST_SCHEMA_READY" "while :; do read -r -t 0.1 _ </dev/zero || true; done" \
                > /kubedoop/run/schema-test/bin/base
            chmod 0755 /kubedoop/run/schema-test/bin/base
            exec start-metastore --db-type derby --config /kubedoop/run/schema-test/conf \
                --hive-bin-dir /kubedoop/run/schema-test/bin
        ')
        ready=false
        for ((i=0;i<30;i++)); do
            if docker logs "$CID" 2>&1 | grep -F TEST_SCHEMA_READY >/dev/null; then ready=true; break; fi
            sleep 0.1
        done
        [[ "$ready" == true ]] || fail "schema child did not start"
        docker kill --signal "$signal" "$CID" >/dev/null
        rc=$(timeout 10 docker wait "$CID") || fail "schema cancellation did not finish"
        [[ "$rc" == 143 ]] || fail "helper cancellation status changed to $rc"
        logs=$(docker logs "$CID" 2>&1)
        ! grep -Fq 'Main process did not exit' <<< "$logs" || fail "outer lifecycle killed helper before owned-child cleanup"
        [[ "$(grep -c 'Shutdown complete' <<< "$logs")" == 1 ]] || fail "cleanup was not completed once"
        docker rm "$CID" >/dev/null
        CID=""
        echo "ok - image helper cancels TERM-ignoring schema child on $signal with ${budget}s budget"
    done
done
