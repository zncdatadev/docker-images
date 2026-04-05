# Superset Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache Superset data visualization and BI platform. Python-based build (not Java like most products in this repo). Uses a Python venv with superset and many extras.

## Build Details
- Build command: `make superset-build`
- Build stages: (1) superset-builder creates Python venv with superset + extras, (2) statsd-exporter-builder compiles statsd-exporter from Go source, (3) final runtime stage
- Build system: Python pip + Go (statsd-exporter)
- Base images: vector (builder) → vector (runtime)

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | Superset version (list: 4.0.2, 4.1.1, 4.1.2) |
| python | Python version for venv |
| vector | Vector image version (base) |
| statsd-exporter | StatsD exporter version |
| authlib | authlib version |

## Kubedoop Customizations
### Patches
- NONE
### JMX Configuration
- NONE (Python product, not JVM-based)
### Custom Scripts
- `kubedoop/bin/entrypoint.sh` — runs gunicorn with configurable env vars: SUPERSET_BIND_ADDRESS, SUPERSET_PORT, SERVER_WORKER_AMOUNT, SERVER_WORKER_CLASS, SERVER_THREADS_AMOUNT, GUNICORN_TIMEOUT, GUNICORN_KEEPALIVE, WORKER_MAX_REQUESTS, WORKER_MAX_REQUESTS_JITTER, SERVER_LIMIT_REQUEST_LINE, SERVER_LIMIT_REQUEST_FIELD_SIZE

## Dependencies
- Uses at build time: vector (builder stage)
- Uses at runtime: vector
- Used by: none

## Key Files
- `Dockerfile` — Python venv build, gevent pin removal, statsd-exporter Go build
- `kubedoop/bin/entrypoint.sh` — gunicorn entrypoint with env-configurable parameters
- `kubedoop/requirements/{version}/base.txt` — pip constraints per Superset version (4.0.2, 4.1.1, 4.1.2)
- `versions.yaml` — version specifications

## Extras
- Removes gevent pin from constraints: `sed -i '/^gevent==.*$/d' base.txt`
- Installs extras: psycopg2-binary, pydruid, python-json-logger, python-ldap, statsd, trino[sqlalchemy], Flask-OIDC==2.2.0, Flask-OpenID==1.3.1, authlib==${AUTHLIB_VERSION}
- Only product using authlib explicitly
- Exposes port 8088 (SUPERSET_PORT)
