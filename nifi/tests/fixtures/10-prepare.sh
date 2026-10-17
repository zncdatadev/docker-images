#!/bin/bash
# Test-only, loopback HTTP configuration. Never included in the production image.
set -euo pipefail
properties="${NIFI_HOME}/conf/nifi.properties"
set_property() {
    local key="$1" value="$2" escaped
    escaped="${key//./\\.}"
    grep -q "^${escaped}=" "$properties"
    sed -i "s|^${escaped}=.*|${key}=${value}|" "$properties"
}
set_property nifi.web.http.host 127.0.0.1
set_property nifi.web.http.port 8080
set_property nifi.web.https.host ''
set_property nifi.web.https.port ''
set_property nifi.remote.input.secure false
set_property nifi.security.keystore ''
set_property nifi.security.keystoreType ''
set_property nifi.security.keystorePasswd ''
set_property nifi.security.keyPasswd ''
set_property nifi.security.truststore ''
set_property nifi.security.truststoreType ''
set_property nifi.security.truststorePasswd ''
set_property nifi.security.user.authorizer ''
set_property nifi.security.user.login.identity.provider ''
set_property nifi.sensitive.props.key universal-nifi-lifecycle-test-key
sed -i -e 's/^java.arg.2=.*/java.arg.2=-Xms512m/' \
    -e 's/^java.arg.3=.*/java.arg.3=-Xmx1g/' "${NIFI_HOME}/conf/bootstrap.conf"
test -w "${NIFI_HOME}/conf"
echo TEST_NIFI_PRE_READY
echo PRE >> /kubedoop/run/nifi-events
