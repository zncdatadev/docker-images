# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true

## stage: dolphin-builder
FROM zncdatadev/image/java-devel AS dolphin-builder

ARG PRODUCT_VERSION

WORKDIR /build

RUN --mount=type=cache,target=/root/.m2 --mount=type=cache,target=/root/.pnpm-store <<EOF
    set -euo pipefail
    mkdir -p /build/dolphinscheduler-src
    pushd /build/dolphinscheduler-src
    curl -sSfL \
        https://github.com/apache/dolphinscheduler/archive/refs/tags/${PRODUCT_VERSION}.tar.gz \
        | tar xzf - --strip-components=1
    chmod +x ./mvnw
    ./mvnw --batch-mode --no-transfer-progress clean package \
        -Dmaven.test.skip \
        -Dmaven.javadoc.skip \
        -Dspotless.skip=true \
        -Prelease

    tar -xzf dolphinscheduler-dist/target/apache-dolphinscheduler-${PRODUCT_VERSION}-bin.tar.gz -C /kubedoop

    # set +x to avoid permission denied for sub-projects
    find /kubedoop/apache-dolphinscheduler-${PRODUCT_VERSION}-bin -maxdepth 2 -type d -name "bin" -exec chmod +x -R {} \;

    ln -s /kubedoop/apache-dolphinscheduler-${PRODUCT_VERSION}-bin /kubedoop/dolphinscheduler
    popd

    # cleanup source
    rm -rf /build/dolphinscheduler-src
EOF

# smoke test
RUN test -f /kubedoop/dolphinscheduler/bin/dolphinscheduler-daemon.sh

## stage: tini-downloader
FROM zncdatadev/image/java-devel AS tini-downloader
ARG TARGETARCH
ARG TINI_VERSION
RUN <<EOF
    set -e
    curl -sSfL -o /tmp/tini "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod 0755 /tmp/tini
EOF

## stage: final
FROM zncdatadev/image/java-base

RUN microdnf install util-linux-core \
    && microdnf clean all

COPY --from=dolphin-builder --chown=kubedoop:kubedoop /kubedoop/ /kubedoop/
COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/lib/ /kubedoop/lib/
COPY --chown=root:root kubedoop/bin/ /kubedoop/bin/
COPY kubedoop/prepare-launchers.sh /tmp/prepare-launchers.sh
RUN bash /tmp/prepare-launchers.sh /kubedoop/dolphinscheduler \
    && rm /tmp/prepare-launchers.sh \
    && chown root:kubedoop /kubedoop \
    && chmod 1770 /kubedoop \
    && chown root:root /kubedoop/bin /kubedoop/lib \
    && chmod -R 0755 /kubedoop/bin /kubedoop/lib \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount \
    && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run \
    && chmod 1775 /kubedoop/run
ENV PATH="/kubedoop/bin:${PATH}"

USER kubedoop

WORKDIR /kubedoop/dolphinscheduler
ENTRYPOINT ["tini", "--", "/kubedoop/bin/entrypoint.sh"]
CMD ["run-dolphinscheduler", "standalone-server"]
