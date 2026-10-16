#!/bin/bash
# Sourced by the real image suite and a mocked source regression.
# The caller provides CID, query(), and fail().
wait_for_server() {
    local attempt output
    for ((attempt=0; attempt<40; attempt++)); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || fail "Trino exited before readiness"
        # A constant query can finish on the coordinator before a worker has
        # registered. Probe real connector data to require a schedulable worker.
        if output=$(query 'SELECT count(*) FROM tpch.tiny.nation' 2>/dev/null) && [[ "$output" == 25 ]]; then
            return 0
        fi
        sleep 1
    done
    fail "Trino never became ready"
}
