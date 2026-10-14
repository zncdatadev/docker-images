ARG IMAGE
FROM ${IMAGE}
USER root
COPY superset_config.py /kubedoop/run/superset_config.py
COPY 10-pre.sh /kubedoop/mount/pre-script/10-pre.sh
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-pre.sh /kubedoop/mount/post-script/10-post.sh
ENV SUPERSET_CONFIG_PATH=/kubedoop/run/superset_config.py \
    SERVER_WORKER_AMOUNT=2 \
    SERVER_THREADS_AMOUNT=2 \
    SUPERSET_BIND_ADDRESS=127.0.0.1 \
    KUBEDOOP_KILL_TIMEOUT=15
USER kubedoop
# Private disposable regression setup, never automatic production initialization.
RUN superset db upgrade \
    && superset fab create-admin --username lifecycle_admin --firstname Lifecycle \
        --lastname Regression --email regression@example.invalid --password private-test-only \
    && superset init
