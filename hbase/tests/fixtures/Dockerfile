ARG IMAGE
FROM ${IMAGE}
USER root
COPY hbase-site.xml /kubedoop/run/test-config/hbase-site.xml
COPY 10-prepare.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-prepare.sh /kubedoop/mount/post-script/10-check-stopped.sh
ENV HBASE_CONF_DIR=/kubedoop/run/conf HBASE_LOG_DIR=/kubedoop/run/logs HBASE_PID_DIR=/kubedoop/run/pids HBASE_HEAPSIZE=512 HBASE_OPTS="-XX:ActiveProcessorCount=2"
USER kubedoop
