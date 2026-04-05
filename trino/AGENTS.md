# Trino Container
<!-- Parent: ../AGENTS.md -->

## Overview
Trino SQL query engine. Only product with an external plugin build (trino-storage from snowlift, not trinodb). Spans Java 22-24 across its version matrix.

## Build Details
- Build command: `make trino-build`
- Build stages: (1) storage-connector-builder builds trino-storage from snowlift/trino-storage GitHub, (2) trino-builder builds Trino from source excluding docs, copies storage connector plugin into plugin directory, applies log4shell patch, (3) final runtime stage
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

## Kubedoop Customizations
### Patches
- NONE
### JMX Configuration
- `kubedoop/jmx/config/config.yaml` — minimal: only `lowercaseOutputName: true`
### Custom Scripts
- NONE

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
