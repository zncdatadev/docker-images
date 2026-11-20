# Hive universal process management

The image keeps the existing kubedoop UID 1001, Hadoop/JMX contents and all
three product versions (3.1.3, 4.0.0, 4.0.1). Its entrypoint is
`tini -- /kubedoop/bin/entrypoint.sh`; default CMD is
`base --service metastore`, the native foreground metastore launcher.

The framework does not select a production database or run schema initialization
for the default CMD. Supply your metastore configuration and prepare its schema
according to your deployment policy. The existing explicit schema helper remains:

```sh
docker run --rm IMAGE start-metastore \
  --db-type postgres --config /path/to/mounted/config \
  --hive-bin-dir /kubedoop/hive-metastore/bin
```

The helper retains validate-then-initialize behavior. A validation failure attempts
initialization, **not** a schema upgrade or migration. An initialization failure
prevents service startup. The helper now validates options, accepts service
arguments after `--`, does not log argv, and execs the native launcher so the
managed PID becomes the actual JVM. TERM/INT during schema preparation terminate
and reap the owned schema child; cancellation never starts the metastore. The
owned cancellation timer is forcibly cancelled and reaped even if it ignores TERM.

Hive 4.0.0's native schemaTool script references the wrong Java package.
Runtime assembly corrects only that version to the class actually packaged in
its server JAR, matching the upstream 4.0.1 launcher. A build smoke test invokes
typed help (no database initialization); real schema initialization/reuse in
the application suite guards the startup behavior.

Docker command arguments replace CMD and are managed verbatim; for example,
`docker run --rm IMAGE base --service schemaTool ...`. Kubernetes `command`
overrides ENTRYPOINT and bypasses this lifecycle. Configure `args` or invoke the
entrypoint explicitly if lifecycle hooks are required.

Root-owned executable `.sh` files mounted in `/kubedoop/mount/pre-script` run
in filename order before startup. Post-scripts in `post-script` run once after
the managed process stops. Projected ConfigMap links are followed; ownership
and executability are checked on the target. Pre-hook/discovery failure aborts
startup; post-hook failure is logged without replacing the application exit code.
Hooks receive /dev/null stdin, while the main process retains stdin. Framework
diagnostics go to stderr and omit argv, including debug logging.

TERM/INT use TERM-based graceful shutdown. `KUBEDOOP_KILL_TIMEOUT` (default 30,
positive integer seconds) bounds the wait before KILL escalation. Tini is PID 1
and reaps orphans. The root-owned sticky HOME permits UID 1001 cache writes
while preventing replacement of the root-owned framework directories.
Managed commands own a separate session/process group. Live descendants drain
before post-hooks even after normal main exit, using the same shutdown deadline.
The ALRM timer is cancelled and reaped before its handler is removed; real exit
statuses including 127, 142 and 165 remain valid application results.

## Regression suites

```sh
hive/tests/source-entrypoint-framework.sh
sudo bash hive/tests/source-entrypoint-framework.sh
hive/tests/source-start-metastore.sh
sudo bash hive/tests/source-start-metastore.sh
hive/tests/image-entrypoint-framework.sh IMAGE
bash hive/tests/image-schema-cancellation.sh IMAGE
hive/tests/image-hive-lifecycle.sh IMAGE
```

Run against each locally built version; CI runs all suites after each native
amd64/arm64 build. The image suite checks that runtime scripts match the current
source hashes, and covers metadata/UID, immutable framework
paths and writable HOME, projected hooks and discovery errors, stdin/structured
stdout, exit status 7/127, signal forwarding, repeated cleanup signals, timeout
escalation, orphan reaping and argv confidentiality.

The image helper suite exercises schema cancellation through the real Tini and
universal lifecycle, with TERM-ignoring schema children, TERM/INT signals and
one/four-second shutdown budgets. It verifies the helper completes cleanup
before outer timeout escalation.

The application fixture compiles a client against the tested distribution's own
metastore/Hadoop JARs with a separate JDK 11 builder. Only client classes are
copied into the disposable test image; no compiler is added to production.
Private embedded Derby and loopback Thrift settings exist **only in tests**.
The suite tests both default CMD and explicit start-metastore, performs real
database create/read operations over Thrift, starts each same container three
times under both UID1001 and root, verifies database contents and schema reuse,
then checks explicit TERM, INT and docker stop with exact PRE/POST ordering and
no surviving metastore JVM or KILL escalation. Container-side CLI deadlines also
cover normal and TERM-ignoring commands. It publishes no ports
and uses no host data mounts or external database.

The test configuration selects the distribution's real
`DefaultPartitionExpressionProxy`: Hive 3.1.3 otherwise defaults to a Hive QL
class that is not included in this metastore-only image. This fixture setting
never enters production. That standalone proxy does not implement partition
expression pruning; these regressions validate lifecycle and basic Thrift
database operations, **not** query execution or pruning semantics. Deployments
must select an expression proxy appropriate to their client/workload.

The fixture also retains the packaged EventCleanerTask and RuntimeStatsCleanerTask
as always-on tasks, omitting Hive 3.1.3's default QL replication DumpDirCleanerTask
which is absent from its standalone distribution. Remote maintenance task defaults
remain unchanged. This test-only configuration does not validate replication
dump cleanup and is not installed into the production image.
