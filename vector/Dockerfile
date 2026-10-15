# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


## stage: builder
FROM zncdatadev/image/kubedoop-base AS vector-builder

ARG PRODUCT_VERSION
ARG INOTIFY_TOOLS_VERSION
ARG GOMPLATE_VERSION

RUN <<EOF
    microdnf update
    microdnf install \
        autoconf \
        automake \
        gcc-c++ \
        gzip \
        libtool \
        tar \
        xz
    microdnf clean all
    rm -rf /var/cache/yum
EOF

WORKDIR /build

RUN <<EOF
    ARCH=$(uname -m)
    ARCH="${ARCH/amd64/x86_64}"
    ARCH="${ARCH/arm64/aarch64}"

    mkdir -p vector
    pushd vector

    # https://packages.timber.io/vector/0.42.0/vector-0.42.0-1.aarch64.rpm
    curl -sSfL --proto '=https' --tlsv1.2 \
        -o vector-${PRODUCT_VERSION}-1.${ARCH}.rpm \
        https://packages.timber.io/vector/${PRODUCT_VERSION}/vector-${PRODUCT_VERSION}-1.${ARCH}.rpm
    popd
EOF

# smoke test
RUN test -f /build/vector/vector-${PRODUCT_VERSION}-1.*.rpm

# build inotify-tools
RUN <<EOF
    set -euo pipefail
    mkdir -p /build/inotify-tools
    pushd /build/inotify-tools
    curl -sSfL \
        https://github.com/inotify-tools/inotify-tools/archive/refs/tags/${INOTIFY_TOOLS_VERSION}.tar.gz | \
        tar xzf - --strip-components=1
    ./autogen.sh
    ./configure --prefix=/usr/local/inotify-tools
    make -j$(nproc)
    make install
    popd

    # smoke test
    test -x /usr/local/inotify-tools/bin/inotifywait

    # cleanup source
    rm -rf /build/inotify-tools
EOF

# download gomplate
RUN <<EOF
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

    curl -sSfL --proto '=https' --tlsv1.2 \
        -o /usr/local/bin/gomplate \
        https://github.com/hairyhenderson/gomplate/releases/download/v${GOMPLATE_VERSION}/gomplate_${OS}-${ARCH}
    chmod +x /usr/local/bin/gomplate

    # smoke test
    gomplate --version
EOF


## stage: tini-downloader
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

## stage: final
FROM zncdatadev/image/kubedoop-base

COPY --from=vector-builder /build/vector /tmp/vector
COPY --from=vector-builder /usr/local/inotify-tools /usr/local/inotify-tools
COPY --from=vector-builder /usr/local/bin/gomplate /usr/local/bin/gomplate

# setup inotify-tools
RUN ln -s /usr/local/inotify-tools/bin/inotifywait /usr/local/bin/inotifywait \
    && ln -s /usr/local/inotify-tools/bin/inotifywatch /usr/local/bin/inotifywatch \
    && rpm -ivh /tmp/vector/*.rpm \
    && rm -rf /tmp/vector

RUN microdnf install util-linux-core && microdnf clean all
COPY --from=tini-downloader /tmp/tini /usr/bin/tini
# A base image must not share helper paths with product-specific entrypoints.
COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-vector/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-vector \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

# Preserve inherited root USER and /bin/bash CMD; Vector starts only on request.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-vector/bin/entrypoint.sh"]
CMD ["/bin/bash"]
