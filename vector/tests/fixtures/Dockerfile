ARG IMAGE
FROM ${IMAGE}
COPY vector.toml /kubedoop/run/vector.toml
COPY 10-pre.sh /kubedoop/mount/pre-script/10-pre.sh
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/pre-script/10-pre.sh /kubedoop/mount/post-script/10-post.sh
USER kubedoop
CMD ["vector", "--config", "/kubedoop/run/vector.toml"]
