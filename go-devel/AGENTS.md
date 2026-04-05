# Go Development Container
<!-- Parent: ../AGENTS.md -->

## Overview
Go development environment. Installs Go binary from go.dev on top of kubedoop-base with C/C++ toolchain and development libraries.

## Build
- Command: `make go-devel-build`
- Base image: kubedoop-base
- Build approach: Installs C/C++ toolchain (cmake, gcc, gcc-c++, make) and dev libs (cyrus-sasl-devel, fuse-devel, krb5-devel, openssl-devel, etc.). Downloads Go binary from go.dev using `PRODUCT_VERSION`. Sets `GOROOT=/usr/local/go` and updates PATH. Architecture-aware (x86_64 -> amd64, aarch64 -> arm64). Smoke test: `go version`.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Go releases (list, e.g., 1.25.5, 1.25.3, 1.24.11, 1.24.9) |
| kubedoop-base_version | Parent base image version |

## Dependencies
- Extends: kubedoop-base
- Used by: airflow (git-sync build stage)

## Key Files
- `Dockerfile` — Go binary install with dev libs and architecture mapping
- `versions.yaml` — version specifications
