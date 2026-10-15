# Vector lifecycle and base-image compatibility

Run from the repository root:

```bash
bash vector/tests/source-entrypoint-framework.sh
bash vector/tests/image-entrypoint-framework.sh IMAGE
bash vector/tests/image-vector-lifecycle.sh IMAGE
```

Also run source framework tests as root and build a cheap real downstream image
(ZooKeeper uses java-base) against this exact Vector source graph. The original
root USER and /bin/bash CMD are retained: starting Vector requires an explicit
native Vector command/config, and no host logs are collected automatically.

Helpers live under /usr/local/libexec/kubedoop-vector, not the product-facing
/kubedoop/bin/entrypoint.sh or /kubedoop/lib paths. This prevents legacy child
images from overwriting the inherited supervisor. ENTRYPOINT passes commands
through unchanged; child images can replace ENTRYPOINT normally, without a
second supervisor. A private child-image regression installs a legacy product
entrypoint at that old path and verifies inheritance and exactly-once hooks.

Source/generic tests cover owned group signals, stdin/status, repeated cleanup
signals, bounded escalation, orphan reaping, hook failures/permissions, protected
helpers and runtime script hashes. Base metadata remains root, while UID1001
writability and protection plus the actual Vector pipeline are tested separately.

The real private pipeline reads a file, runs native VRL and writes JSON. It checks
same-container restart, file checkpoint continuation without duplicate records,
TERM/INT flush and post-hooks only after Vector exits. No public port, host mount,
external sink or production data is used. Native inotify-tools/gomplate smoke
checks prove auxiliary artifacts are present. Distributed sinks and full
downstream operator migration are outside these image-level regressions.
