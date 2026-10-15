# Testing-Tools Container
<!-- Parent: ../AGENTS.md -->

## Overview
Integration testing utility image. Debian-based Python image with tools for E2E testing of the Kubedoop data stack. Published to test registry (quay.io/zncdatadev-test/).

## Build
- Command: `make testing-tools-build`
- Base image: python:3.12-slim-bullseye (standalone, NOT kubedoop-base)
- Build approach: Installs build-essential, jq, krb5-user, kubectl, libkrb5-dev, openjdk-11-jdk-headless. Downloads Keycloak CLI. Installs 14 Python packages from python/requirements.txt for testing against data services (Hive, Kafka, NiFi, Trino, Superset) with Kerberos support. Creates kubedoop user (uid/gid 1000 — different from kubedoop-base's 1001).

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Testing-tools container version (0.1.0) |
| keycloak_version | Keycloak CLI version |

## Dependencies
- Extends: python:3.12-slim-bullseye (standalone, not kubedoop-base)
- Used by: CI/CD integration tests for the Kubedoop data stack

## Key Files
- `Dockerfile` — multi-tool testing image with Python, JDK, kubectl, Keycloak CLI, Kerberos client
- `python/requirements.txt` — 14 Python test packages (pyhive, kafka-python, pydruid, requests-kerberos, etc.)
- `versions.yaml` — version specifications

## Process Management
- Preserve standalone Python3.12 base, UID1000 and native Python3 CMD.
- Checksum-pinned Tini0.19.0, util-linux setsid, procps and root-owned helpers at
  `/usr/local/libexec/kubedoop-testing-tools`, installed after original chown.
- Universal root-owned hooks and bounded owned-group lifecycle, stderr diagnostics,
  stdin/status retention, writable sticky HOME and protected helper paths.
- Source/root/generic and real private Python/requests HTTP persistence/TERM/INT
  regressions run on native amd64/arm64 CI, with no external services.
- `build/debian-bullseye.list` uses official archived repositories, retaining
  signature validation and disabling expiry only for frozen archive entries.
  apt/pip stages fail fast instead of hiding missing build dependencies.
- Keep general `java` on Java11; add official Bullseye Java17 JRE and protected
  PATH adapters for kcadm/kcreg. They preserve explicit JAVA/JAVA_HOME overrides
  and exec the original Keycloak26 scripts. Direct vendor paths need Java17
  selected explicitly; regression checks both CLIs plus default Java11.
- `python/patch-kafka3-six.py` backports six's find_spec hook to the pinned
  kafka-python3==3.0.0 vendored six1.11, which otherwise cannot import on Python3.12.
  Guard package/source expectations; test native imports and Kafka integer codec.
