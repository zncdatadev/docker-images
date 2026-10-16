# Trino Container
<!-- Parent: ../AGENTS.md -->

## Overview
Trino SQL query engine. Only product with an external plugin build (trino-storage from snowlift, not trinodb). Spans Java 22-24 across its version matrix.

## Build Details
- Build command: `make trino-build`
- Build stages: storage-connector-builder, trino-builder, checksum-verified tini-downloader, and final runtime stage. Runtime lifecycle files are copied only into the final stage.
- Build system: Maven (./mvnw wrapper)
- Base images: java-devel (builder) → java-base (runtime)

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | Trino version (list: 451, 470, 476) |
| java-base | JRE version for runtime image (22, 23, 24) |
| java-devel | JDK version for builder image (22, 23, 24) |
| jmx-exporter | JMX exporter version |
| storage-connector | trino-storage plugin version (pegged to Trino version) |
| tini | Init system version (0.19.0) |

## Kubedoop Customizations
### Patches
- NONE
### JMX Configuration
- `kubedoop/jmx/config/config.yaml` — minimal: only `lowercaseOutputName: true`
### Custom Scripts
- `kubedoop/bin/entrypoint.sh` and `kubedoop/lib/` — independently vendored lifecycle framework
- `tests/source-entrypoint-framework.sh` — source lifecycle regressions
- `tests/image-entrypoint-framework.sh` — image wiring, hooks, signals, stdin and exit-code regressions
- `tests/image-trino-lifecycle.sh` — real single-node SQL, graceful stop and restart acceptance
- Framework commands own a separate session/group drained before post-hooks; timeout cancellation/reaping precedes ALRM handler removal. All versions require root/UID1001 SQL/TPCH across three same-container starts, TERM/INT/stop, stable identity and exactly-once ordered hooks.

## Dependencies
- Uses at build time: java-devel
- Uses at runtime: java-base, Python (Trino launcher requires it)
- Used by: none

## Key Files
- `Dockerfile` — external plugin build from snowlift/trino-storage, Trino source build with `-Dcheckstyle.skip -Dmaven.javadoc.skip=true`, log4shell vulnerability patch, Python install for launcher
- `kubedoop/jmx/config/config.yaml` — minimal JMX config
- `versions.yaml` — version specifications

## Extras
- External plugin trino-storage from snowlift (not trinodb); storage-connector version matches Trino version
- Builds with `--projects='!docs'` to skip documentation
- Applies log4shell vulnerability patch via lunasec log4shell tool
- Only product spanning Java 22-24
