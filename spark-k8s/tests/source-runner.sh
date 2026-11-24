#!/bin/bash
# Fast adapter contract tests without downloading or replacing Spark binaries.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/../kubedoop/bin/run-spark"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mkdir -p "$TEST_DIR/spark/bin" "$TEST_DIR/java/bin"
cat > "$TEST_DIR/capture" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$CAPTURE_PID"
printf '%s\n' "$@" > "$CAPTURE_ARGS"
exit 7
EOF
chmod 0755 "$TEST_DIR/capture"
ln -s "$TEST_DIR/capture" "$TEST_DIR/spark/bin/spark-class"
ln -s "$TEST_DIR/capture" "$TEST_DIR/spark/bin/spark-submit"
ln -s "$TEST_DIR/capture" "$TEST_DIR/java/bin/java"
export SPARK_HOME="$TEST_DIR/spark" JAVA_HOME="$TEST_DIR/java"
export CAPTURE_PID="$TEST_DIR/pid" CAPTURE_ARGS="$TEST_DIR/args"
export SPARK_DRIVER_BIND_ADDRESS=127.0.0.1
export SPARK_EXECUTOR_MEMORY=256m SPARK_DRIVER_URL=spark://driver:7078
export SPARK_EXECUTOR_ID=7 SPARK_EXECUTOR_CORES=2 SPARK_APPLICATION_ID=test-app
export SPARK_EXECUTOR_POD_IP=127.0.0.2 SPARK_RESOURCE_PROFILE_ID=0 SPARK_EXECUTOR_POD_NAME=test-pod
export SPARK_JAVA_OPT_10=-Dorder=10 SPARK_JAVA_OPT_2=-Dorder=2
export SPARK_JAVA_OPT_1='-Dcredential=not for logs'
export SPARK_CONF_DIR=/test/conf HADOOP_CONF_DIR=/test/hadoop
export SPARK_DIST_CLASSPATH=/test/dist SPARK_EXTRA_CLASSPATH=/test/extra
run_capture() {
    local rc=0 pid
    bash "$RUNNER" "$@" > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr" &
    pid=$!
    wait "$pid" || rc=$?
    [[ "$rc" == 7 ]] || fail 'application status lost'
    [[ "$(< "$CAPTURE_PID")" == "$pid" ]] || fail 'runner failed to exec foreground command'
    [[ ! -s "$TEST_DIR/stdout" && ! -s "$TEST_DIR/stderr" ]] || fail 'adapter printed command arguments'
}
for spec in master:org.apache.spark.deploy.master.Master worker:org.apache.spark.deploy.worker.Worker history:org.apache.spark.deploy.history.HistoryServer; do
    IFS=: read -r role class <<< "$spec"
    run_capture "$role" 'argument with spaces'
    mapfile -t args < "$CAPTURE_ARGS"
    [[ "${args[*]}" == "$class argument with spaces" && "${#args[@]}" == 2 ]] || fail 'daemon role argv changed'
done
run_capture driver --master 'local[2]' 'local:///argument with spaces.py'
mapfile -t args < "$CAPTURE_ARGS"
[[ "${args[0]}" == --conf && "${args[1]}" == spark.driver.bindAddress=127.0.0.1 ]] || fail 'driver bind address'
[[ "${args[3]}" == spark.executorEnv.SPARK_DRIVER_POD_IP=127.0.0.1 && "${args[5]}" == client ]] || fail 'driver native configuration'
[[ "${args[8]}" == 'local:///argument with spaces.py' && "${#args[@]}" == 9 ]] || fail 'driver argv changed'
run_capture executor 'argument with spaces'
mapfile -t args < "$CAPTURE_ARGS"
[[ "${args[0]}" == '-Dcredential=not for logs' && "${args[1]}" == -Dorder=2 && "${args[2]}" == -Dorder=10 ]] || fail 'executor numeric ordering or argument boundaries'
[[ "${args[6]}" == /test/conf:/test/hadoop:* && "${args[6]}" == *:/test/extra:* && "${args[6]}" == *:/test/dist ]] || fail 'executor classpath'
[[ "${args[7]}" == org.apache.spark.scheduler.cluster.k8s.KubernetesExecutorBackend ]] || fail 'executor class'
[[ "${args[${#args[@]}-1]}" == 'argument with spaces' ]] || fail 'executor extra argv'
(
    unset JAVA_HOME SPARK_CONF_DIR HADOOP_CONF_DIR
    export PATH="$TEST_DIR/java/bin:$PATH"
    run_capture executor
    mapfile -t args < "$CAPTURE_ARGS"
    [[ "${args[6]}" == "$SPARK_HOME/conf:"* ]] || fail 'default Spark config classpath lost'
)
(
    mkdir -p "$TEST_DIR/hadoop/bin"
    cat > "$TEST_DIR/hadoop/bin/hadoop" <<'EOF'
#!/bin/bash
[[ "$1" == classpath ]] || exit 1
printf '%s\n' /test/discovered-hadoop
EOF
    chmod 0755 "$TEST_DIR/hadoop/bin/hadoop"
    export HADOOP_HOME="$TEST_DIR/hadoop"
    unset SPARK_DIST_CLASSPATH
    run_capture executor
    mapfile -t args < "$CAPTURE_ARGS"
    [[ "${args[6]}" == *:/test/discovered-hadoop ]] || fail 'native Hadoop classpath discovery lost'
)
run_capture "$TEST_DIR/capture" 'arbitrary argument with spaces'
[[ "$(< "$CAPTURE_ARGS")" == 'arbitrary argument with spaces' ]] || fail 'pass-through command changed'
echo 'ok - five adapter roles and pass-through preserve exec PID, status, argument boundaries and silent diagnostics'
