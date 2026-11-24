# Kubedoop Base Container
<!-- Parent: ../AGENTS.md -->

## Overview
The foundational base image for the entire Kubedoop stack. Creates the kubedoop user and provides minimal utilities. Every production image traces back to this.

## Build
- Command: `make kubedoop-base-build`
- Base image: registry.access.redhat.com/ubi9/ubi-minimal:9.6
- Build approach: Creates kubedoop user/group (uid/gid 1001, home /kubedoop). Installs minimal utils (findutils, iputils, less, procps, tar). Copies custom dnf.conf (`install_weak_deps=False`, `assumeyes=True`). Sets OCI image labels.
- Checksum-pinned Tini and setsid supervise the main process group with bounded shutdown, orphan reaping, real exit status and ordered projected root-owned hooks. Root USER, working directory and Bash CMD remain unchanged.
- Helpers are protected under `/usr/local/libexec/kubedoop-base`, outside downstream legacy `/kubedoop` copies. Child CMD inheritance and explicit ENTRYPOINT overrides are tested; Docker RUN does not invoke the image ENTRYPOINT. Product-specific launchers may override the generic foreground supervisor for their own graceful-shutdown policy.

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
- `Dockerfile` — kubedoop user/group creation and minimal package install
- `kubedoop/dnf.conf` — package manager configuration
- `versions.yaml` — version specifications
- `kubedoop/bin/`, `kubedoop/lib/` — private universal process lifecycle
- `tests/` — source/image/inheritance and original source-built downstream regressions
