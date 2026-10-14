#!/bin/bash
# Native-entrypoint adapter contracts without an external database or broker.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/../kubedoop/bin/run-airflow"
TMP_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || wait "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/airflow" <<'EOF'
#!/bin/bash
if [[ "${TEST_CELERY:-false}" == true ]]; then
    case "$*" in
        'db check') exit 0 ;;
        'config get-value core executor') echo CeleryExecutor; exit 0 ;;
        'config get-value celery broker_url') echo "$TEST_BROKER"; exit 0 ;;
    esac
fi
printf '%s\0' "$@" > "$CAPTURE"
printf '%s\n' "$BASHPID" > "$PID_CAPTURE"
exit "${TEST_EXIT:-0}"
EOF
chmod +x "$TMP_DIR/bin/airflow"
cat >"$TMP_DIR/bin/id" <<'EOF'
#!/bin/bash
case "$1" in -u|-g) echo 1001 ;; *) exec /usr/bin/id "$@" ;; esac
EOF
chmod +x "$TMP_DIR/bin/id"
export PATH="$TMP_DIR/bin:$PATH" CAPTURE="$TMP_DIR/args" PID_CAPTURE="$TMP_DIR/pid"
export CONNECTION_CHECK_MAX_COUNT=0
for command in scheduler webserver api-server dag-processor triggerer celery sync-perm; do
    TEST_EXIT=7 bash "$RUNNER" airflow "$command" 'a b=secret' >"$TMP_DIR/out" 2>"$TMP_DIR/err" & pid=$!
    rc=0; wait "$pid" || rc=$?
    [[ "$rc" == 7 && "$(cat "$PID_CAPTURE")" == "$pid" ]]
    mapfile -d '' -t args < "$CAPTURE"
    [[ "${args[0]}" == "$command" && "${args[1]}" == 'a b=secret' ]]
    if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
    TEST_EXIT=7 bash "$RUNNER" "$command" 'a b=secret' >"$TMP_DIR/out" 2>"$TMP_DIR/err" & pid=$!
    rc=0; wait "$pid" || rc=$?
    [[ "$rc" == 7 && "$(cat "$PID_CAPTURE")" == "$pid" ]]
    mapfile -d '' -t args < "$CAPTURE"
    [[ "${args[0]}" == "$command" && "${args[1]}" == 'a b=secret' ]]
    if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
done
bash "$RUNNER" /bin/bash -c 'printf arbitrary' >"$TMP_DIR/out"
[[ "$(cat "$TMP_DIR/out")" == arbitrary ]]
printf 'stdin\n' | bash "$RUNNER" cat >"$TMP_DIR/out"
[[ "$(cat "$TMP_DIR/out")" == stdin ]]
CONNECTION_CHECK_MAX_COUNT=20 bash "$RUNNER" airflow --help >/dev/null 2>"$TMP_DIR/err"
mapfile -d '' -t args < "$CAPTURE"
[[ "${args[0]}" == --help && "${#args[@]}" == 1 ]]
TEST_EXIT=23 _AIRFLOW_DB_MIGRATE=true bash "$RUNNER" scheduler >"$TMP_DIR/out" 2>"$TMP_DIR/err" && exit 1 || rc=$?
[[ "$rc" == 23 ]]
mapfile -d '' -t args < "$CAPTURE"
[[ "${args[*]}" == 'db migrate' ]]
cat >"$TMP_DIR/bin/python" <<'EOF'
#!/bin/bash
exec python3 "$@"
EOF
chmod +x "$TMP_DIR/bin/python"
# A private loopback TCP fixture, not a real broker or Celery task acceptance.
python3 - "$TMP_DIR/port" <<'PY' &
import socket
import sys
from pathlib import Path

with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    server.settimeout(10)
    Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
    connection, _ = server.accept()
    connection.close()
PY
SERVER_PID=$!
deadline=$((SECONDS + 10))
while [[ ! -s "$TMP_DIR/port" ]] && ((SECONDS < deadline)); do sleep 0.05; done
[[ -s "$TMP_DIR/port" ]]
port=$(cat "$TMP_DIR/port")
TEST_CELERY=true TEST_BROKER="redis://private:secret@127.0.0.1:$port/0" CONNECTION_CHECK_MAX_COUNT=1 bash "$RUNNER" celery worker >"$TMP_DIR/out" 2>"$TMP_DIR/err"
wait "$SERVER_PID"; SERVER_PID=""
mapfile -d '' -t args < "$CAPTURE"
[[ "${args[*]}" == 'celery worker' ]]
if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
rc=0
TEST_CELERY=true TEST_BROKER="redis://private:secret@127.0.0.1:$port/0" CONNECTION_CHECK_MAX_COUNT=1 bash "$RUNNER" celery worker >"$TMP_DIR/out" 2>"$TMP_DIR/err" || rc=$?
[[ "$rc" == 1 ]]
if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
echo 'ok - native Celery broker checks use bounded Python TCP without netcat or credential logging'
echo 'ok - native roles exec PID/status/argv, help, arbitrary commands/stdin, and fail-fast explicit migration'
