# Hadoop Container
<!-- Parent: ../AGENTS.md -->

## Overview
HDFS-focused Apache Hadoop distribution. The existing Maven build excludes YARN and MapReduce distribution modules; shipped commands are hadoop, hdfs and fuse_dfs. Compiles protobuf from source and builds native code support including fuse_dfs.

## Build Details
- Build command: `make hadoop-build`
- Build stages: complex source/native builder (protobuf, boost/EPEL, Hadoop `-Pdist,native`, fuse_dfs), checksum-pinned Tini downloader, final Java runtime
- Source builder copies only patches into /build/patches; JMX configuration retains its original separate COPY. Runtime entrypoint changes do not invalidate the Hadoop Maven source layer.
- Build system: Maven
- Base images: java-devel -> java-base

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | Hadoop version (3.3.6, 3.4.1) |
| java-base | JRE version for runtime image |
| java-devel | JDK version for build image |
| protobuf | Protobuf version compiled from source |
| jmx-exporter | JMX exporter version |
| async-profiler | Async-profiler version |
| oauth2-proxy | OAuth2 proxy version |
| tini | Pinned init binary version, with architecture-specific checksums |

## Kubedoop Customizations
### Patches (18 total)
- `kubedoop/patches/3.3.6/` -- 8 patches: YARN-11527, datanode registration override, HADOOP-18055, HADOOP-18077, perf event itimer, HDFS-17378, snappy CVEs, HADOOP-18516
- `kubedoop/patches/3.4.1/` -- 10 patches: YARN-11527/node.js, datanode registration, async-profiler itimer, HDFS-17378, CycloneDX, OSS connector, netty CVEs x2, kafka CVE, Jetty upgrade

### JMX Configuration (3 configs)
- `namenode.yaml` -- HDFS NameNode-specific whitelist/blacklist patterns
- `datanode.yaml` -- HDFS DataNode-specific whitelist/blacklist patterns
- `journalnode.yaml` -- HDFS JournalNode-specific whitelist/blacklist patterns

### Custom Scripts
- `kubedoop/patches/apply_patches.sh` -- applies versioned patches during build
- `kubedoop/bin/entrypoint.sh`, `kubedoop/lib/{log,run,signal}.sh` -- universal foreground lifecycle, root-owned projected hooks, bounded TERM/INT shutdown and exit propagation
- Default ENTRYPOINT is Tini plus the universal entrypoint; CMD is `hdfs namenode`. No automatic NameNode formatting or native script rewriting occurs.
- `tests/` -- source/image regressions, four shipped HDFS foreground role paths, real isolated HDFS data/identity persistence and restart/TERM/INT tests. Fixtures are test-only.

## Extras
- Includes async-profiler, oauth2-proxy, JMX exporter
- Log4Shell vulnerability patcher applied to built JARs
- fuse_dfs binary produced for HDFS FUSE mount support
- Sets LD_LIBRARY_PATH for native libraries

## Dependencies
- Uses at build time: java-devel (JDK + Maven)
- Uses at runtime: java-base (JRE)
- Used by: hbase (COPYs entire Hadoop + AWS JARs), hive (COPYs entire Hadoop + AWS/Azure JARs), spark-k8s (COPYs Hadoop JARs)

## Key Files
- `Dockerfile` -- protobuf from source + boost + native build
- `kubedoop/patches/{ver}/` -- versioned patches (18 total across 2 versions)
- `kubedoop/jmx/config/` -- 3 HDFS role-specific JMX configs
- `versions.yaml` -- version specifications
