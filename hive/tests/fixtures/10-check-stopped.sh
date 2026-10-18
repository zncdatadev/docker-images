#!/bin/bash
set -euo pipefail
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aq 'org.apache.hadoop.hive.metastore.HiveMetaStore' "$cmdline"; then
        echo "Hive metastore JVM is still running" >&2
        exit 1
    fi
done
test -d /kubedoop/run/metastore-db
echo TEST_HIVE_POST_DONE
echo POST >> /kubedoop/run/hive-events
