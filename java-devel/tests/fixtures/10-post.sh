#!/bin/bash
set -euo pipefail
pid=$(cat /kubedoop/run/java-pid)
[[ "$pid" =~ ^[0-9]+$ ]]
test ! -e "/proc/$pid"
test -s /kubedoop/run/java-state
echo TEST_JAVA_POST
