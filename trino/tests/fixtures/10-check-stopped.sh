#!/bin/bash
set -euo pipefail
for path in /proc/[0-9]*/cmdline; do
    [[ -r "$path" ]] || continue
    if grep -q 'io\.trino\.server\.TrinoServer' "$path" 2>/dev/null; then
        echo 'Trino JVM is still running during post-script' >&2
        exit 1
    fi
done
echo TEST_TRINO_POST_DONE
printf 'POST\n' >> /kubedoop/run/trino-events
