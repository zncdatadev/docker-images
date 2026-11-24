#!/bin/bash
# Apply narrow, asserted runtime adaptations to the shipped native launchers.
set -euo pipefail
distribution="${1:?Usage: prepare-launchers.sh DISTRIBUTION}"
for role in standalone-server api-server master-server worker-server alert-server; do
    native="$distribution/$role/bin/start.sh"
    [[ -f "$native" ]] || { echo "missing native launcher for $role" >&2; exit 1; }
    script="$distribution/$role/bin/start-foreground.sh"
    cp "$native" "$script"
    [[ "$(grep -c '^\$JAVA_HOME/bin/java ' "$script")" == 1 ]] || {
        echo "unexpected Java invocation in $role" >&2; exit 1;
    }
    [[ "$(grep -c '^  org\.apache\.dolphinscheduler\.' "$script")" == 1 ]] || {
        echo "unexpected application class invocation in $role" >&2; exit 1;
    }
    # Preserve start.sh for legacy daemon PID/status/stop and operator callers.
    # Keep native env/JVM/classpath behavior. Only replace the terminal JVM
    # invocation, forward explicit application arguments and omit option logs.
    sed -i '1a set -eo pipefail' "$script"
    sed -i 's|^\$JAVA_HOME/bin/java |exec "$JAVA_HOME/bin/java" |; /^echo "JAVA_HOME=/d; /^echo "JAVA_OPTS=/d; /^  org\.apache\.dolphinscheduler\./s/$/ "$@"/' "$script"
    chmod 0755 "$script"
    bash -n "$script"
done
