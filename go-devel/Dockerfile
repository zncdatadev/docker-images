# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true
# Golang development environment


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

RUN <<EOF
    microdnf update
    microdnf install \
        cmake \
        cyrus-sasl-devel \
        diffutils \
        fuse-devel \
        gcc \
        gcc-c++ \
        gettext \
        git \
        gzip \
        hostname \
        krb5-devel \
        libcurl-devel \
        make \
        openssl-devel \
        pkg-config \
        tar \
        unzip \
        util-linux-core \
        wget \
        which \
        xz \
        zlib-devel \
        zip

    microdnf clean all
    rm -rf /var/cache/yum
EOF

RUN <<EOF
    set -ex
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    ARCH=${ARCH/x86_64/amd64}
    ARCH=${ARCH/aarch64/arm64}

    # go1.23.2.darwin-arm64.tar.gz
    curl -sSfL --proto '=https' --tlsv1.2 \
        https://go.dev/dl/go${PRODUCT_VERSION}.${OS}-${ARCH}.tar.gz | \
        tar xz -C /usr/local

EOF

ENV GOROOT="/usr/local/go"
ENV PATH="$PATH:$GOROOT/bin"

RUN go version

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-go-devel/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-go-devel \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

# Preserve inherited root USER, working directory and Bash CMD for the SDK.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-go-devel/bin/entrypoint.sh"]
CMD ["/bin/bash"]
