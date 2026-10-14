# Spark-k8s Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Spark on Kubernetes. Most complex dependency chain in the repo — uses gradle, hadoop, java-devel, and java-base images. Includes PySpark support with Python runtime.

## Build Details
- Build command: `make spark-build` (target is `spark-build`, NOT `spark-k8s-build`)
- Build stages: (1) gradle-builder downloads jackson-dataformat-xml, (2) hadoop stage for AWS/Azure JAR COPY, (3) spark-builder builds Spark via make-distribution.sh, fixes log4j-slf4j-impl, downloads oauth2-proxy, (4) final runtime stage
- Build system: Maven (Spark's make-distribution.sh) + Gradle (jackson-dataformat-xml)
- Additional checksum-pinned Tini downloader stage and final product-local universal entrypoint. Native Spark scripts remain unchanged.
- Base images: java-devel + gradle:8 (external) → java-base (runtime)

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | Spark version (e.g. 3.5.5) |
| java-base | JRE version for runtime image |
| java-devel | JDK version for builder image |
| python | Python version for PySpark |
| hadoop | Hadoop version for -Dhadoop.version |
| hbase | Declared build dependency; runtime HBase JAR COPY remains commented out |
| jmx-exporter | JMX exporter version |
| oauth2-proxy | OAuth2 Proxy version |
| jackson-dataformat-xml | Jackson XML version for extra-jars |
| tini | Pinned init version, with architecture-specific checksums |

## Kubedoop Customizations
### Patches
- NONE
### JMX Configuration
- `kubedoop/jmx/config/config.yaml` — comprehensive Spark-specific metrics: master, worker, driver (DAGScheduler, BlockManager, jvm), executor (filesystem, executor), streaming, structured streaming, HiveExternalCatalog, CodeGenerator, LiveListenerBus
### Custom Scripts
- `kubedoop/bin/entrypoint.sh`, `kubedoop/lib/{log,run,signal}.sh` — universal pre/post hooks, stderr diagnostics, stdin retention, bounded TERM/INT shutdown and exit propagation.
- `kubedoop/bin/run-spark` — foreground master/worker/history, Kubernetes driver/executor and arbitrary command pass-through; no embedded second Tini or options echo.
- ENTRYPOINT prefixes the runner after Tini/universal entrypoint; CMD is `spark-submit --help`, UID 1001 preserved.
- Main commands use a separate `setsid` foreground process group. TERM/INT and
  bounded escalation cover Java/Python children before post-hooks; hook cleanup
  remains outside the workload group. Runtime includes util-linux-core.
- Exact duplicate version entries are removed; the supported 3.5.5 configuration and dependency pins are unchanged.

## Dependencies
- Uses at build time: java-devel (Spark build), gradle:8 (jackson-dataformat-xml download), hadoop (COPY AWS+Azure JARs)
- Uses at runtime: java-base
- Used by: none

## Key Files
- `Dockerfile` — multi-stage: gradle download, hadoop JAR copy, make-distribution.sh with `-Phadoop-3 -Pkubernetes -Phive -Phive-thriftserver`, log4j-slf4j-impl fix, oauth2-proxy setup
- `kubedoop/jmx/config/config.yaml` — Spark JMX rules
- `versions.yaml` — version specifications

## Extras
- log4j-slf4j-impl fix (commit b04b22e): downloads missing JAR via Maven to resolve logging output issues when external JARs are added
- Installs Python + pip in final image for PySpark; sets PYSPARK_PYTHON and PYTHONPATH
- Extra JARs go to spark/extra-jars/; examples.jar symlinked
- HBase JAR COPY is commented out, but the version pin still causes the generated
  bake graph to build HBase and operator-tools. Preserve this existing dependency
  graph; do not hand-edit the generated bakefile to skip it.
- Regression suites under `tests/`: framework source behavior, runner source
  contracts, final image lifecycle, actual native Spark launchers and real
  PySpark/HistoryServer persistence and shutdown. Native Kubernetes scheduling
  and operator command migration are separate acceptance scopes.
