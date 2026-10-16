#!/bin/bash
# Test-only initialization of a disposable, single-node KRaft broker.
set -euo pipefail
if [[ ! -f /kubedoop/run/data/meta.properties ]]; then
    cluster_id=$(kafka-storage.sh random-uuid)
    kafka-storage.sh format -t "$cluster_id" -c /kubedoop/run/server.properties
fi
echo TEST_KAFKA_PRE_READY
printf 'PRE\n' >> /kubedoop/run/kafka-events
