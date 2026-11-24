ARG IMAGE
FROM ${IMAGE}
USER root
COPY Workload.java /tmp/Workload.java
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
COPY legacy-entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chmod 0755 /kubedoop/mount/post-script/10-post.sh /kubedoop/bin/entrypoint.sh \
    && chown -R kubedoop:kubedoop /kubedoop/bin
ARG COMPILE_USER=kubedoop
USER ${COMPILE_USER}
# Exercise this exact SDK's default javac/jar/javadoc/javap offline, as both
# UID1001 and root, rather than borrowing a compiler from another image.
RUN set -e; mkdir -p /kubedoop/run/classes; \
    javac -source 8 -target 8 -d /kubedoop/run/classes /tmp/Workload.java; \
    jar cfe /kubedoop/run/workload.jar Workload -C /kubedoop/run/classes .; \
    javadoc -quiet -d /kubedoop/run/docs /tmp/Workload.java; \
    javap -verbose -classpath /kubedoop/run/classes Workload | grep 'major version: 52'
CMD ["java", "-jar", "/kubedoop/run/workload.jar"]
