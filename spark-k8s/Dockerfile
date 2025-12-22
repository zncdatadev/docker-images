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



    # cleanup source
    rm -rf /build/spark-src

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


## stage: final
FROM zncdatadev/image/java-base

ARG PRODUCT_VERSION
ARG PYTHON_VERSION

RUN <<EOF
    set -e
    microdnf update
    microdnf install \
        procps \
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

ENV SPARK_HOME=/kubedoop/spark
ENV PATH="${SPARK_HOME}/bin:${PATH}" \
    PYSPARK_PYTHON=/usr/bin/python \
    PYTHONPATH="${SPARK_HOME}/python"

WORKDIR /kubedoop/spark

USER kubedoop
