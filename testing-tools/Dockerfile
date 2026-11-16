# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM eclipse-temurin:11-jdk-jammy AS java11

FROM python:3.13-slim-bookworm

ARG PRODUCT_VERSION
ARG KEYCLOAK_VERSION
ARG TARGETARCH

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

COPY --from=java11 /opt/java/openjdk /usr/lib/jvm/java-11-openjdk-${TARGETARCH}

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
        openjdk-17-jre-headless

    # Bookworm no longer packages OpenJDK 11. Keep Java 11 as the default,
    # and use the Debian-managed truststore for both Java runtimes.
    JAVA_11_HOME=/usr/lib/jvm/java-11-openjdk-${TARGETARCH}
    for java_tool in "${JAVA_11_HOME}"/bin/*; do
        [ -f "$java_tool" ] && [ -x "$java_tool" ] || continue
        name=${java_tool##*/}
        update-alternatives --install "/usr/bin/${name}" "$name" "$java_tool" 1100
        update-alternatives --set "$name" "$java_tool"
    done
    update-alternatives --install /usr/bin/jexec jexec "${JAVA_11_HOME}/lib/jexec" 1100
    update-alternatives --set jexec "${JAVA_11_HOME}/lib/jexec"
    ln -sf /etc/ssl/certs/java/cacerts "${JAVA_11_HOME}/lib/security/cacerts"
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

WORKDIR /kubedoop
