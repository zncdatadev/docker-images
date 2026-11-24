#!/bin/bash
set -euo pipefail
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aqE 'org.apache.hadoop.hdfs.server.(namenode.NameNode|datanode.DataNode)' "$cmdline"; then
        echo 'Hadoop service JVM is still running' >&2; exit 1
    fi
done
if [[ "${TEST_ROLE:-}" == namenode && "${TEST_FORMAT:-false}" != true ]]; then
    test ! -e /kubedoop/run/name/current/VERSION
    echo TEST_HADOOP_FORMAT_POLICY_PRESERVED
fi
echo TEST_HADOOP_POST_DONE
