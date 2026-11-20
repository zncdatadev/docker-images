# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

FROM docker.io/library/gradle:8 AS gradle-builder

ARG JACKSON_DATAFORMAT_XML_VERSION

WORKDIR /build

RUN <<EOT
    cat > build.gradle <<EOF
apply plugin: 'base'

repositories {
    mavenLocal()
    mavenCentral()
}

configurations {
    toCopy
}

dependencies {
    toCopy 'com.fasterxml.jackson.dataformat:jackson-dataformat-xml:${JACKSON_DATAFORMAT_XML_VERSION}'
}

task download(type: Copy) {
    from configurations.toCopy
    into '/jars'
}

EOF

    # show dependencies graph
    gradle --no-daemon dependencies

    # download dependencies
    gradle download --no-daemon

    # cleanup cache
    rm -rf /root/.gradle
EOT


## stage: spark-builder
FROM zncdatadev/image/hadoop AS hadoop


# ## stage: spark-builder
# FROM zncdatadev/image/hbase AS hbase


## stage: spark-builder
FROM zncdatadev/image/java-devel AS spark-builder

ARG PRODUCT_VERSION
ARG HADOOP_VERSION
ARG JMX_EXPORTER_VERSION
ARG OAUTH2_PROXY_VERSION

WORKDIR /build

# setup jmx_exporter
COPY kubedoop/jmx/config /kubedoop/jmx
RUN <<EOF
    curl -sSfL \
        https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
        -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

    ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar
EOF

# build spark
RUN <<EOF
    mkdir -p /build/spark-src
    pushd /build/spark-src
    curl -sSfL \
        https://github.com/apache/spark/archive/refs/tags/v${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    ./dev/make-distribution.sh \
        -Dhadoop.version=${HADOOP_VERSION} \
        -Dmaven.javadoc.skip=true \
        -DskipTests \
        -Phadoop-3 \
        -Pkubernetes \
        -Phive \
        -Phive-thriftserver

    cp -r dist /kubedoop/spark-${PRODUCT_VERSION}

    ln -s /kubedoop/spark-${PRODUCT_VERSION} /kubedoop/spark
    ln -s /kubedoop/spark/jars/spark-examples_*.jar /kubedoop/spark/examples.jar
    popd

    # cleanup cache
    rm -rf /root/.m2
EOF

# smoke test
RUN SPARK_HOME=/kubedoop/spark /kubedoop/spark/bin/spark-shell --version

COPY --from=hadoop \
    /kubedoop/hadoop/share/hadoop/tools/lib/hadoop-aws-*.jar \
    /kubedoop/hadoop/share/hadoop/tools/lib/bundle-*.jar \
    /kubedoop/spark/jars/

COPY --from=hadoop \
    /kubedoop/hadoop/share/hadoop/tools/lib/hadoop-azure-*.jar \
    /kubedoop/hadoop/share/hadoop/tools/lib/azure-storage-*.jar \
    /kubedoop/hadoop/share/hadoop/tools/lib/azure-keyvault-core-*.jar \
    /kubedoop/spark/jars/

# COPY --from=hbase \
#     /kubedoop/hbase/lib/shaded-clients/hbase-shared-client-byo-hadoop-*.jar \
#     /kubedoop/hbase/lib/shaded-clients/hbase-shared-mapreduce-*.jar \
#     /kubedoop/spark/jars/

# COPY --from=hbase \
#     /kubedoop/hbase/lib/client-facing-thirdparty/opentelemetry-api-*.jar \
#     /kubedoop/hbase/lib/client-facing-thirdparty/opentelemetry-context-*.jar \
#     /kubedoop/hbase/lib/client-facing-thirdparty/opentelemetry-semconv-*.jar \
#     /kubedoop/spark/jars/

# Fix the issue where log4j-slf4j-impl is missing when adding external JARs on top of the Spark base,
# which causes logging output to fail
RUN <<EOF
    # Download log4j-slf4j-impl-x.x.x.jar containing the StaticLoggerBinder
    # which is required by the connector.
    # Spark contains only log4j-slf4j2-impl-x.x.x.jar but excludes
    # log4j-slf4j-impl-x.x.x.jar. It is okay to have both JARs in the
    # classpath as long as they have the same version.
    mvn --quiet --non-recursive --no-transfer-progress --batch-mode --file /build/spark-src/pom.xml \
        dependency:copy \
        -Dartifact=org.apache.logging.log4j:log4j-slf4j-impl:'${log4j.version}' \
        -DoutputDirectory=/kubedoop/spark/jars
EOF

# download extra-jars
COPY --from=gradle-builder /jars /kubedoop/spark/extra-jars

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
EOF

# smoke test
RUN /kubedoop/oauth2-proxy/oauth2-proxy --version


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
ARG PYTHON_VERSION

RUN <<EOF
    set -e
    microdnf update
    microdnf install \
        procps \
        util-linux-core \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-pip \
        java-${JAVA_VERSION}-openjdk-devel \
        zip

    microdnf clean all
    rm -rf /var/cache/yum

    ln -s /usr/bin/python${PYTHON_VERSION} /usr/bin/python
    ln -s /usr/bin/pip-${PYTHON_VERSION} /usr/bin/pip
EOF

COPY --from=spark-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/ /kubedoop/bin/
RUN chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/bin /kubedoop/lib \
    && chmod -R 0755 /kubedoop/bin /kubedoop/lib \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

ENV SPARK_HOME=/kubedoop/spark
ENV PATH="${SPARK_HOME}/bin:${PATH}" \
    PYSPARK_PYTHON=/usr/bin/python \
    PYTHONPATH="${SPARK_HOME}/python"

WORKDIR /kubedoop/spark

USER kubedoop
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh", "/kubedoop/bin/run-spark"]
CMD ["spark-submit", "--help"]
