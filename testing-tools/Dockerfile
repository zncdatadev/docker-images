# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM python:3.12-slim-bullseye

ARG PRODUCT_VERSION
ARG KEYCLOAK_VERSION
ARG TARGETARCH

# Disable interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
    groupadd --gid 1000 --system kubedoop
    useradd \
        --system \
        --gid 1000 \
        --uid 1000 \
        --create-home \
        --home-dir /kubedoop \
        kubedoop
EOF

COPY build/debian-bullseye.list /etc/apt/sources.list
RUN <<EOF
    set -eu
    # Bullseye is archived. Do not retain an active Debian deb822 source too.
    rm -f /etc/apt/sources.list.d/debian.sources
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
        procps \
        tar \
        util-linux \
        findutils \
        zip \
        unzip \
        openjdk-11-jdk-headless \
        openjdk-17-jre-headless
    # Keep the existing general-purpose Java11 default; Keycloak CLI needs17.
    update-alternatives --set java "/usr/lib/jvm/java-11-openjdk-$(dpkg --print-architecture)/bin/java"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
EOF

COPY python/requirements.txt /kubedoop/

RUN curl -sSfL https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz | tar xzC /kubedoop && \
    ln -s /kubedoop/keycloak-${KEYCLOAK_VERSION} /kubedoop/keycloak

RUN <<EOF
    set -eu
    pip install --no-cache-dir --upgrade pip
    pip install --no-cache-dir -r /kubedoop/requirements.txt

    chown -R kubedoop:kubedoop /kubedoop
EOF

ENV PATH=$PATH:/kubedoop/keycloak/bin:/kubedoop/.local/bin \
    PRODUCT_VERSION=${PRODUCT_VERSION}

COPY python/patch-kafka3-six.py /tmp/patch-kafka3-six.py
RUN python3 /tmp/patch-kafka3-six.py && rm /tmp/patch-kafka3-six.py \
    && python3 -c 'import kafka3; from kafka3.vendor.six.moves import range; assert list(range(2)) == [0, 1]'

RUN <<EOF
    set -e
    curl -sSfL -o /usr/bin/tini "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /usr/bin/tini" | sha256sum -c
    chmod 0755 /usr/bin/tini
EOF

COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-testing-tools/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-testing-tools \
    && ln -s /usr/local/libexec/kubedoop-testing-tools/bin/keycloak-cli.sh /usr/local/bin/kcadm.sh \
    && ln -s /usr/local/libexec/kubedoop-testing-tools/bin/keycloak-cli.sh /usr/local/bin/kcreg.sh \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

USER kubedoop

WORKDIR /kubedoop

# Preserve the Python base image default rather than introducing a new daemon.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-testing-tools/bin/entrypoint.sh"]
CMD ["python3"]
