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
