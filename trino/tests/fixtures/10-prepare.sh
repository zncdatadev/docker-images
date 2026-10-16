#!/bin/bash
# Disposable test directories, never production configuration generation.
set -euo pipefail
mkdir -p /kubedoop/run/data /kubedoop/run/tmp
echo TEST_TRINO_PRE_READY
printf 'PRE\n' >> /kubedoop/run/trino-events
