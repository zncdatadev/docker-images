# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


## stage: airflow-builder
FROM zncdatadev/image/vector AS airflow-builder

ARG PRODUCT_VERSION
ARG PYTHON_VERSION

RUN <<EOF
    microdnf update
    microdnf install \
        cyrus-sasl-devel \
        gcc \
        gcc-c++ \
        jq \
        libffi-devel \
        libpq-devel \
        make \
        openldap-devel \
        openssl-devel \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-devel \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-wheel

    microdnf clean all
    rm -rf /var/cache/yum
EOF

WORKDIR /kubedoop

COPY kubedoop/requirements/${PRODUCT_VERSION}/ /tmp/requirements/

RUN <<EOF
    set -ex
    python${PYTHON_VERSION} -m venv app
    source app/bin/activate
    pip install --upgrade --no-cache-dir pip setuptools wheel

    # join extras from `airflow-extras.txt` into a comma-separated list
    AIRFLOW_EXTRAS=$(tr '\n' ',' < /tmp/requirements/airflow-extras.txt | sed 's/,$//')

    pip install --no-cache-dir apache-airflow[${AIRFLOW_EXTRAS}]==${PRODUCT_VERSION} --constraint /tmp/requirements/constraints.txt

    pip install --no-cache-dir s3fs==2024.9.0 Flask_OIDC==2.2.0 Flask-OpenID==1.3.1

    ls -alh /kubedoop/app/bin
    /kubedoop/app/bin/pip --version
    /kubedoop/app/bin/pip list

    # smoke test
    /kubedoop/app/bin/airflow version | grep -q ${PRODUCT_VERSION}
EOF


## stage: statsd exporter
FROM zncdatadev/image/vector AS statsd-exporter-builder

ARG STATSD_EXPORTER_VERSION

WORKDIR /build

RUN <<EOF
    microdnf update
    microdnf install \
        golang \
        gzip \
        tar \
        xz

    microdnf clean all
    rm -rf /var/cache/yum
EOF

# download and build statsd-exporter
RUN <<EOF
    mkdir -p /build/statsd-exporter-src
    pushd /build/statsd-exporter-src
    curl -sSfL \
        https://github.com/prometheus/statsd_exporter/archive/refs/tags/v${STATSD_EXPORTER_VERSION}.tar.gz \
        | tar xzf - --strip-components=1

    go build -o /kubedoop/bin/statsd-exporter
    popd



    # cleanup source
    rm -rf /build/statsd-exporter-src

    # cleanup cache
    go clean -modcache
    rm -rf /root/.cache/go-build

    # smoke test
    /kubedoop/bin/statsd-exporter --version
EOF


# stage: git-sync-builder
FROM zncdatadev/image/go-devel AS git-sync-builder

ARG GIT_SYNC_VERSION

WORKDIR /build

RUN <<EOF
    mkdir -p /build/git-sync-src
    pushd /build/git-sync-src
    # https://github.com/kubernetes/git-sync/archive/refs/tags/v4.4.0.tar.gz
    curl -sSfL \
        https://github.com/kubernetes/git-sync/archive/refs/tags/v${GIT_SYNC_VERSION}.tar.gz \
        | tar xzf - --strip-components=1

    export OS=$(go env GOOS)
    export ARCH=$(go env GOARCH)
    export GOBIN=$(pwd)/bin
    export VERSION=${GIT_SYNC_VERSION}

    ./build/build.sh

    mkdir -p /kubedoop/bin
    mv bin/git-sync /kubedoop/bin
    popd

    # cleanup source
    rm -rf /build/git-sync-src

    # cleanup cache
    go clean -modcache
    rm -rf /root/.cache/go-build

    # smoke test
    /kubedoop/bin/git-sync --version
EOF


# stage: tini-downloader
FROM zncdatadev/image/vector AS tini-downloader
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

# stage: final
FROM zncdatadev/image/vector

ARG PRODUCT_VERSION
ARG PYTHON_VERSION

RUN <<EOF
    microdnf update
    microdnf install \
        cyrus-sasl \
        libstdc++ \
        libpq \
        make \
        openldap \
        openldap-clients \
        openssh-clients \
        openssl \
        openssl-libs \
        openssl-pkcs11 \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-pip \
        socat \
        unixODBC
    microdnf install util-linux-core

    microdnf clean all
    rm -rf /var/cache/yum
EOF

COPY --from=airflow-builder --chown=kubedoop:kubedoop /kubedoop /kubedoop
COPY --from=statsd-exporter-builder --chown=kubedoop:kubedoop /kubedoop/bin/statsd-exporter /kubedoop/bin/statsd-exporter
COPY --from=git-sync-builder --chown=kubedoop:kubedoop /kubedoop/bin/git-sync /kubedoop/bin/git-sync

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/bin/ /kubedoop/bin/
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/bin /kubedoop/lib \
    && chmod -R 0755 /kubedoop/bin /kubedoop/lib \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run /kubedoop/airflow \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run /kubedoop/airflow && chmod 1775 /kubedoop/run

ENV VIRTUAL_ENV=/kubedoop/app
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    AIRFLOW_HOME=/kubedoop/airflow

WORKDIR /kubedoop

USER kubedoop

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh", "/kubedoop/bin/run-airflow"]
CMD ["airflow", "--help"]
