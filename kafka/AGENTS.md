# Kafka Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Kafka message streaming platform. Only product using Gradle as its build system. Builds purely from upstream source with zero patches.

## Build Details
- Build command: `make kafka-build`
- Build stages: single build stage using Gradle with `--mount=type=cache,sharing=locked` (fixes Gradle concurrency lock issue)
- Build system: Gradle
- Base images: java-devel -> java-base

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | Kafka version (3.7.2, 3.8.0, 3.9.0, 4.0.0) |
| scala | Scala version (2.13) |
| java-base | JRE version for runtime (21-23) |
| java-devel | JDK version for build (21-23) |
| kcat | kcat CLI tool version |
| jmx-exporter | JMX exporter version |

## Kubedoop Customizations
### Patches
None -- only product that builds purely from upstream source without any patches.

### JMX Configuration (1 config)
- `config.yaml` -- most detailed JMX config in the repo (~70 lines): per-second counters, gauges, histogram percentile emulation, quota metrics, coordinator metrics. Extensive Kafka-specific rules.

### Custom Scripts
None.

## Extras
- Widest Java version range of any product (21-23). Kafka 4.0.0 uses Java 23.
- Log4Shell vulnerability patch applied to built Kafka JARs
- Includes kcat CLI for Kafka topic inspection
- Only product using Gradle (all other Java products use Maven)

## Dependencies
- Uses at build time: java-devel (JDK + Gradle)
- Uses at runtime: java-base (JRE)
- Used by: none

## Key Files
- `Dockerfile` -- Gradle build with cache mount + log4shell post-build patch
- `kubedoop/jmx/config/config.yaml` -- extensive Kafka-specific JMX rules (~70 lines)
- `versions.yaml` -- version specifications
