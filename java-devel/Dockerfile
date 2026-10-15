# syntax=docker/dockerfile:1.17.1@sha256:38387523653efa0039f8e1c89bb74a30504e76ee9f565e25c9a09841f9427b05
# check=error=true


FROM zncdatadev/image/kubedoop-base AS tini-downloader
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

FROM zncdatadev/image/kubedoop-base

ARG PRODUCT_VERSION

RUN <<EOT
    set -ex
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
        cmake \
        cyrus-sasl-devel \
        diffutils \
        fuse-devel \
        gcc \
        gcc-c++ \
        gettext \
        git \
        gzip \
        hostname \
        krb5-devel \
        libcurl-devel \
        make \
        maven \
        openssl-devel \
        patch \
        pkg-config \
        tar \
        temurin-${PRODUCT_VERSION}-jdk \
        tzdata-java \
        unzip \
        util-linux-core \
        wget \
        which \
        xz \
        zlib-devel \
        zip

    microdnf clean all
    rm -rf /var/cache/yum

    # Preserve the public JAVA_HOME even when Temurin changes its package path.
    public_home="/usr/lib/jvm/temurin-${PRODUCT_VERSION}-jdk"
    if [ ! -d "$public_home" ]; then
        test -x "/usr/lib/jvm/java-${PRODUCT_VERSION}-temurin-jdk/bin/javac"
        ln -s "java-${PRODUCT_VERSION}-temurin-jdk" "$public_home"
    fi
    jdk_home=$(readlink -f "$public_home")
    # Maven brings JDK17 too. Select the vendor's existing canonical alternatives
    # instead of re-registering a symlink path without jar/javadoc slave links.
    alternatives --set java "$jdk_home/bin/java"
    alternatives --set javac "$jdk_home/bin/javac"
    for tool in java javac jar javadoc javap; do
        test "$(readlink -f "$(command -v "$tool")")" = "$jdk_home/bin/$tool"
    done

    # smoke test
    JAVA_VERSION_OUTPUT=$(java -version 2>&1)
    if [ "${PRODUCT_VERSION}" != "8" ]; then
        echo "$JAVA_VERSION_OUTPUT" | grep -q "openjdk version \"${PRODUCT_VERSION}\." || {
            echo "ERROR: Expected Java ${PRODUCT_VERSION}, but got:"
            echo "$JAVA_VERSION_OUTPUT"
            exit 1
        }
    else
        echo "$JAVA_VERSION_OUTPUT" | grep -q "openjdk version \"1\.${PRODUCT_VERSION}\." || {
            echo "ERROR: Expected Java 1.${PRODUCT_VERSION}, but got:"
            echo "$JAVA_VERSION_OUTPUT"
            exit 1
        }
    fi
EOT

ENV JAVA_HOME=/usr/lib/jvm/temurin-${PRODUCT_VERSION}-jdk
ENV JAVA_VERSION=${PRODUCT_VERSION}

# Mitigation for CVE-2021-44228 (Log4Shell)
# This variable is supported as of Log4j version 2.10 and
# disables the vulnerable feature
ENV LOG4J_FORMAT_MSG_NO_LOOKUPS=true

COPY --from=tini-downloader /tmp/tini /usr/bin/tini
COPY --chown=root:root kubedoop/ /usr/local/libexec/kubedoop-java-devel/
RUN chmod -R 0755 /usr/local/libexec/kubedoop-java-devel \
    && chown root:kubedoop /kubedoop && chmod 1770 /kubedoop \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chown -R root:root /kubedoop/mount && chmod -R 0755 /kubedoop/mount \
    && chown kubedoop:kubedoop /kubedoop/run && chmod 1775 /kubedoop/run

# Preserve the SDK's inherited root USER, working directory and default Bash.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/libexec/kubedoop-java-devel/bin/entrypoint.sh"]
CMD ["/bin/bash"]
