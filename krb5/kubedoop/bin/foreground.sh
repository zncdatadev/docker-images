#!/bin/bash
# Both daemons remain in the owned session established by command.sh.
# Returning on either daemon's exit lets command.sh drain the other before hooks.
set -euo pipefail
/usr/local/libexec/kubedoop-krb5/bin/setup.sh "$@"
/usr/sbin/krb5kdc -n &
/usr/sbin/kadmind -nofork &
set +e
wait -n
status=$?
# An unexpected clean daemon exit is still a service failure.
((status != 0)) || status=1
exit "$status"
