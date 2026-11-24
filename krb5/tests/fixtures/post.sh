#!/bin/bash
set -euo pipefail
# In both modes post must follow termination of the real KDC and admin daemon.
# Zombies have terminated; Tini/systemd may still be about to reap them. pgrep
# also matches zombies and incorrectly rejected this valid shutdown window.
# Materialize ps output so discovery errors cannot silently pass the assertion.
processes=$(ps -eo stat=,comm=)
while read -r state command; do
    if [[ ( $command == krb5kdc || $command == kadmind ) && $state != Z* && $state != X* ]]; then
        ps -eo pid,ppid,pgid,stat,comm >&2
        exit 1
    fi
done <<< "$processes"
printf 'POST\n' >> /kubedoop/run/events
[[ "${TEST_FAIL_POST:-false}" != true ]] || exit 23
