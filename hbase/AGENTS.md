# HBase Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache HBase NoSQL database. Largest Dockerfile in the repo (291 lines) with 4 build stages, including a separate hbase-operator-tools build from a specific git commit SHA.

## Build Details
- Build command: `make hbase-build`
- Build stages: (1) hbase-builder -- builds HBase from source with `-Dhadoop.profile=3.0`, (2) hbase-operator-tools-builder -- builds from specific git commit SHA, (3) hadoop -- copies from hadoop image, (4) hadoop-s3-builder -- extracts AWS JARs
- Build system: Maven
- Base images: java-devel -> java-base

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | HBase version (2.6.1, 2.6.2) |
| java-base | JRE version for runtime image |
| java-devel | JDK version for build image |
| hadoop | Hadoop version (provides HDFS client JARs) |
| hbase-operator-tools | Operator tools version (git commit SHA, not release tag) |
| hbase-thirdparty | HBase thirdparty version |
| phoenix | Apache Phoenix version |
| hbase-profile | Maven profile (2.6) |
| jmx-exporter | JMX exporter version |
| async-profiler | Async-profiler version |
| oauth2-proxy | OAuth2 proxy version |

## Kubedoop Customizations
### Patches (13 total across 3 components)
- `kubedoop/patches/hbase/2.4.18/` -- 5 patches (HBASE-27103, HBASE-28242, HBASE-28379, HBASE-28511, patch-updates) + series file
- `kubedoop/patches/hbase/2.6.1/` -- 4 patches (async-profiler support, dependency updates, jackson-dataformat-xml, CycloneDX) + patchable.toml
- `kubedoop/patches/hbase-operator-tools/1.3.0-fd5a5fb/` -- 2 patches (exclude hbase-testing-utils, configure git-commit-id-plugin)

### JMX Configuration (4 configs)
- `master.yaml` -- HBase Master metrics (uses catch-all pattern `.*`)
- `regionserver.yaml` -- HBase RegionServer metrics (uses catch-all pattern `.*`)
- `restserver.yaml` -- HBase REST Server metrics (uses catch-all pattern `.*`)
- `config.yaml` -- base JMX config

Note: JMX is conditional -- empty JMX_EXPORTER_VERSION for 2.6 which has native JMX/Prometheus support.

### Custom Scripts
- `kubedoop/patches/apply_patches.sh` -- applies versioned patches during build

## Extras
- Downloads hbase-operator-tools from specific git commit SHA (not release tag)
- Uses patchable.toml for 2.6.1 patch configuration
- Final image installs python + pip
- Only product with hbase-operator-tools
- Includes async-profiler, oauth2-proxy

## Dependencies
- Uses at build time: java-devel (JDK + Maven), hadoop (COPY AWS JARs via intermediate stage)
- Uses at runtime: java-base (JRE)
- Used by: spark-k8s (commented out, planned)

## Key Files
- `Dockerfile` -- 291 lines, 4 stages (hbase-builder, operator-tools-builder, hadoop, hadoop-s3-builder)
- `kubedoop/patches/hbase/{ver}/` -- per-version HBase patches
- `kubedoop/patches/hbase-operator-tools/{ver}/` -- per-version operator-tools patches
- `kubedoop/jmx/config/` -- 4 JMX configs (master, regionserver, restserver, base)
- `versions.yaml` -- version specifications
