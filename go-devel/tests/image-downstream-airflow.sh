#!/bin/bash
# Original Airflow runtime owns its own ENTRYPOINT; test its compiled artifacts.
set -euo pipefail
IMAGE="${1:?Usage: image-downstream-airflow.sh IMAGE}"
docker run --rm --entrypoint /kubedoop/bin/git-sync "$IMAGE" --version
docker run --rm --entrypoint /kubedoop/app/bin/airflow "$IMAGE" version
echo 'ok - original-source downstream git-sync and Airflow native CLI'
