ARG IMAGE
FROM ${IMAGE}
USER root
COPY job.py /kubedoop/run/job.py
COPY 10-prepare.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-prepare.sh /kubedoop/mount/post-script/10-check-stopped.sh
ENV SPARK_DAEMON_MEMORY=256m SPARK_DAEMON_JAVA_OPTS="-XX:ActiveProcessorCount=2" SPARK_HISTORY_OPTS="-Dspark.history.fs.logDirectory=file:///kubedoop/run/events -Dspark.history.fs.update.interval=1s -Dspark.history.ui.port=18080"
USER kubedoop
