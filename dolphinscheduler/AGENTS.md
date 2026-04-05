# DolphinScheduler Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache DolphinScheduler workflow engine. Builds from source with Maven. Only app product without kubedoop/ directory.

## Build
- Command: `make dolphinscheduler-build`
- Base image: java-devel (builder) → java-base (runtime)
- Build approach: Multi-stage. Stage 1 clones DolphinScheduler source from GitHub, builds with Maven (`./mvnw clean package -Prelease`), uses `--mount=type=cache` for .m2 and .pnpm-store. Stage 2 copies built artifacts to `/kubedoop/`. Symlinks `apache-dolphinscheduler-{ver}-bin` to `/kubedoop/dolphinscheduler`.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | DolphinScheduler releases (list, e.g., 3.3.2, 3.2.2) |
| java-base_version | Runtime JRE version |
| java-devel_version | Builder JDK version |

## Dependencies
- Extends: java-base (runtime)
- Used by: none

## Key Files
- `Dockerfile` — Source build with Maven cache and multi-stage artifact copy
- `versions.yaml` — version specifications
