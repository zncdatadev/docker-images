# ZooKeeper Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache ZooKeeper coordination service. Simplest Java product build in the repo.

## Build Details
- Build command: `make zookeeper-build`
- Build stages: zookeeper-builder (Maven `-Pfull-build`, log4shell patch) + tini-downloader (checksum-verified static binary download), then final runtime stage
- Build system: Maven
- Base images: java-devel (Java 11) → java-base (Java 17) — unique Java version split

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | ZooKeeper version (e.g. 3.9.3) |
| java-base | JRE version for runtime image (17) |
| java-devel | JDK version for builder image (11), also used by the tini-downloader stage |
| jmx-exporter | JMX exporter version |
| tini | init system version (0.19.0) |

## Kubedoop Customizations
### Patches (1)
- `kubedoop/patches/3.9.2/` — 1 patch: cyclonedx-plugin (note: patch dir is 3.9.2 but current product version is 3.9.3)
### JMX Configuration
- `kubedoop/jmx/config/config.yaml` — ZooKeeper-specific rules: ReplicatedServer patterns (with replicaId label), standalone patterns, InMemoryDataTree pattern (with memberType label)
### Custom Scripts
- `kubedoop/patches/apply_patches.sh` — applies .patch files from version subdirectories
- `kubedoop/bin/entrypoint.sh` — universal entrypoint framework pilot for process lifecycle management
- `kubedoop/lib/` — entrypoint framework libraries for logging, operator script discovery/execution, and signal handling
- `tests/source-entrypoint-framework.sh` — source-level shell tests for the vendored entrypoint framework
- `tests/image-entrypoint-framework.sh` — image-level tests for built entrypoint behavior
- `tests/image-zookeeper.sh` — real default-CMD znode persistence and pre/post ordering over three same-container starts/stops as kubedoop and root
- Framework diagnostics use stderr; root-owned sticky HOME remains writable for user caches but protects root-owned bin/lib/mount. Commands own a separate session/group, drained before post-hooks, with timer cancellation/reaping before removing SIGALRM handling.

## Dependencies
- Uses at build time: java-devel (Java 11)
- Uses at runtime: java-base (Java 17)
- Used by: kafka (runtime dependency), hadoop/hbase (coordination)

## Key Files
- `Dockerfile` — simplest Java build: single Maven stage with `-Pfull-build`, excludes zookeeper-client-c, log4shell patch, tarball rename (-bin suffix)
- `kubedoop/bin/entrypoint.sh` — universal entrypoint wrapper used as the image entrypoint via tini
- `kubedoop/lib/` — vendored framework libraries for the product-first rollout
- `tests/source-entrypoint-framework.sh` — local source-level verification for framework lifecycle behavior
- `tests/image-entrypoint-framework.sh` — post-build image verification for entrypoint wiring, hooks, and signal behavior
- `tests/fixtures/` — derived-image projected lifecycle hooks, never a prebuilt product substitute
- `kubedoop/patches/3.9.2/` — version-specific patches
- `kubedoop/patches/apply_patches.sh` — patch application script
- `kubedoop/jmx/config/config.yaml` — ZooKeeper JMX rules
- `versions.yaml` — version specifications

## Extras
- Only product with Java version split: devel=11, base=17
- Extracted tarball has -bin suffix requiring rename (`mv apache-zookeeper-${VER}-bin apache-zookeeper-${VER}`)
- Applies log4shell vulnerability patch via lunasec log4shell tool
- Excludes zookeeper-client-c from build (`-pl "!zookeeper-client/zookeeper-client-c"`)
