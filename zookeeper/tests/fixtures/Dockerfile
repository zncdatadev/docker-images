ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
COPY --chown=root:root pre.sh /kubedoop/mount/pre-script/..v1/10-pre.sh
COPY --chown=root:root post.sh /kubedoop/mount/post-script/..v1/10-post.sh
RUN chmod 0755 /kubedoop/mount/{pre-script,post-script}/..v1/*.sh \
    && ln -s ..v1 /kubedoop/mount/pre-script/..data \
    && ln -s ..data/10-pre.sh /kubedoop/mount/pre-script/10-pre.sh \
    && ln -s ..v1 /kubedoop/mount/post-script/..data \
    && ln -s ..data/10-post.sh /kubedoop/mount/post-script/10-post.sh \
    && sed -i 's#^dataDir=.*#dataDir=/kubedoop/run/zookeeper-data#' /kubedoop/zookeeper/conf/zoo_sample.cfg
USER kubedoop
