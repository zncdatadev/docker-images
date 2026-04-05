# Tools Container
<!-- Parent: ../AGENTS.md -->

## Overview
CLI utility image with jq, yq, and kubectl. Extends kubedoop-base with common tools for debugging and operations.

## Build
- Command: `make tools-build`
- Base image: kubedoop-base
- Build approach: Installs system packages (gettext, gzip, iputils, openssl, tar, wget, zip) and downloads three CLI tools: jq (JSON processor), yq (YAML processor), kubectl (Kubernetes CLI). All tools installed to /kubedoop/bin/ with proper ownership. Architecture-aware downloads. Each tool has smoke test (--version). Sets PATH="/kubedoop/bin:${PATH}".

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Tools container version (1.0.0) |
| kubedoop-base_version | Parent base image version |
| kubectl_version | Kubernetes CLI version |
| jq_version | jq JSON processor version |
| yq_version | yq YAML processor version |

## Dependencies
- Extends: kubedoop-base
- Used by: CI/CD pipelines, debugging

## Key Files
- `Dockerfile` — multi-tool install with smoke tests per tool
- `versions.yaml` — version specifications
