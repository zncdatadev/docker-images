# Helloworld Container
<!-- Parent: ../AGENTS.md -->

## Overview
Trivial smoke test container that echoes "Hello, World!". Used to verify the build system works end-to-end.

## Build
- Command: `make helloworld-build`
- Base image: kubedoop-base

## Key Files
- `Dockerfile` — minimal echo command
- `versions.yaml` — version specifications

## Process Management
- Preserve the build-time hello and inherited runtime root identity and Bash CMD.
- Tini0.19.0 checksums are pinned per native architecture. Runtime helpers live
  under `/usr/local/libexec/kubedoop-helloworld` and remain root-owned.
- Universal root-owned pre/post hooks, owned foreground process group shutdown,
  bounded TERM/KILL escalation, stdin/status retention and stderr diagnostics.
- `tests/` exercises actual default Bash execution and explicit hello under root
  and kubedoop, plus generic lifecycle and root/source regressions.
