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

# Install init system
# tini: lightweight init, signal forwarding to direct child, zombie reaping
# Not available in UBI 9 repos — download static binary from GitHub releases
# SHA256 checksums are hardcoded in the verification step to prevent --build-arg override
ARG TARGETARCH
ADD https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH} /tmp/tini
RUN <<EOF
    set -e
    case "${TARGETARCH}" in
        arm64)  expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        amd64)  expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        *)      echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    mv /tmp/tini /usr/bin/tini
    chmod +x /usr/bin/tini
EOF

# Deploy universal entrypoint framework
# Framework files: root-owned, world-readable/executable, NOT writable by kubedoop
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chmod -R 0755 /kubedoop/lib/ /kubedoop/bin/ \
    && mkdir -p /kubedoop/mount/{pre-script,post-script} \
    && chown -R root:root /kubedoop/mount/ \
    && mkdir -p /kubedoop/run \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run

# Security requirements for derived images and pods:
# - runAsNonRoot: true (or runAsUser: 1001)
# - readOnlyRootFilesystem: true (with /kubedoop/run as emptyDir)
# - allowPrivilegeEscalation: false
# - Runtime script injection: only ConfigMap/projected volumes in /kubedoop/mount/
USER 1001

# Init process as PID 1
# No -g flag: tini forwards signals only to direct child process.
# The entrypoint.sh manages signal propagation explicitly via trap.
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
