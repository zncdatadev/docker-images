ARG IMAGE
FROM ${IMAGE}
USER root
COPY --chown=root:root --chmod=0755 10-prepare.sh /kubedoop/mount/pre-script/10-prepare.sh
COPY --chown=root:root --chmod=0755 10-check-stopped.sh /kubedoop/mount/post-script/10-check-stopped.sh
COPY --chown=root:root api.py /kubedoop/run/api.py
ARG RUNTIME_USER=root
USER ${RUNTIME_USER}
