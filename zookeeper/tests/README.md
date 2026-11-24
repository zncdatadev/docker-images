# ZooKeeper Entrypoint Tests

This directory contains lightweight tests for the zookeeper entrypoint framework.

## Source behavior test

Run this before or after an image build when changing `zookeeper/kubedoop/lib/*.sh`:

```bash
zookeeper/tests/source-entrypoint-framework.sh
```

This sources the framework libraries directly from the working tree. It validates
library behavior only; it does not prove the final image wiring.

## Image behavior test

Run this after `make zookeeper-build`:

```bash
zookeeper/tests/image-entrypoint-framework.sh
```

Or pass an explicit image:

```bash
zookeeper/tests/image-entrypoint-framework.sh quay.io/zncdatadev/zookeeper:3.9.3-kubedoop0.0.0-dev
```

This runs containers from the built image and validates the final image wiring:
entrypoint files, runtime user, exit-code propagation, root-owned runtime hooks,
and signal forwarding through tini and `/kubedoop/bin/entrypoint.sh`.

Regression coverage includes ConfigMap-style `..data` symlinks, checking the
target's ownership and execute permission, stdin-consuming hooks followed by
another hook, status 127 on normal and signal-driven exits, and omission of
command arguments from logs in both normal and debug mode. Hooks receive
`/dev/null` as stdin; they must use explicit files or environment variables for
input.

The suite also checks that the main command retains stdin, that repeated
SIGTERM/SIGINT signals cannot interrupt application shutdown or post-scripts,
and that post-scripts run exactly once while preserving the application's exit
status. The default-CMD smoke test starts ZooKeeper without overriding its
command, reads the root znode with `zkCli.sh`, and checks graceful shutdown.

Follow-up gates also require clean command stdout/stdin as kubedoop and root,
root-owned sticky HOME with writable user caches and non-replaceable framework
directories, exact installed source hashes, owned-group descendant draining
after normal exit, and deterministic TERM-resistant timer cancellation while
preserving genuine application status142. Framework diagnostics use stderr;
operator hook output remains under the hook author's control.

After the full original source build, also run:

```bash
sudo bash zookeeper/tests/source-entrypoint-framework.sh
bash zookeeper/tests/image-zookeeper.sh IMAGE
```

The real application suite uses only a fixture derived from that source-built
image, with the original default CMD and UID preserved. A real client creates
and reads a persistent znode over three same-container starts/stops as each of
kubedoop and root. It tests TERM/INT/Docker stop, JVM143, no forced JVM KILL,
and exactly-once PRE/POST after the JVM has stopped. No host ports are exposed;
cleanup removes only test-owned containers, volumes and unique fixture tags.
