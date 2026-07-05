# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


# stage: zookeeper-builder
FROM zncdatadev/image/java-devel AS zookeeper-builder

ARG PRODUCT_VERSION
ARG JMX_EXPORTER_VERSION

WORKDIR /build

# setup jmx_exporter
COPY kubedoop/jmx/config /kubedoop/jmx
RUN <<EOF
    curl -sSfL \
        https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
        -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

    ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar
EOF

# build zookeeper
RUN --mount=type=cache,target=/root/.m2 <<EOF
    mkdir -p /build/zookeeper-src
    pushd /build/zookeeper-src

    SOURCE_URL="https://github.com/apache/zookeeper/archive/refs/tags/release-${PRODUCT_VERSION}.tar.gz"
    echo "Downloading zookeeper from: ${SOURCE_URL}"
    curl -sSfL $SOURCE_URL | tar xzf - --strip-components=1

    mvn --batch-mode --no-transfer-progress -pl "!zookeeper-client/zookeeper-client-c" clean install checkstyle:check spotbugs:check -DskipTests -Pfull-build

    # install zookeeper binary
    ZOOKEEPER_BINARY="zookeeper-assembly/target/apache-zookeeper-${PRODUCT_VERSION}-bin.tar.gz"
    ZOOKEEPER_HOME="/kubedoop/apache-zookeeper-${PRODUCT_VERSION}"

    if [ ! -f "${ZOOKEEPER_BINARY}" ]; then
        echo "Error: Zookeeper binary not found at ${ZOOKEEPER_BINARY}"
        ls -la $(dirname ${ZOOKEEPER_BINARY})
        exit 1
    fi

    # extract and setup zookeeper
    tar -xzf ${ZOOKEEPER_BINARY} -C /kubedoop || {
        echo "Error: Failed to extract Zookeeper binary"
        exit 1
    }

    # checkout extracted folder
    if [ ! -d "${ZOOKEEPER_HOME}-bin" ]; then
        echo "Error: Extracted Zookeeper directory not found at ${ZOOKEEPER_HOME}-bin"
        ls -la /kubedoop
        exit 1
    fi

    mv ${ZOOKEEPER_HOME}-bin ${ZOOKEEPER_HOME}
    ln -sf ${ZOOKEEPER_HOME} /kubedoop/zookeeper
    popd

    # smoke test
    /kubedoop/zookeeper/bin/zkServer.sh version

    # cleanup source
    rm -rf /build/zookeeper-src
EOF

# Fix log4j vulnerability
RUN <<EOF
    ARCH=$(uname -m)
    ARCH="${ARCH/amd64/x86_64}"
    ARCH="${ARCH/aarch64/arm64}"
    curl -sSfL -o /usr/local/bin/log4shell \
        https://github.com/lunasec-io/lunasec/releases/download/v1.6.1-log4shell/log4shell_1.6.1-log4shell_Linux_${ARCH}
    chmod +x /usr/local/bin/log4shell
    /usr/local/bin/log4shell patch --backup --force-patch --json /kubedoop/zookeeper
EOF


## final stage
FROM zncdatadev/image/java-base

ARG PRODUCT_VERSION
ARG TARGETARCH

WORKDIR /kubedoop

COPY --from=zookeeper-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/

# Install init system
# tini: lightweight init, signal forwarding to direct child, zombie reaping
# Not available in UBI 9 repos — download static binary from GitHub releases
# SHA256 checksums are hardcoded in the verification step to prevent --build-arg override
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
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script \
    && chown -R root:root /kubedoop/mount/ \
    && mkdir -p /kubedoop/run \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run

ENV ZOOKEEPER_HOME=/kubedoop/zookeeper
ENV PATH="$ZOOKEEPER_HOME/bin:$PATH"

WORKDIR /kubedoop/zookeeper

USER kubedoop

# Init process as PID 1
# No -g flag: tini forwards signals only to direct child process.
# The entrypoint.sh manages signal propagation explicitly via trap.
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["bin/zkServer.sh", "start-foreground", "config/zoo_sample.cfg"]
