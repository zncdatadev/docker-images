# Testing-tools lifecycle

Keep the original Python3.12/Debian base, kubedoop UID1000 (not1001), Python3 CMD,
working directory and dependencies. No service starts unless explicitly requested.
Root-owned helpers use a private `/usr/local/libexec/kubedoop-testing-tools` path;
HOME remains writable while helpers and hook mount directories are protected.

Run source tests as normal user and root, build the full original Dockerfile,
then run the generic image suite and the native Python suite:

```bash
bash testing-tools/tests/source-entrypoint-framework.sh
bash testing-tools/tests/image-entrypoint-framework.sh IMAGE
bash testing-tools/tests/image-python-lifecycle.sh IMAGE
```

Generic coverage includes actual default Python stdin, source hashes, status127,
projected hooks, orphan reaping and bounded/repeated-signal cleanup. The private
Python fixture uses the real requests stack against a loopback-only HTTP server,
flushes state on shutdown, checks post hooks after exit, status42 and same-container
restart under UID1000 and root. No public ports, cluster or production credentials
are involved. CI runs all suites on native amd64 and arm64.

Bullseye packages come from official signed archive repositories. Keycloak26
CLI class files require Java17, so protected PATH adapters use the additional
official Java17 JRE by default while keeping general `java` on Java11. Explicit
JAVA/JAVA_HOME values are honored. Direct vendor script paths still require
selecting Java17 explicitly. Native checks include kcadm/kcreg help, kubectl,
Python imports (the kafka-python3 module is kafka3) and pip dependency consistency.

The pinned kafka-python3==3.0.0 vendors six1.11, whose importer lacks find_spec
on Python3.12. A guarded build-time backport of upstream six's importer hook
preserves the client version; real Kafka imports, nested moves imports and
integer codec round-trip tests prevent an import-only false positive.
