#!/bin/bash
set -euo pipefail
if pgrep -f '^python3 -u /kubedoop/run/worker.py$' >/dev/null; then exit 1; fi
python3 -c 'import json; assert json.load(open("/kubedoop/run/state.json"))["flushed"] is True'
echo TEST_PYTHON_POST
