#!/bin/bash
set -euo pipefail
for arg in "$@"; do
    if [[ "$arg" == org.apache.spark.launcher.Main ]]; then exec "$REAL_JAVA_HOME/bin/java" "$@"; fi
done
printf '%s\n' "$@" > /kubedoop/run/mock-args
printf '%s\n' "$$" > /kubedoop/run/mock-pid
[[ "${TEST_JVM_EXIT:-}" != 42 ]] || exit 42
trap 'echo TEST_JVM_TERM; exit 42' TERM
echo TEST_JVM_READY
while :; do read -r -t 0.1 _ </dev/zero || true; done
