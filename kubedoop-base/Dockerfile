# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05


FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6-1755695350

COPY kubedoop/dnf.conf /etc/dnf/dnf.conf

RUN <<EOF
    microdnf update -y
    microdnf install \
        findutils \
        iputils \
        less \
        procps \
        tar

    groupadd -g 1001 --system kubedoop
    useradd \
        --no-log-init \
        --gid 1001 \
        --uid 1001 \
        --create-home \
        --home-dir /kubedoop \
        kubedoop

    microdnf clean all
    rm -rf /var/cache/yum
EOF

ENV PATH=$PATH:/kubedoop

# https://github.com/opencontainers/image-spec/blob/main/annotations.md#pre-defined-annotation-keys
# https://specs.opencontainers.org/image-spec/annotations/#pre-defined-annotation-keys
LABEL org.opencontainers.image.authors="ZNCDataDev Team" \
    org.opencontainers.image.url="https://zncdata.dev" \
    org.opencontainers.image.vendor="ZNCDataDev" \
    org.opencontainers.image.licenses="Apache-2.0"
