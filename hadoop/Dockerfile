# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


## stage: hadoop-builder
FROM zncdatadev/image/java-devel AS hadoop-builder

ARG PRODUCT_VERSION
ARG PROTOBUF_VERSION
ARG ASYNC_PROFILER_VERSION
ARG JMX_EXPORTER_VERSION
ARG OAUTH2_PROXY_VERSION

WORKDIR /build

# setup async-profiler
RUN <<EOF
    set -ex
    ARCH=$(uname -m)
    ARCH="${ARCH/x86_64/x64}"
    ARCH="${ARCH/amd64/x64}"
    ARCH="${ARCH/aarch64/arm64}"

    # build async-profiler
    # https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-x64.tar.gz
    curl -sSfL \
        https://github.com/async-profiler/async-profiler/releases/download/v${ASYNC_PROFILER_VERSION}/async-profiler-${ASYNC_PROFILER_VERSION}-linux-${ARCH}.tar.gz \
        | tar -zxf - -C /kubedoop

    ln -s /kubedoop/async-profiler-${ASYNC_PROFILER_VERSION}-linux-${ARCH} /kubedoop/async-profiler
EOF

COPY kubedoop/jmx/config /kubedoop/jmx

# setup jmx_exporter
RUN <<EOF
    curl -sSfL \
        https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
        -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

    ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar
EOF

# setup oauth2-proxy
RUN <<EOF
    ARCH=$(uname -m)
    ARCH="${ARCH/x86_64/amd64}"
    ARCH="${ARCH/aarch64/arm64}"

    mkdir /kubedoop/oauth2-proxy
    cd /kubedoop/oauth2-proxy

    curl -sSfL \
        https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${OAUTH2_PROXY_VERSION}/oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-${ARCH}.tar.gz \
        | tar xzf - --strip-components=1

    # smoke test
    /kubedoop/oauth2-proxy/oauth2-proxy --version
EOF

# Setup protobuf
# ref: https://github.com/apache/hadoop/blob/trunk/dev-support/docker/pkg-resolver/install-protobuf.sh
ENV PROTOBUF_HOME=/opt/protobuf
RUN <<EOF
    set -ex
    mkdir -p /build/protobuf-src
    pushd /build/protobuf-src
    PROTOBUF_LANGUAGE_VERSION=$PROTOBUF_VERSION

    if [ "$(echo -e "$PROTOBUF_VERSION\n21.12" | sort -V | head -n 1)" = "$PROTOBUF_VERSION" ]; then
        PROTOBUF_LANGUAGE_VERSION=java-$PROTOBUF_VERSION
    fi

    curl -sSfL \
        https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-${PROTOBUF_LANGUAGE_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    ./configure --prefix=${PROTOBUF_HOME}
    make -j$(nproc)
    make install
    popd

    # cleanup source
    rm -rf /build/protobuf-src

EOF

ENV PATH="${PATH}:${PROTOBUF_HOME}/bin"

# smoke test
RUN protoc --version

# Setup boost
# ref: https://github.com/apache/hadoop/blob/trunk/dev-support/docker/pkg-resolver/install-boost.sh
RUN <<EOF
    rpm --install --replacepkgs https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
    microdnf update
    microdnf install boost1.78-devel
    microdnf clean all
    rm -rf /var/cache/yum
EOF

COPY kubedoop/patches/ /build/patches/

# Setup hadoop
RUN <<EOF
    set -ex
    mkdir -p /build/hadoop-src
    pushd /build/hadoop-src
    curl -sSfL \
        https://github.com/apache/hadoop/archive/refs/tags/rel/release-${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    /build/patches/apply_patches.sh /build/patches/${PRODUCT_VERSION}
    mvn \
        --batch-mode \
        --no-transfer-progress \
        clean \
        package \
        -Pdist,native \
        -pl '!hadoop-tools/hadoop-pipes,!hadoop-yarn-project,!hadoop-mapreduce-project,!hadoop-minicluster' \
        -Drequire.fuse=true \
        -DskipTests \
        -Dmaven.javadoc.skip=true

    cp -r hadoop-dist/target/hadoop-${PRODUCT_VERSION} /kubedoop/hadoop-${PRODUCT_VERSION}
    cp hadoop-hdfs-project/hadoop-hdfs-native-client/target/main/native/fuse-dfs/fuse_dfs /kubedoop/hadoop-${PRODUCT_VERSION}/bin

    ln -s /kubedoop/hadoop-${PRODUCT_VERSION} /kubedoop/hadoop
    popd

    # cleanup source
    rm -rf /build/hadoop-src

    # cleanup cache
    rm -rf /root/.m2
EOF

# smoke test
RUN HADOOP_HOME=/kubedoop/hadoop HADOOP_YARN_HOME=/kubedoop/hadoop HADOOP_MAPRED_HOME=/kubedoop/hadoop /kubedoop/hadoop/bin/hadoop version

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
    curl -sSfL -o /tmp/tini "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod 0755 /tmp/tini
EOF

## stage: final
FROM zncdatadev/image/java-base

ARG PRODUCT_VERSION

WORKDIR /kubedoop

COPY --from=hadoop-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/
COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/bin /kubedoop/lib \
    && chmod -R 0755 /kubedoop/bin /kubedoop/lib \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

ENV HADOOP_HOME=/kubedoop/hadoop
ENV HADOOP_CONF_DIR="${HADOOP_HOME}/etc/hadoop" \
    HADOOP_YARN_HOME="${HADOOP_HOME}" \
    HADOOP_MAPRED_HOME="${HADOOP_HOME}" \
    LD_LIBRARY_PATH="${HADOOP_HOME}/lib/native:/usr/lib/jvm/jre/lib/server" \
    PATH="${PATH}:${HADOOP_HOME}/bin"

RUN cat > /etc/profile.d/hadoop.sh <<'EOF'
export CLASSPATH=${CLASSPATH}:$(hadoop classpath --glob)
EOF

USER kubedoop

# smoke test
RUN hadoop version

WORKDIR /kubedoop/hadoop
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["hdfs", "namenode"]
