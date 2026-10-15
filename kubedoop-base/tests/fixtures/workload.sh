#!/bin/bash
set -euo pipefail
finish() {
    local count=0
    if [[ -f /kubedoop/run/base-state ]]; then
        read -r count < /kubedoop/run/base-state
    fi
    printf '%s\n' "$((count + 1))" > /kubedoop/run/base-state
    echo TEST_BASE_FLUSHED
    exit 42
}
trap finish TERM
echo TEST_BASE_READY
while :; do sleep 0.1; done
