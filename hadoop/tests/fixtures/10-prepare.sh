#!/bin/bash
set -euo pipefail
mkdir -p "$HADOOP_CONF_DIR" "$HADOOP_PID_DIR" "$HADOOP_LOG_DIR" /kubedoop/run/tmp
cp -R "$HADOOP_HOME/etc/hadoop/." "$HADOOP_CONF_DIR/"
cp /kubedoop/run/test-config/*.xml "$HADOOP_CONF_DIR/"
[[ "${TEST_ROLE:?test role required}" != namenode ]] || mkdir -p /kubedoop/run/name
if [[ "${TEST_ROLE:?test role required}" == namenode && "${TEST_FORMAT:-false}" == true && ! -f /kubedoop/run/name/current/VERSION ]]; then
    hdfs namenode -format -nonInteractive
    echo TEST_HADOOP_FORMAT_ONCE
fi
echo TEST_HADOOP_PRE_READY
