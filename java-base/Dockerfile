# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


FROM zncdatadev/image/vector AS tini-downloader
ARG TARGETARCH
RUN <<EOF
    set -e
    curl -sSfL -o /tmp/tini "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TARGETARCH}"
    case "${TARGETARCH}" in
        amd64) expected_sha="c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee" ;;
        arm64) expected_sha="eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9" ;;
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
    esac
    echo "${expected_sha}  /tmp/tini" | sha256sum -c
    chmod 0755 /tmp/tini
EOF

## stage: final
FROM zncdatadev/image/vector

ARG PRODUCT_VERSION

RUN <<EOT
    set -e
    # https://adoptium.net/en-GB/installation/linux/#_centosrhelfedora_instructions
    cat <<EOF > /etc/yum.repos.d/adoptium.repo
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/${DISTRIBUTION_NAME:-$(. /etc/os-release; echo $ID)}/\$releasever/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF

    microdnf update
    microdnf install \
        krb5-workstation \
        temurin-${PRODUCT_VERSION}-jre \
        tzdata-java \
        util-linux-core

    microdnf clean all
    rm -rf /var/cache/yum

    # Newer Temurin packages use java-N-temurin-jre. Preserve the public
    # JAVA_HOME path used by existing downstream images on both architectures.
    expected_home="/usr/lib/jvm/temurin-${PRODUCT_VERSION}-jre"
    if [ ! -d "$expected_home" ]; then
        test -x "/usr/lib/jvm/java-${PRODUCT_VERSION}-temurin-jre/bin/java"
        ln -s "java-${PRODUCT_VERSION}-temurin-jre" "$expected_home"
    fi
    test -x "$expected_home/bin/java"
    "$expected_home/bin/java" -version
EOT

ENV JAVA_HOME=/usr/lib/jvm/temurin-${PRODUCT_VERSION}-jre
ENV JAVA_VERSION=${PRODUCT_VERSION}

# Mitigation for CVE-2021-44228 (Log4Shell)
# This variable is supported as of Log4j version 2.10 and
# disables the vulnerable feature
ENV LOG4J_FORMAT_MSG_NO_LOOKUPS=true

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-java-base/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-java-base \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

# Preserve root USER, inherited working directory and actual default Bash.
# Private helpers cannot be overwritten by downstream COPY /kubedoop trees.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-java-base/bin/entrypoint.sh"]
CMD ["/bin/bash"]
