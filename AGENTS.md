# Kubedoop Container Images

Container images for the Kubedoop data platform — a monorepo with 20 independent OCI images sharing common build infrastructure.

## Architecture Overview

- **Monorepo**: 20 independent container images, each in its own directory
- **Shared build infrastructure**: `Makefile`, `.scripts/build.sh`, `bakefile.json`
- **CI**: Per-product GitHub Actions workflow in `.github/workflows/`
- **Global paths**: Changes to `.github/`, `.scripts/` trigger all product rebuilds (see `project.yaml`)

## Image Dependency Chain

```
ubi9/ubi-minimal (Red Hat)
  └── kubedoop-base (creates kubedoop user uid=1001, minimal utils)
      ├── go-devel (Go SDK)
      ├── java-devel (JDK + Maven + build tools)
      ├── tools (jq, yq, kubectl)
      ├── helloworld (smoke test)
      ├── vector (log collector + inotify-tools + gomplate)
      │   ├── java-base (JRE runtime + Log4Shell mitigation)
      │   │   └── dolphinscheduler
      │   ├── airflow (Python + git-sync from go-devel)
      │   └── superset (Python + statsd-exporter)
      └── hadoop (builds from source + protobuf)
          ├── hbase (largest Dockerfile, operator-tools)
          ├── hive (metastore only)
          └── spark-k8s (PySpark + Hadoop JARs, uses gradle:8 externally)

Standalone (not based on kubedoop-base):
  ├── krb5 (Rocky Linux + systemd, Kerberos KDC test server)
  └── testing-tools (Debian Python, integration test utilities)
```

Cross-dependencies:
- airflow additionally uses `go-devel` for git-sync build stage
- spark-k8s additionally uses `gradle:8` external image for jackson-dataformat-xml

## Build System

- Build all: `make build`
- Build one: `make {product}-build` (e.g., `make hadoop-build`, `make spark-build`)
- Build config: `bakefile.json` defines multi-arch bake targets
- Version spec: each product's `versions.yaml`
- CI: `.github/workflows/build_{product}.yaml` per product

**Note**: Makefile target names follow `{product}-build` pattern. `spark-k8s` uses target `spark-build`.

## Common Patterns

- **Java products**: build with `java-devel`, runtime with `java-base`
- **Python products** (airflow, superset): runtime uses `vector` base, install via pip in venv
- **Products with kubedoop/ dirs** have: patches, JMX configs, and/or custom scripts
- **Patches**: applied via `kubedoop/patches/apply_patches.sh` (most products) or `kubedoop/apply_patches.sh` (nifi)
- **JMX exporter**: included in hadoop, hbase, hive, kafka, spark-k8s, trino, zookeeper (NOT in nifi)
- **Log4Shell patches**: applied to built JARs in hadoop, kafka, trino, zookeeper
- **Log4Shell env var** (`LOG4J_FORMAT_MSG_NO_LOOKUPS=true`): set in java-base, java-devel
- **oauth2-proxy**: included in hadoop, hbase, spark-k8s only
- **async-profiler**: included in hadoop, hbase only
- **statsd-exporter**: built from Go in airflow, superset

## Product Index

| Product | Category | Base Image | Build Command | Tier |
|---------|----------|------------|---------------|------|
| kubedoop-base | infra | ubi9-minimal | `make kubedoop-base-build` | 2 |
| vector | infra | kubedoop-base | `make vector-build` | 2 |
| helloworld | infra | kubedoop-base | `make helloworld-build` | 3 |
| java-base | devel | vector | `make java-base-build` | 2 |
| java-devel | devel | kubedoop-base | `make java-devel-build` | 2 |
| go-devel | devel | kubedoop-base | `make go-devel-build` | 2 |
| krb5 | tools | rockylinux:9 | `make krb5-build` | 2 |
| tools | tools | kubedoop-base | `make tools-build` | 2 |
| testing-tools | tools | python:3.12-slim-bullseye | `make testing-tools-build` | 2 |
| airflow | app | vector | `make airflow-build` | 1 |
| superset | app | vector | `make superset-build` | 1 |
| dolphinscheduler | app | java-base | `make dolphinscheduler-build` | 2 |
| kafka | app | java-base | `make kafka-build` | 1 |
| trino | app | java-base | `make trino-build` | 1 |
| zookeeper | app | java-base | `make zookeeper-build` | 1 |
| hadoop | app | java-base | `make hadoop-build` | 1 |
| hive | app | java-base | `make hive-build` | 1 |
| hbase | app | java-base | `make hbase-build` | 1 |
| spark-k8s | app | java-base | `make spark-build` | 1 |
| nifi | app | java-base | `make nifi-build` | 1 |

## Version Management

- Each product has `versions.yaml` with product version and dependency versions
- `project.yaml` declares all 20 products in dependency order
- CI: `.github/workflows/` has per-product workflow
- Global paths: changes to `.github/`, `.scripts/` trigger all product rebuilds

## When to Update AGENTS.md

- **Adding a new product**: Create AGENTS.md in the new directory, add to Product Index above, update dependency chain
- **Changing versions.yaml structure**: Update the version schema description in the product's AGENTS.md
- **Adding/removing patches**: Update the patches summary in Tier 1 AGENTS.md
- **Changing Dockerfile build stages**: Update the build details section
- **Adding new kubedoop/ content**: May upgrade product from Tier 2 to Tier 1
