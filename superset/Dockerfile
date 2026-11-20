# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


## stage: builder
FROM zncdatadev/image/vector AS superset-builder

ARG PRODUCT_VERSION
ARG PYTHON_VERSION
ARG AUTHLIB_VERSION

RUN <<EOF
    microdnf update
    microdnf install \
        cyrus-sasl-devel \
        gcc \
        gcc-c++ \
        make \
        openldap-devel \
        openssl-devel \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-devel \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-wheel \
        libffi-devel \
        libpq-devel

    microdnf clean all
    rm -rf /var/cache/yum
EOF

WORKDIR /kubedoop

COPY kubedoop/requirements/${PRODUCT_VERSION}/ /tmp/requirements/

RUN <<EOF
    set -ex
    python${PYTHON_VERSION} -m venv app
    source app/bin/activate
    pip install --upgrade --no-cache-dir pip setuptools==75.2.0
    # remove gevent pin to allow latest version
    sed -i '/^gevent==.*$/d' /tmp/requirements/base.txt
    pip install --no-cache-dir \
        --upgrade \
        --constraint /tmp/requirements/base.txt \
        apache-superset==${PRODUCT_VERSION} \
        psycopg2-binary \
        pydruid \
        python-json-logger \
        python-ldap \
        statsd \
        trino[sqlalchemy] \
        Flask-OIDC==2.2.0 \
        Flask-OpenID==1.3.1 \
        tzdata \
        authlib==${AUTHLIB_VERSION}
    pip install --upgrade --no-cache-dir \
        gunicorn==22.0.0 \
        python-json-logger

    # smoke test
    SUPERSET_SECRET_KEY=$(openssl rand -hex 32) FLASK_APP="superset.app:create_app()" /kubedoop/app/bin/superset version
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

    # smoke test
    /kubedoop/bin/statsd-exporter --version

    # cleanup source
    rm -rf /build/statsd-exporter-src

    # cleanup cache
    go clean -modcache
    rm -rf /root/.cache/go-build
EOF


## stage: tini-downloader
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

## stage: final
FROM zncdatadev/image/vector

ARG PRODUCT_VERSION
ARG PYTHON_VERSION

RUN <<EOF
    microdnf update
    microdnf install \
        cyrus-sasl \
        libpq \
        make \
        openssl \
        openssl-libs \
        openldap \
        openldap-clients \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-pip \
        util-linux-core

    microdnf clean all
    rm -rf /var/cache/yum
EOF

WORKDIR /kubedoop

COPY --from=statsd-exporter-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/
COPY --from=superset-builder --chown=kubedoop:kubedoop /kubedoop/app /kubedoop/app

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/bin/ /kubedoop/bin/
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/bin /kubedoop/lib \
    && chmod -R 0755 /kubedoop/bin /kubedoop/lib \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

ENV VIRTUAL_ENV=/kubedoop/app
ENV SUPERSET_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/kubedoop/app/pythonpath" \
    PATH="${VIRTUAL_ENV}/bin:$PATH" \
    SUPERSET_PORT=8088

EXPOSE ${SUPERSET_PORT}

WORKDIR /kubedoop/app

USER kubedoop

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh", "/kubedoop/bin/run-superset"]
CMD ["webserver"]
