#!/bin/bash
# Exercise the wrapper independently of Maven, a database or the final image.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER="${SCRIPT_DIR}/../kubedoop/bin/start-metastore"
TMP_DIR=$(mktemp -d)
PID=""
cleanup() { [[ -z "$PID" ]] || kill -KILL "$PID" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mkdir -p "$TMP_DIR/bin with spaces" "$TMP_DIR/conf with spaces"
export TEST_TRACE="$TMP_DIR/trace" TEST_READY="$TMP_DIR/ready" TEST_PID="$TMP_DIR/pid"
cat > "$TMP_DIR/bin with spaces/base" <<'EOF'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$@" >> "$TEST_TRACE"
case " $* " in
  *" schemaTool "*)
    if [[ "${TEST_SCHEMA_WAIT:-false}" == true ]]; then
      echo "$$" > "$TEST_PID"
      if [[ "${TEST_IGNORE_TERM:-false}" == true ]]; then
        trap '' TERM
      elif [[ "${TEST_WAIT_TIMER:-false}" == true ]]; then
        trap 'while [[ ! -e "$TEST_TIMER_READY" ]]; do command sleep 0.01; done; exit 143' TERM
      else
        trap 'exit 143' TERM
      fi
      touch "$TEST_READY"
      while :; do read -r -t 0.1 _ </dev/zero || true; done
    fi
    if [[ " $* " == *" -validate "* ]]; then exit "${TEST_VALIDATE_STATUS:-0}"; fi
    exit "${TEST_INIT_STATUS:-0}"
    ;;
  *" metastore "*)
    echo "$$" > "$TEST_PID"
    if [[ "${TEST_MAIN_WAIT:-false}" == true ]]; then
      trap 'exit 42' TERM
      touch "$TEST_READY"
      while :; do read -r -t 0.1 _ </dev/zero || true; done
    fi
    exit "${TEST_MAIN_STATUS:-0}"
    ;;
esac
exit 99
EOF
chmod 0755 "$TMP_DIR/bin with spaces/base"
args=(--db-type derby --config "$TMP_DIR/conf with spaces" --hive-bin-dir "$TMP_DIR/bin with spaces")
expect_status() {
  local expected="$1" rc=0
  shift
  "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr" || rc=$?
  [[ "$rc" == "$expected" ]] || fail "expected status $expected, got $rc"
}
expect_status 0 "$WRAPPER" --help
expect_status 1 "$WRAPPER"
for option in --config --db-type --hive-bin-dir; do expect_status 1 "$WRAPPER" "$option"; done
expect_status 1 "$WRAPPER" "${args[@]}" --unknown
expect_status 1 "$WRAPPER" "${args[@]}" --db-type unexpected
expect_status 0 env TEST_VALIDATE_STATUS=0 "$WRAPPER" "${args[@]}" -- -p 19083 '--hiveconf' 'secret=test-not-for-logs'
! grep -qx -- -initSchema "$TEST_TRACE" || fail "existing schema was initialized again"
grep -qx 19083 "$TEST_TRACE" || fail "metastore arguments were lost"
! grep -q test-not-for-logs "$TMP_DIR/stdout" "$TMP_DIR/stderr" || fail "wrapper logged arguments"
: > "$TEST_TRACE"
expect_status 7 env TEST_VALIDATE_STATUS=1 TEST_MAIN_STATUS=7 "$WRAPPER" "${args[@]}"
[[ "$(grep -cx -- -initSchema "$TEST_TRACE")" == 1 ]] || fail "missing schema was not initialized once"
: > "$TEST_TRACE"
expect_status 1 env TEST_VALIDATE_STATUS=1 TEST_INIT_STATUS=23 "$WRAPPER" "${args[@]}"
! grep -qx metastore "$TEST_TRACE" || fail "metastore started after schema initialization failure"
wait_ready() {
  for ((i=0;i<100;i++)); do [[ ! -e "$TEST_READY" ]] || return 0; sleep 0.05; done
  fail "child did not become ready"
}
TEST_MAIN_WAIT=true "$WRAPPER" "${args[@]}" >/dev/null 2>&1 & PID=$!
wait_ready
[[ "$(cat "$TEST_PID")" == "$PID" ]] || fail "wrapper did not exec the native metastore"
kill -TERM "$PID"
rc=0; wait "$PID" || rc=$?; PID=""
[[ "$rc" == 42 ]] || fail "metastore termination exit code was lost"
for scenario in graceful:4:TERM ignored:4:TERM ignored:1:TERM graceful:4:INT; do
  IFS=: read -r behavior budget signal <<< "$scenario"
  ignore=false
  [[ "$behavior" != ignored ]] || ignore=true
  rm -f "$TEST_READY"
  : > "$TEST_TRACE"
  # Bash ignores INT for asynchronous jobs; restore its default before exec
  # so this direct helper test actually delivers INT (the framework uses TERM).
  env --default-signal=INT TEST_SCHEMA_WAIT=true TEST_IGNORE_TERM="$ignore" KUBEDOOP_KILL_TIMEOUT="$budget" "$WRAPPER" "${args[@]}" >/dev/null 2>&1 & PID=$!
  wait_ready
  child=$(cat "$TEST_PID")
  kill -"$signal" "$PID"
  rc=0; wait "$PID" || rc=$?; PID=""
  [[ "$rc" == 143 ]] || fail "schema-time shutdown lost cancellation"
  ! kill -0 "$child" 2>/dev/null || fail "schema JVM survived wrapper shutdown"
  ! grep -qx metastore "$TEST_TRACE" || fail "metastore started after cancellation"
done
(
  export TEST_TIMER_READY="$TMP_DIR/timer-ready"
  sleep() { trap '' TERM; touch "$TEST_TIMER_READY"; command sleep "$@"; }
  export -f sleep
  rm -f "$TEST_READY"
  TEST_SCHEMA_WAIT=true TEST_WAIT_TIMER=true KUBEDOOP_KILL_TIMEOUT=6 "$WRAPPER" "${args[@]}" >/dev/null 2>&1 & PID=$!
  for ((i=0;i<100;i++)); do [[ ! -e "$TEST_READY" ]] || break; command sleep 0.05; done
  [[ -e "$TEST_READY" ]] || fail 'timer cancellation child did not become ready'
  started=$SECONDS
  kill -TERM "$PID"
  rc=0; wait "$PID" || rc=$?; PID=""
  [[ "$rc" == 143 ]] || fail 'timer cancellation changed helper status'
  ((SECONDS - started < 2)) || fail 'TERM-resistant helper timer delayed cancellation'
) || fail 'helper timer cancellation regression'
echo "ok - wrapper validates arguments, initializes only as requested, execs metastore, stops schema children and cancels TERM-resistant timers"
