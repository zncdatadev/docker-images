#!/bin/bash
# Native Spark command construction uses the actual JVM launcher; only final service JVM is instrumented.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="${1:?Usage: image-native-launchers.sh IMAGE}"
TEST_IMAGE="spark-role-test:$(date +%s)-$$"
CID=""
cleanup() {
    [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { [[ -z "$CID" ]] || docker logs --tail 80 "$CID" >&2; echo "not ok - $*" >&2; exit 1; }
docker run --rm "$IMAGE" >/dev/null 2>&1 || fail 'default spark-submit help CMD broken'
docker build -q --build-arg "IMAGE=$IMAGE" -f "$SCRIPT_DIR/fixtures/role-Dockerfile" -t "$TEST_IMAGE" "$SCRIPT_DIR/fixtures" >/dev/null
COMMON=(-e SPARK_DRIVER_BIND_ADDRESS=127.0.0.1
    -e SPARK_EXECUTOR_MEMORY=256m -e SPARK_DRIVER_URL=spark://driver:7078
    -e SPARK_EXECUTOR_ID=7 -e SPARK_EXECUTOR_CORES=2 -e SPARK_APPLICATION_ID=test-app
    -e SPARK_EXECUTOR_POD_IP=127.0.0.2 -e SPARK_RESOURCE_PROFILE_ID=0 -e SPARK_EXECUTOR_POD_NAME=test-pod
    -e SPARK_JAVA_OPT_10=-Dtest-order=10 -e SPARK_JAVA_OPT_2=-Dtest-order=2
    -e 'SPARK_JAVA_OPT_1=-Dtest-credential=not for logs'
    -e 'SPARK_DAEMON_JAVA_OPTS=-Dtest-credential=not-for-logs'
    -e SPARK_HISTORY_OPTS=-Dtest-role=history
    -e SPARK_EXTRA_CLASSPATH=/kubedoop/run/extra-jars
    -e SPARK_CONF_DIR=/kubedoop/run/conf -e HADOOP_CONF_DIR=/kubedoop/run/hadoop-conf
    -e SPARK_DIST_CLASSPATH=/kubedoop/run/dist)
for spec in \
    master:org.apache.spark.deploy.master.Master \
    worker:org.apache.spark.deploy.worker.Worker \
    history:org.apache.spark.deploy.history.HistoryServer \
    driver:org.apache.spark.deploy.SparkSubmit \
    executor:org.apache.spark.scheduler.cluster.k8s.KubernetesExecutorBackend; do
    IFS=: read -r role class <<< "$spec"
    case "$role" in
        worker) args=(worker spark://master:7077 'arg with spaces') ;;
        driver) args=(driver --master 'local[1]' 'local:///arg with spaces.py') ;;
        *) args=("$role" 'arg with spaces') ;;
    esac
    CID=$(docker run -d "${COMMON[@]}" "$TEST_IMAGE" "${args[@]}")
    ready=false
    for ((i=0;i<100;i++)); do
        logs=$(docker logs "$CID" 2>&1)
        if grep -Fq TEST_JVM_READY <<< "$logs"; then ready=true; break; fi
        sleep 0.1
    done
    [[ "$ready" == true ]] || fail "$role never reached service JVM"
    managed=$(awk '/Main process started/ {gsub(/[()]/, ""); print $NF}' <<< "$logs" | tail -1)
    [[ "$(docker exec "$CID" cat /kubedoop/run/mock-pid)" == "$managed" ]] || fail 'managed PID is not final JVM'
    jvm_args=$(docker exec "$CID" cat /kubedoop/run/mock-args)
    grep -Fxq "$class" <<< "$jvm_args" || fail "$role class selection broken"
    if [[ "$role" == master || "$role" == worker || "$role" == history ]]; then
        grep -Fxq -- '-Dtest-credential=not-for-logs' <<< "$jvm_args" || fail 'native daemon JVM options lost'
    fi
    if [[ "$role" == history ]]; then
        grep -Fxq -- '-Dtest-role=history' <<< "$jvm_args" || fail 'native HistoryServer options lost'
    fi
    if [[ "$role" == driver ]]; then
        grep -Fxq 'local:///arg with spaces.py' <<< "$jvm_args" || fail 'driver argv boundary lost'
        grep -Fxq spark.driver.bindAddress=127.0.0.1 <<< "$jvm_args" || fail 'driver bind address lost'
        grep -Fxq spark.executorEnv.SPARK_DRIVER_POD_IP=127.0.0.1 <<< "$jvm_args" || fail 'executor driver address lost'
        grep -Fxq client <<< "$jvm_args" || fail 'native driver deploy mode lost'
    else
        grep -Fxq 'arg with spaces' <<< "$jvm_args" || fail 'role argv boundary lost'
    fi
    if [[ "$role" == executor ]]; then
        positions=$(grep -n '^-Dtest-order=' <<< "$jvm_args" | cut -d: -f2- | tr '\n' ',')
        [[ "$positions" == '-Dtest-order=2,-Dtest-order=10,' ]] || fail 'executor options not numerically ordered'
        grep -Fxq -- '-Dtest-credential=not for logs' <<< "$jvm_args" || fail 'executor option boundary lost'
        grep -Fq '/kubedoop/run/conf:/kubedoop/run/hadoop-conf:' <<< "$jvm_args" || fail 'executor config classpath lost'
        grep -Fq '/kubedoop/run/extra-jars' <<< "$jvm_args" || fail 'executor extra classpath lost'
        grep -Fxq test-pod <<< "$jvm_args" || fail 'executor pod name lost'
        grep -Fxq 7 <<< "$jvm_args" || fail 'executor id lost'
    fi
    ! grep -Eq 'not.for.logs' <<< "$logs" || fail 'runner logged sensitive options'
    docker kill --signal INT "$CID" >/dev/null
    [[ "$(timeout 10 docker wait "$CID")" == 42 ]] || fail 'signal JVM status lost'
    docker rm "$CID" >/dev/null; CID=""
    rc=0
    docker run --rm "${COMMON[@]}" -e TEST_JVM_EXIT=42 "$TEST_IMAGE" "${args[@]}" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 42 ]] || fail 'normal JVM status lost'
    echo "ok - $role native class/options/argv, JVM exec PID and status"
done
for name in SPARK_EXECUTOR_MEMORY SPARK_DRIVER_URL SPARK_EXECUTOR_ID SPARK_EXECUTOR_CORES SPARK_APPLICATION_ID SPARK_EXECUTOR_POD_IP SPARK_RESOURCE_PROFILE_ID SPARK_EXECUTOR_POD_NAME; do
    rc=0
    output=$(docker run --rm "${COMMON[@]}" -e "$name=" "$IMAGE" executor 2>&1) || rc=$?
    [[ "$rc" == 1 ]] || fail "missing $name not rejected"
    grep -Fq "required variable missing: $name" <<< "$output" || fail 'missing executor variable not identified'
    ! grep -Eq 'not.for.logs' <<< "$output" || fail 'validation leaked sensitive options'
done
rc=0
output=$(docker run --rm -e SPARK_DRIVER_BIND_ADDRESS= "$IMAGE" driver 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail 'missing driver bind address not rejected'
grep -Fq 'required variable missing: SPARK_DRIVER_BIND_ADDRESS' <<< "$output" || fail 'driver validation not identified'
echo 'ok - every required driver/executor variable fails safely when missing'
