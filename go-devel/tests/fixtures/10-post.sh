#!/bin/bash
set -euo pipefail
if pgrep -x workload >/dev/null; then exit 1; fi
test -s /kubedoop/run/go-state
echo TEST_GO_POST
