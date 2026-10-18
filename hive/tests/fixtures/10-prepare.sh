#!/bin/bash
set -euo pipefail
mkdir -p "$METASTORE_CONF_DIR" /kubedoop/run/warehouse
cp /kubedoop/run/metastore-site.xml "$METASTORE_CONF_DIR/metastore-site.xml"
cp "${HIVE_HOME}/conf/metastore-log4j2.properties" "$METASTORE_CONF_DIR/"
if [[ "${TEST_NATIVE_CMD:-false}" == true ]]; then
    if ! base --config "$METASTORE_CONF_DIR" --service schemaTool -dbType derby -validate; then
        base --config "$METASTORE_CONF_DIR" --service schemaTool -dbType derby -initSchema
        echo TEST_HIVE_SCHEMA_INIT
    fi
fi
echo TEST_HIVE_PRE_READY
echo PRE >> /kubedoop/run/hive-events
