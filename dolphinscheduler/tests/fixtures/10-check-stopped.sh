#!/bin/bash
set -euo pipefail
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aq org.apache.dolphinscheduler.StandaloneServer "$cmdline"; then
        echo 'standalone JVM is still running' >&2; exit 1
    fi
done
test -f /kubedoop/run/lifecycle-db.mv.db
touch /kubedoop/run/initialized
echo TEST_DOLPHIN_POST_DONE
echo POST >> /kubedoop/run/dolphin-events
