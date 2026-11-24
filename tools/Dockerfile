# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM zncdatadev/image/kubedoop-base AS tini-downloader
ARG TARGETARCH
RUN <<EOF
    set -e
    curl -sSfL -o /tmp/tini "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod 0755 /tmp/tini
EOF

FROM zncdatadev/image/kubedoop-base

ARG PRODUCT_VERSION
ARG KUBECTL_VERSION
ARG JQ_VERSION
ARG YQ_VERSION

RUN <<EOF
    microdnf update

    microdnf install \
        gettext \
        gzip \
        iputils \
        openssl \
        tar \
        wget \
        zip

    microdnf clean all
    rm -rf /var/cache/yum

EOF

WORKDIR /kubedoop/bin

ENV PATH="/kubedoop/bin:${PATH}"

RUN <<EOF
    set -ex
    ARCH=$(uname -m)
    ARCH=${ARCH/x86_64/amd64}
    ARCH=${ARCH/aarch64/arm64}

    # Download jq from https://github.com/jqlang/jq/releases
    curl -sSfL \
        https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${ARCH} \
        -o /kubedoop/bin/jq
    chmod +x /kubedoop/bin/jq

    # smoke test jq installation
    jq --version || (echo "jq installation failed" && exit 1)

    # Download yq from https://github.com/mikefarah/yq/releases
    curl -sSfL \
        https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH} \
        -o /kubedoop/bin/yq
    chmod +x /kubedoop/bin/yq

    # smoke test yq installation
    yq --version || (echo "yq installation failed" && exit 1)

    # Download kubectl from https://dl.k8s.io/release
    curl -sSfL \
        https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl \
        -o /kubedoop/bin/kubectl
    chmod +x /kubedoop/bin/kubectl
    # smoke test kubectl installation
    kubectl version --client || (echo "kubectl installation failed" && exit 1)

    chown -R kubedoop:kubedoop /kubedoop
EOF

RUN microdnf install util-linux-core && microdnf clean all
COPY --from=tini-downloader /tmp/tini /usr/bin/tini
# Outside the existing user-owned tool directory and recursive application chown.
COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-tools/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-tools \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

USER kubedoop

WORKDIR /kubedoop

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-tools/bin/entrypoint.sh"]
CMD ["/bin/bash"]
