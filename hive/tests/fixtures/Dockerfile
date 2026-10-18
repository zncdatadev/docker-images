ARG IMAGE=quay.io/zncdatadev/hive:4.0.1-kubedoop0.0.0-dev
FROM ${IMAGE} AS distribution

FROM eclipse-temurin:11-jdk AS client-builder
COPY --from=distribution /kubedoop/hive-metastore/lib/ /kubedoop/hive-metastore/lib/
COPY --from=distribution /kubedoop/hadoop/share/ /kubedoop/hadoop/share/
COPY MetastoreClient.java /build/MetastoreClient.java
RUN mkdir -p /build/classes \
    && find /kubedoop -name '*.jar' -printf '%p:' > /build/classpath \
    && javac -cp "$(cat /build/classpath)" -d /build/classes /build/MetastoreClient.java

FROM ${IMAGE}
USER root
COPY --from=client-builder /build/classes/ /kubedoop/run/client/
COPY metastore-site.xml /kubedoop/run/metastore-site.xml
COPY 10-prepare.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-prepare.sh /kubedoop/mount/post-script/10-check-stopped.sh
ENV METASTORE_CONF_DIR=/kubedoop/run/conf HADOOP_HEAPSIZE=512
ARG RUNTIME_USER=kubedoop
USER ${RUNTIME_USER}
