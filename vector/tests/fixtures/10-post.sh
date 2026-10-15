#!/bin/bash
set -euo pipefail
if pgrep -x vector >/dev/null; then echo 'Vector remains alive before post-hook' >&2; exit 1; fi
echo TEST_VECTOR_POST
