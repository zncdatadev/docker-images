# Java Base Container
<!-- Parent: ../AGENTS.md -->

## Overview
Java JRE runtime image. Key intermediate layer between vector and all Java-based application images. Includes Log4Shell mitigation.

## Build
- Command: `make java-base-build`
- Base image: vector (dependency chain: kubedoop-base -> vector -> java-base)
- Build approach: Installs Adoptium Temurin JRE repo, installs `temurin-{ver}-jre`, krb5-workstation, tzdata-java. Sets `JAVA_HOME` and `LOG4J_FORMAT_MSG_NO_LOOKUPS=true` (Log4Shell mitigation).
- Checksum-pinned Tini is built in a private download stage. The final image uses Tini + a protected universal entrypoint under `/usr/local/libexec/kubedoop-java-base`; legacy downstream `/kubedoop` copies cannot overwrite it. Root USER and `/bin/bash` CMD remain unchanged. Temurin's newer package layout is aliased to the existing `JAVA_HOME` path.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Java JRE major versions (list, e.g., 8, 11, 17, 21, 22, 23, 24) |
| vector_version | Parent vector image version |

## Dependencies
- Extends: vector
- Used by: ALL Java application images (airflow, dolphinscheduler, hadoop, hbase, hive, kafka, nifi, spark-k8s, trino, zookeeper)

## Key Files
- `Dockerfile` — Temurin JRE install with Log4Shell mitigation
- `versions.yaml` — version specifications
- `kubedoop/` — vendored process-group lifecycle and projected executable pre/post hooks
- `tests/` — source/image regressions and actual Java8-bytecode lifecycle across all JREs; compile test classes using the source-built java-devel:8 image
