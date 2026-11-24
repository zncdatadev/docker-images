# Java SDK process management and builder compatibility

From the repository root after building all original java-devel versions and a
cheap downstream source target (ZooKeeper:3.9.3):

```bash
bash java-devel/tests/source-entrypoint-framework.sh
bash java-devel/tests/image-entrypoint-framework.sh SDK_IMAGE
bash java-devel/tests/image-java-sdk.sh SDK_IMAGE MAJOR
bash java-devel/tests/image-downstream-zookeeper.sh ZOOKEEPER_IMAGE
```

Run the source suite as root too. Own native CI covers JDK8/11/17/21/22/23/24 on
amd64/arm64, and all affected Java product workflows still build their original
source graphs. No external prebuilt product image replaces a local source build.

The root USER, working directory, Bash CMD/stdin, public JAVA_HOME, JAVA_VERSION
and Log4Shell mitigation remain. Maven's incidental JDK17 must not capture the
selected toolchain. Select the canonical vendor java/javac alternatives without
dropping jar/javadoc/javap slave links. Newer package layouts are aliased to the
existing JAVA_HOME path, including JDK24.

Each SDK compiles the dependency-free fixture offline as UID1001 and root using
its own actual javac, packages an executable JAR, generates Javadoc and checks
Java8 bytecode using javap. Maven's actual runtime JDK is checked too. That JAR
runs through three persisted starts in the same container with TERM, INT and
docker stop, verifying JVM143, System.exit42 and shutdown-hook flush before
exactly-once post hooks. Container INT requests graceful TERM from the supervisor.

A child fixture deliberately owns the legacy `/kubedoop/bin/entrypoint.sh` path
and replaces CMD. Protected SDK helpers remain effective outside that copied
tree. Generic tests also cover stdin/stdout, runtime hashes, protected HOME and
helpers, projected hooks/permissions/failures, orphan reaping, owned groups,
repeated cleanup signals and bounded escalation. Detached/setsid-escaping
applications are outside the foreground process-group contract.

The downstream test exercises artifacts actually built by this SDK in Docker RUN
and starts the original ZooKeeper JVM with isolated config, creates a znode and
checks its value after same-container restart. The SDK supervisor must not leak
into that separate final runtime stage. No host ports or user data are used.
