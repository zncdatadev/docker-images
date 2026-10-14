# Hadoop universal process management

The image retains both Hadoop versions, Java 11, UID 1001, versioned patches,
native libraries/FUSE, JMX exporter, async-profiler and oauth2-proxy. ENTRYPOINT is
`tini -- /kubedoop/bin/entrypoint.sh`; CMD is `hdfs namenode`, the native foreground
NameNode. Supply HDFS configuration and explicitly prepare its storage according
to deployment policy. Default startup never formats NameNode storage.

This repository's existing build explicitly excludes YARN and MapReduce
distribution modules. Its command surface is hadoop/hdfs/fuse_dfs, not a full
YARN/MapReduce server distribution. This feature preserves that packaging scope.

Native Hadoop scripts are unchanged. Their foreground paths already exec Java.
Use normal foreground CLI arguments for other services:

```sh
docker run --rm IMAGE hdfs datanode
docker run --rm IMAGE hdfs journalnode
docker run --rm IMAGE hdfs zkfc
docker run --rm IMAGE hadoop version
```

Do not use `--daemon start` as the main container command: it backgrounds the
actual service. Native daemon administration remains available and unchanged.
Kubernetes `command` overrides ENTRYPOINT and bypasses the universal hooks;
existing operators that supply their own shell/trap commands keep that behavior.
Use `args` or explicitly invoke the universal entrypoint to activate this lifecycle.
This image feature does not modify operator bootstrap/formatting policy.

Executable root-owned `.sh` hooks mounted in pre-script/post-script under
`/kubedoop/mount` run in filename order. Projected links are followed, with target
ownership/executability checked. Discovery/pre-hook failure aborts startup;
post-hook failures are best-effort without replacing application status. Hook
stdin is /dev/null while the main process retains stdin. Framework diagnostics
use stderr and omit argv, including debug mode. Native Hadoop's own explicit
`--debug` logging is independent and can include native options; do not enable it
with sensitive options in production.

TERM/INT initiate TERM-based graceful JVM shutdown, bounded by positive integer
`KUBEDOOP_KILL_TIMEOUT` (default 30 seconds) before KILL. Repeated signals do not
interrupt or duplicate cleanup. Tini reaps orphans. Root-owned sticky HOME permits
user cache writes while protecting the root-owned framework directories.

## Regression suites

```sh
bash hadoop/tests/source-entrypoint-framework.sh
bash hadoop/tests/image-entrypoint-framework.sh IMAGE
bash hadoop/tests/image-native-launchers.sh IMAGE
bash hadoop/tests/image-hadoop-lifecycle.sh IMAGE
```

The host needs Docker. CI runs all four suites after each native
amd64/arm64 version build. Source hashes ensure runtime scripts match the current
entrypoint/libraries. Generic tests cover UID/metadata, protected paths/writable
HOME, projected hooks, stdin/clean stdout, 7/127/42 status, signal forwarding,
repeated cleanup signals, escalation, orphan reaping and confidential argv.

Four-role tests execute actual shipped HDFS launchers with an
instrumented JVM to verify class selection, option/argument retention, exec PID
identity and normal/signal status. These are wiring tests, not HA/secure-mode
or job-execution acceptance.

The real service suite first checks that unformatted production default CMD fails
safely. Disposable fixture hooks then prepare a private NameNode only once and
launch native NameNode/DataNode on an owned Docker network. The test streams
data into HDFS, reads it, restarts the same containers, verifies stored bytes and
cluster identity, checks no reformat and tests TERM/INT with exactly-once hooks
and no surviving service JVM.

All fixture configuration/storage lives inside disposable test containers; no
ports are published and no host data is mounted. Test formatting is never copied
into production. The suite validates storage continuity, not YARN/MapReduce jobs,
HA failover or Kerberos deployment.
