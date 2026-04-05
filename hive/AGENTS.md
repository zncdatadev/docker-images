# Hive Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Hive metastore. Only builds the metastore component, NOT the full Hive service. Uses a version-branching build strategy where older versions build standalone-metastore directly and newer versions follow HIVE-20451 two-stage approach.

## Build Details
- Build command: `make hive-build`
- Build stages: single build stage that branches by version -- for versions < 4.0.0 builds standalone-metastore directly; for >= 4.0.0 follows HIVE-20451 two-stage approach with separate metastore-server
- Build system: Maven
- Base images: java-devel -> java-base

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | Hive version (3.1.3, 4.0.0, 4.0.1) |
| java-base | JRE version for runtime (Java 11) |
| java-devel | JDK version for build (Java 8 -- unique split from runtime) |
| hadoop | Hadoop version (provides HDFS client + AWS/Azure JARs) |
| jmx-exporter | JMX exporter version |

## Kubedoop Customizations
### Patches (12 total)
- `kubedoop/patches/3.1.3/` -- 10 patches: HIVE-26905, HIVE-21939, HIVE-26522, HIVE-26743, HIVE-26882, HIVE-27508, patch-updates, logging-deps, maven-warning, postgres-driver
- `kubedoop/patches/4.0.1/` -- 2 patches: postgres-driver, logging-dependencies

### JMX Configuration (1 config)
- `config.yaml` -- minimal JMX configuration

### Custom Scripts
- `bin/start-metastore` -- custom startup script with `--db-type`, `--config`, `--hive-bin-dir` arguments. Handles database schema initialization before starting the metastore service.

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
