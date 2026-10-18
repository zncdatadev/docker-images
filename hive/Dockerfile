# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


## stage: hive-builder
FROM zncdatadev/image/java-devel AS hive-builder

ARG PRODUCT_VERSION
ARG JMX_EXPORTER_VERSION

WORKDIR /build

COPY kubedoop/jmx/config /kubedoop/jmx

# setup jmx_exporter
RUN <<EOF
    # check JMX_EXPORTER_VERSION
    if [ -n "${JMX_EXPORTER_VERSION}" ]; then
        curl -sSfL \
            https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
            -o /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar

        ln -s /kubedoop/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /kubedoop/jmx/jmx_prometheus_javaagent.jar
    else
        echo "JMX_EXPORTER_VERSION is not set"
    fi
EOF

COPY kubedoop/patches/ /build/patches/

RUN --mount=type=cache,target=/root/.m2 <<EOF
    set -ex
    mkdir -p /build/hive-src
    pushd /build/hive-src
    curl -sSfL \
        https://github.com/apache/hive/archive/refs/tags/rel/release-${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    /build/patches/apply_patches.sh /build/patches/${PRODUCT_VERSION}

    # When the version is less than 4.0.0, we need to build the standalone-metastore
    if [ "$(printf '%s\n' "4.0.0" "${PRODUCT_VERSION}" | sort -V | head -n1)" != "4.0.0" ]; then
        mvn --no-transfer-progress clean package -DskipTests --projects standalone-metastore
        cp -r standalone-metastore/target/apache-hive-metastore-${PRODUCT_VERSION}-bin/apache-hive-metastore-${PRODUCT_VERSION}-bin /kubedoop/
    else
        # https://issues.apache.org/jira/browse/HIVE-20451
        mvn --no-transfer-progress clean package -DskipTests --projects standalone-metastore
        tar -xzf standalone-metastore/target/apache-hive-standalone-metastore-${PRODUCT_VERSION}-src.tar.gz -C /build
        pushd /build/apache-hive-standalone-metastore-${PRODUCT_VERSION}-src

        mvn --batch-mode --no-transfer-progress clean package -DskipTests --projects metastore-server
        tar -xf metastore-server/target/apache-hive-standalone-metastore-server-${PRODUCT_VERSION}-bin.tar.gz -C /kubedoop
        # unarchive to /kubedoop/apache-hive-metastore-${PRODUCT_VERSION}-bin
        popd
    fi

    ln -s /kubedoop/apache-hive-metastore-${PRODUCT_VERSION}-bin /kubedoop/hive-metastore
    popd

    # cleanup source
    rm -rf /build/hive-src
EOF

COPY kubedoop/bin/start-metastore /kubedoop/hive-metastore/bin/

# smoke test
RUN /kubedoop/hive-metastore/bin/start-metastore --help


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

## stage: hadoop
FROM zncdatadev/image/hadoop AS hadoop


## stage: final
FROM zncdatadev/image/java-base

ARG PRODUCT_VERSION
ARG HADOOP_VERSION

RUN microdnf install util-linux-core \
    && microdnf clean all

WORKDIR /kubedoop

COPY --from=hive-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/
# When start the hive-metastore, it will try to load the hadoop configuration from the classpath.
COPY --from=hadoop --chown=kubedoop:kubedoop /kubedoop/hadoop-${HADOOP_VERSION} /kubedoop/hadoop-${HADOOP_VERSION}

RUN <<EOF
    set -e
    # Hive 4.0.0 ships the schema tool in tools.schematool but its launcher
    # still points at tools.MetastoreSchemaTool. Match the 4.0.1 launcher.
    if [ "${PRODUCT_VERSION}" = "4.0.0" ]; then
        schema_tool=/kubedoop/hive-metastore/bin/ext/schemaTool.sh
        grep -Fxq '  CLASS=org.apache.hadoop.hive.metastore.tools.MetastoreSchemaTool' "${schema_tool}"
        sed -i 's/org.apache.hadoop.hive.metastore.tools.MetastoreSchemaTool/org.apache.hadoop.hive.metastore.tools.schematool.MetastoreSchemaTool/' "${schema_tool}"
    fi
    ln -s /kubedoop/hadoop-${HADOOP_VERSION} /kubedoop/hadoop
    find /kubedoop/hadoop/share/ -name *.jar | grep 'aws\|azure' | xargs -I {} ln -s {} /kubedoop/hive-metastore/lib/
EOF

ENV HADOOP_HOME=/kubedoop/hadoop \
    HIVE_HOME=/kubedoop/hive-metastore
ENV PATH="${PATH}:${HIVE_HOME}/bin:${HADOOP_HOME}/bin" \
    HADOOP_YARN_HOME="${HADOOP_HOME}" \
    HADOOP_MAPRED_HOME="${HADOOP_HOME}"

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

USER kubedoop

WORKDIR /kubedoop/hive-metastore

# smoke test
RUN base --service metastore --help || [ $? -eq 1 ]
RUN if [ "${PRODUCT_VERSION}" = "4.0.0" ]; then base --service schemaTool -dbType derby -help; fi

ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["base", "--service", "metastore"]
