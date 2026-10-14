#!/bin/bash
set -euo pipefail
if [[ -f /kubedoop/run/python-driver-pid ]]; then
    python_pid=$(cat /kubedoop/run/python-driver-pid)
    if [[ -e "/proc/$python_pid/cmdline" ]] && grep -aq '/kubedoop/run/job.py' "/proc/$python_pid/cmdline"; then
        echo 'Spark Python driver still running' >&2; exit 1
    fi
fi
for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    if grep -aqE 'org.apache.spark.deploy.(history.HistoryServer|SparkSubmit)' "$cmdline"; then
        echo 'Spark history JVM still running' >&2; exit 1
    fi
done
echo TEST_SPARK_POST_DONE
