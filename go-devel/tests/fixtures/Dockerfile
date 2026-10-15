ARG IMAGE
FROM ${IMAGE}
USER root
COPY workload.go /tmp/workload.go
COPY 10-post.sh /kubedoop/mount/post-script/10-post.sh
RUN chmod 0755 /kubedoop/mount/post-script/10-post.sh
USER kubedoop
# Offline actual SDK compilation as UID1001, with no downloaded Go toolchain.
RUN GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0 go build -trimpath -o /kubedoop/run/workload /tmp/workload.go
CMD ["/kubedoop/run/workload"]
