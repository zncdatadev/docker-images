# Java Development Container
<!-- Parent: ../AGENTS.md -->

## Overview
Full Java JDK development environment. Used as builder stage by all Java products. Includes Maven and comprehensive C/C++ toolchain.

## Build
- Command: `make java-devel-build`
- Base image: kubedoop-base
- Build approach: Installs Adoptium Temurin JDK (full JDK, not JRE), Maven, and comprehensive C/C++ toolchain (cmake, gcc, gcc-c++, make) plus dev headers. Handles `alternatives` for Java version when it differs from Maven's default JDK 17. Has version-specific path handling for Java >= 24 vs older versions. Sets `LOG4J_FORMAT_MSG_NO_LOOKUPS=true`.
- Select the vendor's existing canonical java/javac alternatives, preserving slave links such as jar/javadoc/javap; do not re-register a symlink path without those tools. Preserve the public JAVA_HOME via a compatibility alias for newer package layouts.
- Checksum-pinned Tini and a protected universal entrypoint live under `/usr/local/libexec/kubedoop-java-devel`, outside legacy downstream `/kubedoop` copies. Root USER, inherited working directory and default Bash CMD remain unchanged. Docker RUN compilation does not invoke the image ENTRYPOINT.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Java JDK major versions (list, e.g., 8, 11, 17, 21, 22, 23, 24) |
| kubedoop-base_version | Parent base image version |

## Dependencies
- Extends: kubedoop-base
- Used by: ALL Java products as builder stage (hadoop, hbase, hive, kafka, nifi, spark-k8s, trino, zookeeper, dolphinscheduler)

## Key Files
- `Dockerfile` — Temurin JDK + Maven + alternatives version logic
- `versions.yaml` — version specifications
- `kubedoop/` — process-group lifecycle, stderr diagnostics and projected executable pre/post hooks
- `tests/` — source/generic image suites, offline real javac/jar/javadoc/javap and Maven selection across every SDK as UID1001/root, plus original source-built ZooKeeper downstream acceptance
