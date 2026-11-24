#!/bin/bash
set -euo pipefail
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aq 'org.apache.hadoop.hbase.master.HMaster' "$cmdline"; then
        echo 'HBase service JVM is still running' >&2; exit 1
    fi
done
echo TEST_HBASE_POST_DONE
