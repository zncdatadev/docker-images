#!/bin/bash
# Keep systemd as PID 1 in the default mode. Tini is only used by opt-in modes.
set -euo pipefail
readonly FRAMEWORK=/usr/local/libexec/kubedoop-krb5
case "${1:-}" in
    --exec)
        shift
        exec /usr/bin/tini -- "$FRAMEWORK/bin/command.sh" "$@"
        ;;
    --foreground)
        shift
        exec /usr/bin/tini -- "$FRAMEWORK/bin/command.sh" "$FRAMEWORK/bin/foreground.sh" "$@"
        ;;
    -h|--help)
        "$FRAMEWORK/bin/setup.sh" --help
        printf '\nModes: default systemd; --foreground [setup options]; --exec COMMAND [ARG...]\n'
        exit 0
        ;;
esac
readonly KUBEDOOP_MOUNT_DIR=/kubedoop/mount
readonly KUBEDOOP_RUN_DIR=/kubedoop/run
mkdir -p "$KUBEDOOP_RUN_DIR"
source "$FRAMEWORK/lib/log.sh"
source "$FRAMEWORK/lib/run.sh"
# Fail before any KDC initialization or systemd service startup.
run_pre_scripts
"$FRAMEWORK/bin/setup.sh" "$@"
exec /usr/sbin/init
