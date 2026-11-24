# HBase universal process management

The image preserves both product versions, Java 11, UID 1001, native scripts,
operator tools, Hadoop AWS libraries, JMX, async-profiler and oauth2-proxy.
ENTRYPOINT is `tini -- /kubedoop/bin/entrypoint.sh`; the original CMD remains
`hbase master start`. Native foreground launchers already exec Java.

Use foreground commands such as `hbase regionserver start`, `hbase rest start`,
`hbase thrift start`, `hbase thrift2 start` or `hbase zookeeper start`.
Do not use daemon start scripts or set HBASE_NOEXEC for the managed main process.
Native daemon administration remains unchanged. Kubernetes `command` overrides
ENTRYPOINT and bypasses the framework; use `args` or explicitly invoke the
universal entrypoint. This PR does not modify operators or deployment topology.

Root-owned executable .sh pre/post hooks under /kubedoop/mount run in filename
order. Projected links are followed and target ownership/executability checked.
Discovery/pre-hook failure aborts startup. Post failures are best-effort and do
not replace application status. Hooks get /dev/null stdin while the application
retains stdin. Framework diagnostics use stderr and omit argv, including debug
mode. HBase's own DEBUG is separate and may print native options.

TERM/INT initiate TERM-based graceful shutdown. Positive integer
KUBEDOOP_KILL_TIMEOUT defaults to 30 seconds before KILL escalation.
Repeated signals do not interrupt or duplicate cleanup; Tini reaps orphans.
Root-owned sticky HOME permits user cache writes without replacing framework
directories.

## Local and CI tests

```sh
bash hbase/tests/source-entrypoint-framework.sh
bash hbase/tests/image-entrypoint-framework.sh IMAGE
bash hbase/tests/image-native-launchers.sh IMAGE
bash hbase/tests/image-hbase-lifecycle.sh IMAGE
```

CI runs all four suites after each native architecture/version build. The generic
suite checks exact current runtime script hashes, metadata/UID, writable HOME and
protected directories, projected hooks, stdin/stdout, 7/127/42 statuses, bounded
shutdown, repeated signals, orphan reaping and confidential framework argv.

Six-role tests use actual native scripts with an instrumented JVM for class,
options, argv, exec PID and exit-status wiring. Real-service tests run the
unchanged default HMaster CMD in standalone mode (embedded ZooKeeper and
RegionServer), create/put/get/flush a real table, restart the same container,
verify bytes and cluster identity, then check TERM/INT and exactly-once hooks
with no surviving service JVM. Standalone local filesystem capability settings
exist only in disposable fixtures, not production defaults.

No host data is mounted or port published. This is process and local storage
continuity acceptance, not distributed HDFS, HA failover, Kerberos, REST/Thrift
protocol or Phoenix integration acceptance. Product scope is not changed.
