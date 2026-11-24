# DolphinScheduler Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache DolphinScheduler workflow engine. Builds from source with Maven. Includes product-local universal foreground process management under kubedoop/.

## Build
- Command: `make dolphinscheduler-build`
- Base image: java-devel (builder) → java-base (runtime)
- Build approach: Multi-stage. Stage 1 clones DolphinScheduler source from GitHub, builds with Maven (`./mvnw clean package -Prelease`), uses `--mount=type=cache` for .m2 and .pnpm-store. Stage 2 copies built artifacts to `/kubedoop/`. Symlinks `apache-dolphinscheduler-{ver}-bin` to `/kubedoop/dolphinscheduler`.
- A separate Tini downloader verifies architecture-specific checksums for version 0.19.0. Runtime assembly asserts and creates foreground copies of all five native role launchers to exec Java and forward application arguments while preserving upstream env/JVM/classpath behavior. Original start.sh files are unchanged for legacy daemon PID/status/stop and operator compatibility.
- Default ENTRYPOINT is Tini plus the universal entrypoint. CMD is `run-dolphinscheduler standalone-server`; distributed roles are explicit command arguments. Native daemon start/stop remains available, but is not a foreground container command.
- Root-owned framework directories and sticky HOME allow UID 1001 cache writes without framework replacement. Runtime configuration and product distribution ownership remain compatible.
- Managed commands own a separate session/process group using explicit util-linux-core/setsid. Live descendants drain before post-hooks, including normal exit; ALRM timers are forcibly cancelled and reaped before handler removal. Regressions cover true statuses 127/142/165 and root/UID1001 real API/H2 persistence over three same-container TERM/INT/stop cycles plus CLI deadlines, retaining five-role and legacy-daemon compatibility tests.
- Shared descendant shutdown deadlines use Linux monotonic uptime rather than Bash's integer-second clock, with a boundary regression preventing premature SIGKILL of a graceful child.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | DolphinScheduler release (3.3.2 or 3.2.2) |
| java-base | Runtime JRE version |
| java-devel | Builder JDK version |
| tini | Pinned init binary version |

## Dependencies
- Extends: java-base (runtime)
- Used by: none

## Key Files
- `Dockerfile` — Source build with Maven cache and multi-stage artifact copy
- `versions.yaml` — version specifications
- `kubedoop/bin/run-dolphinscheduler` — foreground role selection and exec of generated start-foreground.sh
- `kubedoop/prepare-launchers.sh` — asserted minimal native launcher adaptation at runtime assembly
- `kubedoop/bin/entrypoint.sh`, `kubedoop/lib/` — lifecycle hooks, signal/exit handling and stderr diagnostics
- `tests/` — source regressions, image lifecycle and five-role wiring tests, real standalone API/H2 restart/TERM/INT suite; fixtures never enter production
