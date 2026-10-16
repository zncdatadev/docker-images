#!/bin/bash
# Ordered after both KDC services stop by kubedoop-lifecycle.service.
set -uo pipefail
readonly KUBEDOOP_MOUNT_DIR=/kubedoop/mount
readonly KUBEDOOP_RUN_DIR=/kubedoop/run
mkdir -p "$KUBEDOOP_RUN_DIR"
source /usr/local/libexec/kubedoop-krb5/lib/log.sh
source /usr/local/libexec/kubedoop-krb5/lib/run.sh
run_post_scripts
