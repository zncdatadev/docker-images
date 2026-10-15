ARG IMAGE
FROM ${IMAGE}
USER root
COPY worker.py /kubedoop/run/worker.py
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/post-script/10-post.sh
USER kubedoop
CMD ["python3", "-u", "/kubedoop/run/worker.py"]
