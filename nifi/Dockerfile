# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


# stage: nifi-builder
FROM zncdatadev/image/java-devel AS nifi-builder

ARG PRODUCT_VERSION
ARG MAVEN_VERSION=3.9.8

WORKDIR /build

# Setup maven
RUN <<EOF
    set -euo pipefail
    mkdir -p /build/maven
    # Download maven binary from https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz
    curl -sSfL \
        https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
        | tar -zxf - --strip-components=1 -C /build/maven

    # Create symlink for maven
    ln -sf /build/maven/bin/mvn /usr/bin/mvn

    # smoke test
    mvn --version | grep "Apache Maven ${MAVEN_VERSION}" || exit 1
EOF

COPY kubedoop/apply_patches.sh /build/
COPY kubedoop/maven-settings.xml /build/
COPY kubedoop/patches/ /build/patches/

# Build apache nifi from github tag
RUN --mount=type=cache,target=/root/.m2 --mount=type=cache,target=/root/.npm <<EOF
    set -euo pipefail
    set -x
    mkdir -p /build/nifi-src
    pushd /build/nifi-src
    # Download apache nifi source from https://github.com/apache/nifi/releases/tag/rel%2Fnifi-1.27.0
    curl -sSfL \
        https://github.com/apache/nifi/archive/refs/tags/rel/nifi-${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1

    if [ -f /build/apply_patches.sh ] && [ -d /build/patches/${PRODUCT_VERSION} ]; then
        /build/apply_patches.sh /build/patches/${PRODUCT_VERSION}
    fi

    # Build apache nifi use mvnw
    ./mvnw \
        --settings /build/maven-settings.xml \
        clean \
        install \
        --batch-mode \
        --no-transfer-progress \
        -Dmaven.javadoc.skip=true \
        -DskipTests \
        --activate-profiles include-hadoop,include-hadoop-aws,include-hadoop-azure,include-hadoop-gcp

    # check if nifi-assembly target directory exists
    if [ ! -d nifi-assembly/target ]; then
        echo "ERROR: nifi-assembly/target directory not found"
        ls -la nifi-assembly/target || echo "nifi-assembly/target directory not found"
        exit 1
    fi
    mv nifi-assembly/target/nifi-${PRODUCT_VERSION}-bin/nifi-${PRODUCT_VERSION} /kubedoop/
    ln -s /kubedoop/nifi-${PRODUCT_VERSION} /kubedoop/nifi

    # Rm nifi docs
    rm -rf /kubedoop/nifi/docs
    popd

    # smoke test - 添加更详细的错误检查
    if [ ! -f /kubedoop/nifi/bin/nifi.sh ]; then
        echo "ERROR: nifi.sh not found"
        ls -la /kubedoop/nifi/bin/ || echo "/kubedoop/nifi/bin/ directory not found"
        exit 1
    fi

    /kubedoop/nifi/bin/nifi.sh --help || {
        echo "ERROR: nifi.sh --help failed"
        exit 1
    }

    # cleanup source
    rm -rf /build/nifi-src
EOF


## stage: tini-downloader
FROM zncdatadev/image/java-devel AS tini-downloader

ARG TARGETARCH
ARG TINI_VERSION

RUN <<EOF
    set -e
    curl -sSfL -o /tmp/tini \
        "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod +x /tmp/tini
EOF

## Final stage
FROM zncdatadev/image/java-base

RUN <<EOF
    microdnf update
    microdnf install \
        gettext \
        git \
        python3-pip \
        util-linux-core \

    microdnf clean all
    rm -rf /var/cache/yum

    pip install --no-cache-dir \
        nipyapi==0.19.1 \
        bcrypt
EOF

COPY --from=nifi-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/lib /kubedoop/bin \
    && chmod -R 0755 /kubedoop/lib/ /kubedoop/bin/ \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script \
    && chown -R root:root /kubedoop/mount/ \
    && mkdir -p /kubedoop/run \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run

ENV NIFI_HOME=/kubedoop/nifi
ENV PATH="${NIFI_HOME}/bin:${PATH}"

WORKDIR /kubedoop/nifi

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["nifi.sh", "run"]
