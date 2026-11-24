#!/bin/bash
set -euo pipefail
if pgrep -f '(^gunicorn:|^/kubedoop/app/bin/python[^ ]* /kubedoop/app/bin/gunicorn)' >/dev/null; then
    echo 'Gunicorn master/worker still alive before post-hook' >&2
    exit 1
fi
if [[ -e /kubedoop/run/hold-started && ! -e /kubedoop/run/hold-done ]]; then
    echo 'in-flight request interrupted before post-hook' >&2
    exit 1
fi
echo TEST_SUPERSET_POST
