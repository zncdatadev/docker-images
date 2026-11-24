#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/../kubedoop/bin/run-superset"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
for command in gunicorn celery; do
    cat >"$TMP_DIR/bin/$command" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "$CAPTURE"
printf '%s\n' "$BASHPID" > "$PID_CAPTURE"
exit 7
EOF
    chmod +x "$TMP_DIR/bin/$command"
done
export PATH="$TMP_DIR/bin:$PATH" CAPTURE="$TMP_DIR/args" PID_CAPTURE="$TMP_DIR/pid"
FLASK_APP='factory:app with secret' SERVER_WORKER_AMOUNT='2 --bad' bash "$RUNNER" webserver --name 'a b=secret' >"$TMP_DIR/out" 2>"$TMP_DIR/err" & pid=$!
rc=0; wait "$pid" || rc=$?
[[ "$rc" == 7 && "$(cat "$PID_CAPTURE")" == "$pid" ]]
mapfile -d '' -t args < "$CAPTURE"
[[ "${args[0]}" == --bind && "${args[1]}" == 0.0.0.0:8088 ]]
[[ "${args[3]}" == '2 --bad' && "${args[5]}" == gthread && "${args[7]}" == 20 ]]
[[ "${args[20]}" == 'factory:app with secret' && "${args[21]}" == --name && "${args[22]}" == 'a b=secret' ]]
if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
for role in worker beat; do
    bash "$RUNNER" "$role" --logfile 'a b=secret' >"$TMP_DIR/out" 2>"$TMP_DIR/err" & pid=$!
    rc=0; wait "$pid" || rc=$?
    [[ "$rc" == 7 && "$(cat "$PID_CAPTURE")" == "$pid" ]]
    mapfile -d '' -t args < "$CAPTURE"
    [[ "${args[0]}" == --app=superset.tasks.celery_app:app && "${args[1]}" == "$role" ]]
    [[ "${args[2]}" == --logfile && "${args[3]}" == 'a b=secret' ]]
    if grep -Fq secret "$TMP_DIR/out" "$TMP_DIR/err"; then exit 1; fi
done
bash "$RUNNER" bash -c 'exit 127' && exit 1 || rc=$?
[[ "$rc" == 127 ]]
output=$(printf 'stdin\n' | bash "$RUNNER" cat)
[[ "$output" == stdin ]]
echo 'ok - web/worker/beat native exec PID/status/argv and arbitrary commands/stdin without argument logging'
