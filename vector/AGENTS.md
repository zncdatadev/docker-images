# Vector Container
<!-- Parent: ../AGENTS.md -->

## Overview
Vector log collection/processing image. Intermediate layer between kubedoop-base and java-base. Also includes inotify-tools (compiled from source) and gomplate template processor.

## Build
- Command: `make vector-build`
- Base image: kubedoop-base
- Build approach: Multi-stage build. Stage 1 (vector-builder): downloads Vector RPM from packages.timber.io, compiles inotify-tools from source (uses autoconf/automake/libtool), downloads gomplate binary. Stage 2 (final): copies all three artifacts. Installs Vector via RPM and symlinks inotify-tools binaries.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Vector container version (0.47.0) |
| kubedoop-base_version | Parent base image version |
| inotify-tools_version | inotify-tools version (compiled from source) |
| gomplate_version | gomplate template processor version |

## Dependencies
- Extends: kubedoop-base
- Used by: java-base (directly), airflow, superset (runtime base)

## Key Files
- `Dockerfile` — multi-stage build: RPM install + inotify-tools source compilation + gomplate binary
- `versions.yaml` — version specifications
