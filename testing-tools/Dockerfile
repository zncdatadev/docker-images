# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM python:3.13-slim-bookworm

ARG PRODUCT_VERSION
ARG KEYCLOAK_VERSION

# Disable interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
    set -e
    groupadd --gid 1000 --system kubedoop
    useradd \
        --system \
        --gid 1000 \
        --uid 1000 \
        --create-home \
        --home-dir /kubedoop \
        kubedoop
EOF

RUN <<EOF
    set -e
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        diffutils \
        gzip \
        jq \
        krb5-user \
        kubernetes-client \
        libkrb5-dev \
        libssl-dev \
        libxml2-dev \
        libxslt1-dev \
        openssl \
        pkg-config \
        tar \
        zip \
        unzip \
        openjdk-17-jdk-headless

    java -version
    javac -version
    apt-get clean
    rm -rf /var/lib/apt/lists/*
EOF

RUN curl -sSfL https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz | tar xzC /kubedoop && \
    ln -s /kubedoop/keycloak-${KEYCLOAK_VERSION} /kubedoop/keycloak

COPY python/requirements.txt /kubedoop/

RUN <<EOF
    set -e
    pip install --no-cache-dir --upgrade pip
    pip install --no-cache-dir -r /kubedoop/requirements.txt

    chown -R kubedoop:kubedoop /kubedoop
EOF

ENV PATH=$PATH:/kubedoop/keycloak/bin:/kubedoop/.local/bin \
    PRODUCT_VERSION=${PRODUCT_VERSION}

# kafka-python3 3.0.0 bundles six 1.11, which cannot import six.moves on
# Python 3.12+. Keep its kafka3 API while using the installed six version.
RUN <<EOF
    set -e
    python - <<'PY'
from pathlib import Path
import shutil
import sysconfig

import six

vendored_six = Path(sysconfig.get_paths()["purelib"]) / "kafka3/vendor/six.py"
shutil.copyfile(six.__file__, vendored_six)
PY
    python -c 'from kafka3 import KafkaConsumer, KafkaProducer'
EOF

USER kubedoop

# Verify both Keycloak CLI entry points with the image's default Java runtime.
RUN kcadm.sh help >/dev/null && kcreg.sh help >/dev/null

WORKDIR /kubedoop
