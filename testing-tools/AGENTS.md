# Testing-Tools Container
<!-- Parent: ../AGENTS.md -->

## Overview
Integration testing utility image. Debian-based Python image with tools for E2E testing of the Kubedoop data stack. Published to test registry (quay.io/zncdatadev-test/).

## Build
- Command: `make testing-tools-build`
- Base image: python:3.13-slim-bookworm (standalone, NOT kubedoop-base)
- Build approach: Installs Debian OpenJDK 17 JDK, build tools and Python packages from `python/requirements.txt`, downloads Keycloak CLI, and creates the kubedoop user (uid/gid 1000 — different from kubedoop-base's 1001).
- Python runtime verification: `sh testing-tools/tests/test_python_runtime.sh <image> [platform]`.
- Java and Keycloak CLI verification: `sh testing-tools/tests/test_keycloak_java.sh <image> [platform]`.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Testing-tools container version (0.1.0) |
| keycloak_version | Keycloak CLI version |

## Dependencies
- Extends: python:3.13-slim-bookworm.
- Used by: CI/CD integration tests for the Kubedoop data stack

## Kafka Python client
- `kafka-python3` 3.0.0 bundles an older `six`; the Dockerfile replaces it with the pinned `six` version for Python 3.12+ compatibility.
- Verify with `sh testing-tools/tests/test_kafka_python.sh <image> [platform]`.

## Key Files
- `Dockerfile` — multi-tool testing image with Python, JDK, kubectl, Keycloak CLI, Kerberos client
- `python/requirements.txt` — 14 Python test packages (pyhive, kafka-python, pydruid, requests-kerberos, etc.)
- `versions.yaml` — version specifications
