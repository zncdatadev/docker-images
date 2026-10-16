#!/bin/bash
set -euo pipefail
cat >/dev/null
[[ "${TEST_FAIL_PRE:-false}" != true ]] || exit 23
printf 'PRE\n' >> /kubedoop/run/events
