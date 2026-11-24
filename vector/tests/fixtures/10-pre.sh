#!/bin/bash
set -euo pipefail
mkdir -p /kubedoop/run/vector-state
if [[ ! -e /kubedoop/run/input.log ]]; then printf 'alpha\nbeta\n' > /kubedoop/run/input.log; fi
echo TEST_VECTOR_PRE
