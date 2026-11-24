# Hive Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Hive metastore. Only builds the metastore component, NOT the full Hive service. Uses a version-branching build strategy where older versions build standalone-metastore directly and newer versions follow HIVE-20451 two-stage approach.

## Build Details
- Build command: `make hive-build`
- Build stages: hive-builder branches by version (< 4.0.0 standalone-metastore; >= 4.0.0 HIVE-20451 two-stage metastore-server), checksum-verified tini-downloader, Hadoop distribution import, final runtime
- Build system: Maven
- Base images: java-devel -> java-base
- Hive 4.0.0 runtime assembly corrects the native schemaTool launcher's stale class name to match its packaged tools.schematool.MetastoreSchemaTool and the upstream 4.0.1 script; a typed help smoke test checks class loading without initializing any database.

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | Hive version (3.1.3, 4.0.0, 4.0.1) |
| java-base | JRE version for runtime (Java 11) |
| java-devel | JDK version for build (Java 8 -- unique split from runtime) |
| hadoop | Hadoop version (provides HDFS client + AWS/Azure JARs) |
| jmx-exporter | JMX exporter version |
| tini | Pinned init binary version (architecture-specific checksums in Dockerfile) |

## Kubedoop Customizations
### Patches (12 total)
- `kubedoop/patches/3.1.3/` -- 10 patches: HIVE-26905, HIVE-21939, HIVE-26522, HIVE-26743, HIVE-26882, HIVE-27508, patch-updates, logging-deps, maven-warning, postgres-driver
- `kubedoop/patches/4.0.1/` -- 2 patches: postgres-driver, logging-dependencies

### JMX Configuration (1 config)
- `config.yaml` -- minimal JMX configuration

### Custom Scripts
- `bin/start-metastore` -- explicit validate/initialize helper with `--db-type`, `--config`, `--hive-bin-dir` and service arguments after `--`; stops schema children on cancellation and execs the native metastore launcher.
- `bin/entrypoint.sh`, `lib/{log,run,signal}.sh` -- universal foreground lifecycle, projected root-owned hooks, bounded graceful termination and application status propagation.
- Default ENTRYPOINT is tini plus the universal entrypoint; default CMD is `base --service metastore`. No database type or schema initialization policy is imposed by the default CMD.
- `tests/` -- source/helper/image regressions and real Thrift/Derby persistence/TERM/INT tests for default CMD and the schema helper; fixtures never enter production.
- Owned managed process groups drain before post-hooks even after normal main exit. Lifecycle ALRM and schema-helper timers are forcibly cancelled and reaped; tests retain true statuses 127/142/165 and cover root/UID1001 native and wrapper launches with three same-container starts, TERM/INT/stop and exact PRE/POST ordering.

## Extras
- Uses Java 8 for devel but Java 11 for base (unique split across the repo)
- Links AWS/Azure JARs from hadoop image into hive-metastore/lib
- Depends on hadoop image at build time (COPYs entire Hadoop distribution)

## Dependencies
- Uses at build time: java-devel (JDK 8 + Maven), hadoop (COPY entire Hadoop + AWS/Azure JARs)
- Uses at runtime: java-base (JRE 11)
- Used by: none directly

## Key Files
- `Dockerfile` -- version-branching build logic (< 4.0 standalone vs >= 4.0 HIVE-20451)
- `kubedoop/bin/start-metastore` -- metastore startup with DB schema init
- `kubedoop/patches/{ver}/` -- per-version patches (12 total across 2 versions)
- `kubedoop/jmx/config/config.yaml` -- minimal JMX config
- `versions.yaml` -- version specifications
