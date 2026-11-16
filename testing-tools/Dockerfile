# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM python:3.12-slim-bullseye

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
    # Debian 11 is EOL; its security packages are available from the archive.
    sed -i 's|deb.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list
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
        openjdk-11-jdk-headless
    apt-get clean
    rm -rf /var/lib/apt/lists/*
EOF

COPY python/requirements.txt /kubedoop/

RUN curl -sSfL https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz | tar xzC /kubedoop && \
    ln -s /kubedoop/keycloak-${KEYCLOAK_VERSION} /kubedoop/keycloak

RUN <<EOF
    set -e
    pip install --no-cache-dir --upgrade pip
    pip install --no-cache-dir -r /kubedoop/requirements.txt

    chown -R kubedoop:kubedoop /kubedoop
EOF

ENV PATH=$PATH:/kubedoop/keycloak/bin:/kubedoop/.local/bin \
    PRODUCT_VERSION=${PRODUCT_VERSION}

USER kubedoop

WORKDIR /kubedoop
