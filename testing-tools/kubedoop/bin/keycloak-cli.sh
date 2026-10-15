#!/bin/bash
# Keycloak26 CLI requires Java17; do not change the image's Java11 default.
set -euo pipefail
command_name=$(basename "$0")
case "$command_name" in
    kcadm.sh|kcreg.sh) ;;
    *) echo 'Invoke this adapter as kcadm.sh or kcreg.sh' >&2; exit 1 ;;
esac
if [[ -z "${JAVA:-}" && -z "${JAVA_HOME:-}" ]]; then
    JAVA="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/bin/java"
    export JAVA
fi
exec "/kubedoop/keycloak/bin/$command_name" "$@"
