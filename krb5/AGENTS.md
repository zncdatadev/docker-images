# Krb5 Container
<!-- Parent: ../AGENTS.md -->

## Overview
Kerberos 5 test/development server. Standalone image based on Rocky Linux (NOT kubedoop-base). Uses systemd for service management. Published to test registry (quay.io/zncdatadev-test/).

## Build
- Command: `make krb5-build`
- Base image: quay.io/rockylinux/rockylinux:9 (standalone, NOT kubedoop-base)
- Build approach: Installs the pinned Rocky krb5-server, krb5-server-ldap and krb5-workstation packages. Preserves default systemd PID 1 and container-krb5.target. krb5-setup initializes only absent databases and parses all realm/domain/password options. Includes minimal-fedora-37.patch for systemd tuning. Standalone Tini 0.19.0 binaries have per-architecture SHA256 checks; Tini is only used in explicit --foreground/--exec modes.

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
- `kubedoop/bin/` and `kubedoop/lib/` — private root-owned runtime under /usr/local/libexec/kubedoop-krb5; hooks under /kubedoop/mount
- `kubedoop-lifecycle.service` — systemd reverse-stop ordering places post-hooks after krb5kdc/kadmin; default STOPSIGNAL SIGRTMIN+3
- `tests/` — source, generic image and real KDC/systemd lifecycle suites; each native CI leg runs all three after the original build

## Verification

Build the full original krb5 target, never substitute a prebuilt product image.
Run source-entrypoint-framework.sh as user and root, then image-entrypoint-framework.sh
and image-kerberos.sh against that exact image. The latter needs a Docker daemon
capable of a privileged **private-cgroup** systemd test container; do not alter
host daemon configuration or mount the host cgroup hierarchy. It checks native
ticket issuance, administrative RPC, persisted principals across nine same-CID
starts/stops and pre/post ordering in default systemd and foreground modes.
No test publishes images or exposes host ports. Only test-owned containers,
anonymous volumes and derived fixture tags are removed.

## Network & Storage
- Exposes: ports 88/tcp, 88/udp, 464/tcp, 464/udp, 749
- Volumes: /tmp, /run, /data
