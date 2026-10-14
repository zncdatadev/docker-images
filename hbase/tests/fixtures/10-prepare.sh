#!/bin/bash
set -euo pipefail
mkdir -p "$HBASE_CONF_DIR" "$HBASE_LOG_DIR" "$HBASE_PID_DIR" /kubedoop/run/tmp /kubedoop/run/zookeeper
cp -R "$HBASE_HOME/conf/." "$HBASE_CONF_DIR/"
cp /kubedoop/run/test-config/hbase-site.xml "$HBASE_CONF_DIR/"
echo TEST_HBASE_PRE_READY
