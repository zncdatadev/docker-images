#!/bin/bash
set -euo pipefail
if pgrep -f '(^airflow scheduler|^/kubedoop/app/bin/python[^ ]* /kubedoop/app/bin/airflow scheduler)' >/dev/null; then
    echo 'scheduler process remains alive before post-hook' >&2
    exit 1
fi
echo TEST_AIRFLOW_POST
