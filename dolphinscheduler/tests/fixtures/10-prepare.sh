#!/bin/bash
set -euo pipefail
mode=always
[[ ! -f /kubedoop/run/initialized ]] || mode=never
cat > /kubedoop/run/lifecycle.properties <<EOF
spring.datasource.url=jdbc:h2:file:/kubedoop/run/lifecycle-db;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=true
spring.sql.init.mode=$mode
server.address=127.0.0.1
api.python-gateway.enabled=false
EOF
echo TEST_DOLPHIN_PRE_READY
echo PRE >> /kubedoop/run/dolphin-events
