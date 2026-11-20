#!/bin/bash
set -euo pipefail
# Post-scripts must run after the broker JVM has exited.
for path in /proc/[0-9]*/cmdline; do
    [[ -r "$path" ]] || continue
    if grep -q 'kafka\.Kafka' "$path" 2>/dev/null; then
        echo 'broker is still running during post-script' >&2
        exit 1
    fi
done
echo TEST_KAFKA_POST_DONE
printf 'POST\n' >> /kubedoop/run/kafka-events
