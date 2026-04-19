# Kubedoop Base Container
<!-- Parent: ../AGENTS.md -->

## Overview
The foundational base image for the entire Kubedoop stack. Creates the kubedoop user and provides minimal utilities. Every production image traces back to this.

## Build
- Command: `make kubedoop-base-build`
- Base image: registry.access.redhat.com/ubi9/ubi-minimal:9.6
- Build approach: Creates kubedoop user/group (uid/gid 1001, home /kubedoop). Installs minimal utils (findutils, iputils, less, procps, tar) and tini as init system. Deploys universal entrypoint framework (signal forwarding, runtime script injection). Sets OCI image labels.
- ENTRYPOINT: `["tini", "--", "/kubedoop/bin/entrypoint.sh"]` — tini as PID 1 for signal delivery and zombie reaping, entrypoint.sh manages graceful shutdown and runtime script injection
- USER: root — derived images must set USER 1001 (kubedoop) at the end of their final stage

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Image version (1.0.0) |
| kubedoop-base_version | Image version (1.0.0, same as product_version) |

## Dependencies
- Extends: ubi9-minimal
- Used by: go-devel, java-devel, tools, vector, helloworld (directly), and transitively ALL other production images

## Key Files
- `Dockerfile` — kubedoop user/group creation, package install, tini init, framework deployment
- `kubedoop/dnf.conf` — package manager configuration
- `kubedoop/bin/entrypoint.sh` — universal container entrypoint (signal forwarding, runtime injection)
- `kubedoop/lib/log.sh` — unified logging framework
- `kubedoop/lib/run-phase.sh` — script auto-discovery and execution engine
- `kubedoop/lib/signal.sh` — graceful process termination (SIGTERM → SIGKILL escalation)
- `versions.yaml` — version specifications
