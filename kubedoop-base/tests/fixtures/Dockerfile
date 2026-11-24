ARG IMAGE
FROM ${IMAGE} AS inherited
USER root
COPY --chown=kubedoop:kubedoop legacy-entrypoint.sh /kubedoop/bin/entrypoint.sh
COPY workload.sh /usr/local/share/kubedoop-base-test/workload.sh
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/bin/entrypoint.sh /usr/local/share/kubedoop-base-test/workload.sh /kubedoop/mount/post-script/10-post.sh
USER kubedoop
WORKDIR /kubedoop/run
CMD ["/bin/bash", "/usr/local/share/kubedoop-base-test/workload.sh"]

FROM inherited AS overridden
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["printf 'TEST_OVERRIDE_ENTRYPOINT\\n'"]
