# Airflow Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Airflow workflow orchestration platform. Python-based (NOT Java) -- one of only two Python-centric products alongside superset. Runs in a venv with pip-installed airflow and extras.

## Build Details
- Build command: `make airflow-build`
- Build stages: (1) Python venv with airflow + extras, (2) Go-compiled statsd-exporter, (3) Go-compiled git-sync from go-devel
- Build system: Python pip + Go
- Base images: vector -> vector (runtime)

## Version Schema
See `versions.yaml` for current values. Structure:

| Field | Description |
|-------|-------------|
| product | Airflow version (3.0.1, 2.10.5, 2.10.4) |
| python | Python version for venv |
| go-devel | Go SDK version used by statsd-exporter and git-sync stages |
| git-sync | git-sync tool version (Go binary) |
| statsd-exporter | Prometheus statsd-exporter version (Go binary) |
| vector | Vector log collector base image version |

## Kubedoop Customizations
### Patches
None -- airflow builds purely from upstream PyPI packages.

### JMX Configuration
None -- monitoring uses statsd-exporter instead of JMX.

### Custom Scripts
- `bin/entrypoint.sh` -- Apache-licensed entrypoint with LD_PRELOAD libstdc++ workaround for issue #17546

### Airflow Extras
Per-version extras defined in `requirements/{version}/airflow-extras.txt` with pinned constraints in `constraints.txt`. Available versions: 2.10.4, 2.10.5, 3.0.1. Version 3.0.1 uses `-` separator in extras names, 2.10.x uses `.` separator. ~23 extras including: async, amazon, celery, cncf-kubernetes, docker, elasticsearch, ldap, trino.

## Dependencies
- Uses at build time: go-devel (git-sync build)
- Uses at runtime: vector (base image)
- Used by: none

## Key Files
- `Dockerfile` -- 3 build stages: Python venv + Go statsd-exporter + Go git-sync
- `kubedoop/bin/entrypoint.sh` -- LD_PRELOAD workaround for libstdc++ compatibility
- `kubedoop/requirements/{ver}/airflow-extras.txt` -- per-version extras list
- `kubedoop/requirements/{ver}/constraints.txt` -- per-version pip constraints
- `versions.yaml` -- version specifications
