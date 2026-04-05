# Krb5 Container
<!-- Parent: ../AGENTS.md -->

## Overview
Kerberos 5 test/development server. Standalone image based on Rocky Linux (NOT kubedoop-base). Uses systemd for service management. Published to test registry (quay.io/zncdatadev-test/).

## Build
- Command: `make krb5-build`
- Base image: quay.io/rockylinux/rockylinux:9 (standalone, NOT kubedoop-base)
- Build approach: Installs krb5-server, krb5-server-ldap, krb5-workstation. Configures systemd for container use with custom container-krb5.target systemd target. Has krb5-setup init script (147 lines) that auto-initializes KDC and kadmin on first run with configurable realm, domain, and passwords. Includes minimal-fedora-37.patch for systemd tuning.

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product_version | Krb5 container version (1.0.0) |

## Dependencies
- Extends: rockylinux:9 (standalone, not kubedoop-base)
- Used by: testing-tools (Kerberos test dependency)

## Key Files
- `Dockerfile` — systemd + Kerberos server installation with container-krb5.target
- `krb5-setup` — KDC/kadmin init script (auto-configures realm, domain, passwords on first run)
- `container-krb5.target` — custom systemd unit for containerized operation
- `minimal-fedora-37.patch` — systemd tuning patch
- `versions.yaml` — version specifications
- `README.md` — usage for Docker/Podman/K8s

## Network & Storage
- Exposes: ports 88/tcp, 88/udp, 464/tcp, 464/udp, 749
- Volumes: /tmp, /run, /data
