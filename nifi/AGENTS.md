# NiFi Container
<!-- Parent: ../AGENTS.md -->

## Overview
Apache NiFi data routing and transformation platform. The only single-version Tier 1 product. Activates cloud storage profiles (AWS, Azure, GCP) during the Maven build to include Hadoop cloud dependencies.

## Build Details
- Build command: `make nifi-build`
- Build stages: single build stage (nifi-builder) + final runtime stage
- Build system: Maven (./mvnw wrapper) + npm cache
- Base images: java-devel (builder) → java-base (runtime)

## Version Schema
See `versions.yaml` for current values. Structure:
| Field | Description |
|-------|-------------|
| product | NiFi version (e.g. 2.4.0) |
| java-base | JRE version for runtime image |
| java-devel | JDK version for builder image |

## Kubedoop Customizations
### Patches (3)
- `patches/2.4.0/` — 3 patches: no-zip-assembly, add-cyclonedx-plugin, disable-host-port-validation
### JMX Configuration
- NONE — only Tier 1 product without JMX exporter
### Custom Scripts
- `kubedoop/apply_patches.sh` — at kubedoop/ root (NOT in patches/ subdir; unique layout among products)

## Dependencies
- Uses at build time: java-devel
- Uses at runtime: java-base
- Used by: none

## Key Files
- `Dockerfile` — single build stage with Maven profiles `include-hadoop,include-hadoop-aws,include-hadoop-azure,include-hadoop-gcp`; custom Maven 3.9.8 from Apache archives; .m2 and .npm caches
- `kubedoop/apply_patches.sh` — applies .patch files from patches/ subdirectories
- `kubedoop/patches/2.4.0/` — version-specific patches
- `versions.yaml` — version specifications

## Extras
- Final image installs gettext, git, python3-pip, then pip installs nipyapi==0.19.1 + bcrypt
- Only product with nipyapi (NiFi Python API client)
- Only product with cloud storage Maven profiles
- Removes docs from final image (`rm -rf /kubedoop/nifi/docs`)
