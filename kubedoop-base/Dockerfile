# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6-1755695350
ARG TARGETARCH

COPY kubedoop/dnf.conf /etc/dnf/dnf.conf

RUN <<EOF
    set -e
    microdnf update -y
    microdnf install \
        curl-minimal \
        findutils \
        iputils \
        less \
        procps \
        tar \
        util-linux-core

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

    curl -sSfL -o /usr/bin/tini "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /usr/bin/tini" | sha256sum -c
    chmod 0755 /usr/bin/tini
EOF

ENV PATH=$PATH:/kubedoop

# Keep the inherited supervisor outside downstream legacy /kubedoop COPY trees.
COPY --chown=root:root kubedoop/bin/ /usr/local/libexec/kubedoop-base/bin/
COPY --chown=root:root kubedoop/lib/ /usr/local/libexec/kubedoop-base/lib/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-base \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

# Preserve the UBI base's root USER, working directory and Bash CMD.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-base/bin/entrypoint.sh"]
CMD ["/bin/bash"]

# https://github.com/opencontainers/image-spec/blob/main/annotations.md#pre-defined-annotation-keys
# https://specs.opencontainers.org/image-spec/annotations/#pre-defined-annotation-keys
LABEL org.opencontainers.image.authors="ZNCDataDev Team" \
    org.opencontainers.image.url="https://zncdata.dev" \
    org.opencontainers.image.vendor="ZNCDataDev" \
    org.opencontainers.image.licenses="Apache-2.0"
