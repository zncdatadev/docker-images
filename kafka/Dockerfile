# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


# stage: kafka-builder
FROM zncdatadev/image/java-devel AS kafka-builder

ARG PRODUCT_VERSION
ARG JMX_EXPORTER_VERSION
ARG SCALA_VERSION

WORKDIR /build

# setup jmx_exporter
COPY kubedoop/jmx/config /kubedoop/jmx

RUN <<EOF
    set -e
    # Download JMX Exporter from github release
    # https://github.com/prometheus/jmx_exporter/releases/download/1.4.0/jmx_prometheus_javaagent-1.4.0.jar
    curl -sSfL \
        https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
        -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

    ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar

EOF

# build kafka
# use cache locked to fix gradle concurrency lock issue https://github.com/gradle/gradle/issues/8750#issuecomment-2312378643
RUN --mount=type=cache,sharing=locked,target=/root/.gradle <<EOF
    set -ex
    mkdir -p /build/kafka-src
    pushd /build/kafka-src
    curl -sSfL \
        https://github.com/apache/kafka/archive/refs/tags/${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    ./gradlew clean releaseTarGz -x test
    tar -xzf core/build/distributions/kafka_${SCALA_VERSION}-${PRODUCT_VERSION}.tgz -C /kubedoop
    ln -s /kubedoop/kafka_${SCALA_VERSION}-${PRODUCT_VERSION} /kubedoop/kafka
    popd

    # smoke test
    /kubedoop/kafka/bin/kafka-server-start.sh --version

    # cleanup source
    rm -rf /build/kafka-src
EOF

RUN <<EOF
    set -e
    ARCH=$(uname -m)
    ARCH="${ARCH/amd64/x86_64}"
    ARCH="${ARCH/aarch64/arm64}"
    curl -sSfL -o /usr/local/bin/log4shell \
        https://github.com/lunasec-io/lunasec/releases/download/v1.6.1-log4shell/log4shell_1.6.1-log4shell_Linux_${ARCH}
    chmod +x /usr/local/bin/log4shell
    /usr/local/bin/log4shell patch --backup --force-patch --json /kubedoop/kafka
EOF


# stage: tini-downloader
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

ARG PRODUCT_VERSION

WORKDIR /kubedoop

COPY --from=kafka-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/

# Commands own a session/group, separate from the entrypoint and post-hooks.
RUN microdnf install -y util-linux-core && microdnf clean all

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown -R root:root /kubedoop/lib/ /kubedoop/bin/ \
    && chmod -R 0755 /kubedoop/lib/ /kubedoop/bin/ \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script \
    && chown -R root:root /kubedoop/mount/ \
    && mkdir -p /kubedoop/run \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run

ENV KAFKA_HOME=/kubedoop/kafka
ENV PATH="${KAFKA_HOME}/bin:${PATH}"

USER kubedoop

# smoke test
RUN kafka-server-start.sh --version

WORKDIR /kubedoop/kafka

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["kafka-server-start.sh", "config/server.properties"]
