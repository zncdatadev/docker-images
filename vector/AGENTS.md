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

## Process Management
- Preserve inherited root USER and /bin/bash CMD; no automatic log collection.
- Checksum-pinned Tini0.19.0, setsid foreground group, universal root-owned hooks,
  stderr diagnostics, stdin/status retention and bounded shutdown.
- Base-only helpers: `/usr/local/libexec/kubedoop-vector/{bin,lib}`. Never use
  `/kubedoop/bin/entrypoint.sh` for the inherited base supervisor: child products
  replace that path. Child ENTRYPOINT overrides work normally.
- HOME remains writable/sticky for UID1001, protected helper paths are outside
  application COPY/chown trees. Inotify source builds fail fast on errors.
- `tests/` covers generic lifecycle, real Vector VRL/file checkpoint restart and
  legacy child-entrypoint inheritance. Test a real ZooKeeper/java-base downstream
  source build too; vector changes trigger multiple product CI workflows.
