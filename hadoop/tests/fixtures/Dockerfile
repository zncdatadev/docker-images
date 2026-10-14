ARG IMAGE
FROM ${IMAGE}
USER root
COPY core-site.xml hdfs-site.xml /kubedoop/run/test-config/
COPY 10-prepare.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-prepare.sh /kubedoop/mount/post-script/10-check-stopped.sh
ENV HADOOP_CONF_DIR=/kubedoop/run/conf HADOOP_PID_DIR=/kubedoop/run/pids \
    HADOOP_LOG_DIR=/kubedoop/run/logs HADOOP_HEAPSIZE_MAX=256 \
    HADOOP_OPTS="-XX:ActiveProcessorCount=2"
USER kubedoop
