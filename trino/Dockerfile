# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

## stage: trino-storage-connector-builder
FROM zncdatadev/image/java-devel AS storage-connector-builder

ARG PRODUCT_VERSION
ARG STORAGE_CONNECTOR_VERSION

RUN --mount=type=cache,target=/root/.m2 <<EOF
    set -ex
    mkdir -p /build/trino-storage-src
    pushd /build/trino-storage-src
    # https://github.com/snowlift/trino-storage/archive/refs/tags/v454.tar.gz
    curl -sSfL \
        https://github.com/snowlift/trino-storage/archive/refs/tags/v${STORAGE_CONNECTOR_VERSION}.tar.gz \
        | tar xzf - --strip-components=1

    ./mvnw --no-transfer-progress versions:set -DnewVersion=${STORAGE_CONNECTOR_VERSION}
    ./mvnw --no-transfer-progress package -DskipTests -Dmaven.gitcommitid.skip=true

    # all jars artifact location: /build/trino-storage-src/target/trino-storage-451/
EOF


## stage: trino-builder
FROM zncdatadev/image/java-devel AS trino-builder

ARG PRODUCT_VERSION
ARG STORAGE_CONNECTOR_VERSION
ARG JMX_EXPORTER_VERSION

WORKDIR /build

COPY kubedoop/jmx/config /kubedoop/jmx

# setup jmx_exporter
RUN <<EOF
    curl -sSfL \
        https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
        -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

    ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar
EOF

# build trino
RUN --mount=type=cache,target=/root/.m2 <<EOF
    mkdir -p /build/trino-src
    pushd /build/trino-src
    # https://github.com/trinodb/trino/archive/refs/tags/454.tar.gz
    curl -sSfL \
        https://github.com/trinodb/trino/archive/refs/tags/${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1

    # Build trino with error checking
    echo "Starting Trino build..."
    if ! ./mvnw \
        --batch-mode \
        --no-transfer-progress \
        package \
        -DskipTests \
        -Dcheckstyle.skip \
        -Dmaven.javadoc.skip=true \
        -Dmaven.gitcommitid.skip=true \
        --projects='!docs' \
        -e ; then
        echo "ERROR: Trino build failed"
        exit 1
    fi
    echo "Trino build completed successfully"

    TRINO_SERVER_BINARY="core/trino-server/target/trino-server-${PRODUCT_VERSION}.tar.gz"
    TRINO_SERVER_HOME="/kubedoop/trino-server-${PRODUCT_VERSION}"

    if [ ! -f "${TRINO_SERVER_BINARY}" ]; then
        echo "Error: Trino server binary not found: ${TRINO_SERVER_BINARY}"
        ls -alh core/trino-server/target/
        exit 1
    fi

    tar -xzvf core/trino-server/target/trino-server-${PRODUCT_VERSION}.tar.gz -C /kubedoop || {
        echo "Error: Failed to extract Trino server binary"
        exit 1
    }

    # create symlink
    if [ ! -d "${TRINO_SERVER_HOME}" ]; then
        echo "Error: Trino server home directory not found: ${TRINO_SERVER_HOME}"
        ls -la /kubedoop/
        exit 1
    fi

    ln -sf /kubedoop/trino-server-${PRODUCT_VERSION} /kubedoop/trino-server

    cp client/trino-cli/target/trino-cli-${PRODUCT_VERSION}-executable.jar /kubedoop/trino-server/bin/trino-cli
    popd

    # cleanup source
    rm -rf /build/trino-src

    # smoke test - check if trino-cli works
    /kubedoop/trino-server/bin/trino-cli --version || {
        echo "ERROR: Trino CLI smoke test failed"
        ls -alh /kubedoop/trino-server/bin/
        exit 1
    }
    echo "Trino CLI smoke test passed"
EOF

# smoke test - enhanced with status check and error handling
RUN <<EOF
    microdnf update
    # trino launcher needs python
    microdnf install python
    microdnf clean all

    # smoke test
    echo "Running Trino launcher smoke test..."
    TRINO_SERVER_HOME="/kubedoop/trino-server/"
    LAUNCHER="${TRINO_SERVER_HOME}/bin/launcher"

    if [ ! -f "$LAUNCHER" ]; then
        echo "ERROR: Trino launcher not found at: $LAUNCHER"
        ls -la "${TRINO_SERVER_HOME}/bin/" || echo "bin directory not found"
        exit 1
    fi

    # run smoke test command
    echo "Checking Trino launcher help command..."
    if "$LAUNCHER" --help >/dev/null 2>&1; then
        echo "SUCCESS: Trino launcher help command executed successfully"
    else
        echo "ERROR: Trino launcher help command failed"
        echo "Launcher output:"
        "$LAUNCHER" --help 2>&1 || true
        exit 1
    fi
EOF

COPY --from=storage-connector-builder --chown=kubedoop:kubedoop /build/trino-storage-src/target/trino-storage-${STORAGE_CONNECTOR_VERSION} /kubedoop/trino-server/plugin/trino-storage-${STORAGE_CONNECTOR_VERSION}

# Fix log4j vulnerability
RUN <<EOF
    ARCH=$(uname -m)
    ARCH="${ARCH/amd64/x86_64}"
    ARCH="${ARCH/aarch64/arm64}"
    curl -sSfL -o /usr/local/bin/log4shell \
        https://github.com/lunasec-io/lunasec/releases/download/v1.6.1-log4shell/log4shell_1.6.1-log4shell_Linux_${ARCH}
    chmod +x /usr/local/bin/log4shell
    /usr/local/bin/log4shell patch --backup --force-patch --json hadoop-${PRODUCT_VERSION}
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

## stage: final
FROM zncdatadev/image/java-base

RUN <<EOF
    set -e
    microdnf update
    microdnf install \
        python \
        util-linux-core

    microdnf clean all
EOF

COPY --from=trino-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/

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

ENV TRINO_HOME=/kubedoop/trino-server
ENV PATH="${TRINO_HOME}/bin:${PATH}"

WORKDIR /kubedoop/trino-server
USER kubedoop

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["launcher", "run"]
