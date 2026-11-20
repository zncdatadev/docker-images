#!/bin/bash
# An upstream-shaped fixture verifies the asserted native-script adaptation.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mkdir -p "$TASK_DIR/java path/bin"
cat > "$TASK_DIR/java path/bin/java" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ARGS"
printf '%s\n' "$$" > "$TEST_PID"
exit 42
EOF
chmod 0755 "$TASK_DIR/java path/bin/java"
export JAVA_HOME="$TASK_DIR/java path" TEST_ARGS="$TASK_DIR/args" TEST_PID="$TASK_DIR/pid"
for role in standalone-server api-server master-server worker-server alert-server; do
    mkdir -p "$TASK_DIR/distribution/$role/bin"
    cat > "$TASK_DIR/distribution/$role/bin/start.sh" <<'EOF'
#!/bin/bash
JAVA_OPTS='-Dtest-secret=not-for-logs'
echo "JAVA_HOME=${JAVA_HOME}"
echo "JAVA_OPTS=${JAVA_OPTS}"
$JAVA_HOME/bin/java $JAVA_OPTS \
  -cp 'native-config:native-libs/*' \
  org.apache.dolphinscheduler.TestServer
EOF
done
find "$TASK_DIR/distribution" -name start.sh -exec sha256sum {} + | sort > "$TASK_DIR/native-before"
bash "$SCRIPT_DIR/../kubedoop/prepare-launchers.sh" "$TASK_DIR/distribution"
find "$TASK_DIR/distribution" -name start.sh -exec sha256sum {} + | sort > "$TASK_DIR/native-after"
[[ "$(< "$TASK_DIR/native-before")" == "$(< "$TASK_DIR/native-after")" ]] || fail "legacy native launchers were modified"
for role in standalone-server api-server master-server worker-server alert-server; do
    "$TASK_DIR/distribution/$role/bin/start-foreground.sh" 'arg with spaces' > "$TASK_DIR/stdout" 2> "$TASK_DIR/stderr" &
    pid=$!
    rc=0; wait "$pid" || rc=$?
    [[ "$rc" == 42 ]] || fail "JVM status lost for $role"
    [[ "$(cat "$TEST_PID")" == "$pid" ]] || fail "launcher did not exec for $role"
    grep -Fxq -- '-Dtest-secret=not-for-logs' "$TEST_ARGS" || fail "native JVM options lost"
    grep -Fxq 'native-config:native-libs/*' "$TEST_ARGS" || fail "native classpath lost"
    grep -Fxq 'arg with spaces' "$TEST_ARGS" || fail "application argument boundary lost"
    ! grep -Fq not-for-logs "$TASK_DIR/stdout" "$TASK_DIR/stderr" || fail "launcher logged JVM options"
done
cp "$TASK_DIR/distribution/standalone-server/bin/start-foreground.sh" "$TASK_DIR/distribution/standalone-server/bin/start.sh"
if bash "$SCRIPT_DIR/../kubedoop/prepare-launchers.sh" "$TASK_DIR/distribution" >/dev/null 2>&1; then
    fail "unexpected upstream launcher shape was silently accepted"
fi
rc=0
"$SCRIPT_DIR/../kubedoop/bin/run-dolphinscheduler" invalid-role >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail "invalid role was accepted"
echo 'ok - native launcher adaptation retains options/classpath/argv, execs JVM, preserves status and rejects drift'
