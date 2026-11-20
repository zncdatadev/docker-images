#!/bin/bash
set -euo pipefail
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aq 'org.apache.nifi.NiFi' "$cmdline"; then
        echo 'NiFi JVM is still running' >&2
        exit 1
    fi
done
test -s "${NIFI_HOME}/conf/flow.json.gz"
echo TEST_NIFI_POST_DONE
echo POST >> /kubedoop/run/nifi-events
