ARG SDK_IMAGE
ARG IMAGE
FROM ${SDK_IMAGE} AS compiler
USER root
RUN mkdir -p /kubedoop/run && chown kubedoop:kubedoop /kubedoop/run
USER kubedoop
COPY --chown=kubedoop:kubedoop Workload.java /kubedoop/run/Workload.java
# The original source-built JDK8 compiles portable bytecode without a network.
RUN javac -source 8 -target 8 -d /kubedoop/run /kubedoop/run/Workload.java

FROM ${IMAGE}
USER root
COPY --from=compiler /kubedoop/run/Workload*.class /kubedoop/run/
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
# Legacy child images may own these paths; the inherited private supervisor
# must continue working, execute hooks exactly once, and retain our child CMD.
COPY legacy-entrypoint.sh /kubedoop/bin/entrypoint.sh
RUN chmod 0755 /kubedoop/mount/post-script/10-post.sh /kubedoop/bin/entrypoint.sh \
    && chown -R kubedoop:kubedoop /kubedoop/bin
USER kubedoop
CMD ["java", "-cp", "/kubedoop/run", "Workload"]
