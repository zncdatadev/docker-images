# Kafka Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Kafka message streaming platform. Only product using Gradle as its build system. Builds purely from upstream source with zero patches.

## Build Details
- Build command: `make kafka-build`
- Build stages: Gradle build with `--mount=type=cache,sharing=locked`, checksum-verified tini downloader, and final runtime stage
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
| tini | Init system version (0.19.0) |

## Kubedoop Customizations
### Patches
None -- only product that builds purely from upstream source without any kubedoop source patches (post-build Log4Shell JAR hardening is applied separately).

### JMX Configuration (1 config)
- `config.yaml` -- most detailed JMX config in the repo (~70 lines): per-second counters, gauges, histogram percentile emulation, quota metrics, coordinator metrics. Extensive Kafka-specific rules.

### Custom Scripts
- `kubedoop/bin/entrypoint.sh` and `kubedoop/lib/` -- lifecycle framework vendored within the Kafka image
- `tests/source-entrypoint-framework.sh` -- source-level lifecycle regressions, independent of other product directories
- `tests/image-entrypoint-framework.sh` -- image regressions for hooks, signals, stdin, exit status, and log redaction
- `tests/image-kafka-lifecycle.sh` -- disposable KRaft broker produce/consume, graceful stop, and restart acceptance
- Framework diagnostics use stderr without contaminating command streams. Root-owned sticky HOME permits caches but protects bin/lib/mount; the application owns a session/group drained before post-hooks, with safe timer cancellation/reaping before ALRM handler removal.
- All four versions require real KRaft identity/message persistence over three same-container starts as kubedoop and root, TERM/INT/Docker stop and exactly-once PRE/POST; no production storage formatting or default-command changes.

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
- `tests/README.md` -- local checks and the explicit Kafka storage/configuration contract
