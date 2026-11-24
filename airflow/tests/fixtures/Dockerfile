ARG IMAGE
FROM ${IMAGE}
USER root
COPY 10-pre.sh /kubedoop/mount/pre-script/10-pre.sh
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-pre.sh /kubedoop/mount/post-script/10-post.sh
ARG EXECUTOR
ENV AIRFLOW__CORE__LOAD_EXAMPLES=False \
    AIRFLOW__CORE__EXECUTOR=${EXECUTOR} \
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////kubedoop/airflow/airflow.db \
    CONNECTION_CHECK_MAX_COUNT=0
USER kubedoop
# Explicit private-test initialization, never production automatic migration.
RUN airflow db migrate
