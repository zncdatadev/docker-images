#!/bin/bash
set -euo pipefail
processes=$(ps -eo stat=,comm=)
while read -r state command; do
    if [[ $command == java && $state != Z* && $state != X* ]]; then exit 1; fi
done <<< "$processes"
printf 'POST\n' >> /kubedoop/run/zookeeper-events
