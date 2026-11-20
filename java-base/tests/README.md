# Java runtime lifecycle and downstream compatibility

Run from the repository root after building the original source dependency graph:

```bash
bash java-base/tests/source-entrypoint-framework.sh
bash java-base/tests/image-entrypoint-framework.sh JRE_IMAGE
bash java-base/tests/image-java-lifecycle.sh JRE_IMAGE MAJOR SOURCE_BUILT_JDK8_IMAGE
bash java-base/tests/image-downstream-zookeeper.sh SOURCE_BUILT_ZOOKEEPER_IMAGE
```

Build every versions.yaml JRE (8, 11, 17, 21, 22, 23, 24), java-devel:8 and
ZooKeeper:3.9.3 through the generated bake graph. Run source tests again as root.
Own native amd64/arm64 CI compiles the dependency-free fixture using this repo's
JDK8 image (not an external prebuilt product) for each runtime. Every affected
downstream workflow also builds its original product matrix.

Root USER, default Bash/stdin, JAVA_VERSION and Log4Shell mitigation are retained.
JAVA_HOME remains `/usr/lib/jvm/temurin-N-jre`, with a compatibility symlink when
the vendor package uses the newer `java-N-temurin-jre` directory name. The test
checks that both JAVA_HOME/bin/java and the default java have the expected major.

The private child fixture deliberately owns `/kubedoop/bin/entrypoint.sh`, while
inheriting the protected supervisor and overriding CMD. It runs Java8-compatible
bytecode on each actual JRE as UID1001 and root, persists from JVM shutdown hooks
before post-scripts, restarts the same container twice, preserves TERM143 and
System.exit42, and detects hook duplication or forced kills. TERM/docker stop is
used for native JVM semantics; framework SIGINT and repeated shutdown signals
are covered separately by the generic suite. Detached/setsid-escaping applications
are outside the foreground process-group contract.

Source/generic tests cover projected symlinks/permissions, hook stdin isolation,
source-to-image hashes, root-owned private helper protection, HOME writability,
clean stdout, secret-free diagnostics, status127, orphan reaping, bounded KILL
and remaining process-group cleanup. Operators supply foreground application
commands/configs; this base does not start a Java service automatically.

The real downstream test uses the original full-source ZooKeeper artifact with
an explicit isolated configuration (not its legacy default config path), creates
a znode, restarts the same container and reads the persisted znode. It exposes no
host ports, mounts no user data and deletes only its own temporary fixtures.
