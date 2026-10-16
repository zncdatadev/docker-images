FROM quay.io/rockylinux/rockylinux:9

ARG PRODUCT_VERSION
ARG TARGETARCH

RUN groupadd -g 288 kdcproxy ; useradd -u 288 -g 288 -c 'IPA KDC Proxy User' -r -d / -s '/sbin/nologin' kdcproxy

RUN ln -s /bin/false /usr/sbin/systemd-machine-id-setup
RUN dnf -y install --setopt=install_weak_deps=False \
    patch \
    vim \
    krb5-server-${PRODUCT_VERSION} \
    krb5-server-ldap-${PRODUCT_VERSION} \
    krb5-workstation-${PRODUCT_VERSION} \
    krb5-libs \
    procps \
    net-tools \
    curl-minimal \
    findutils \
    util-linux-core \
    openssl && \
    dnf clean all

# Standalone image: no prebuilt product/framework dependency.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) tini_arch=amd64; tini_sha=c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee ;; \
      arm64) tini_arch=arm64; tini_sha=eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9 ;; \
      *) echo "Unsupported TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${tini_arch}" -o /usr/bin/tini; \
    echo "${tini_sha}  /usr/bin/tini" | sha256sum -c -; \
    chmod 0755 /usr/bin/tini

RUN systemctl mask rpc-gssd.service

ENV container=oci

RUN echo "DefaultLimitNOFILE=4096" >> /etc/systemd/system.conf

# systemd's native orderly poweroff signal; opt-in supervisor handles it too.
STOPSIGNAL SIGRTMIN+3

RUN find /etc/systemd/system /usr/lib/systemd/system/{basic,multi-user,sysinit}.target.wants -type l \! -lname /dev/null | xargs rm -v \
    && systemctl mask systemd-logind.service && mv /usr/lib/systemd/system/systemd-logind.service /usr/lib/systemd/system/systemd-logind.service-disable-dbus

COPY minimal-fedora-37.patch /root/
RUN patch --verbose -p0 --fuzz=0 < /root/minimal-fedora-37.patch \
    && ln -s /usr/lib/systemd/system/dbus-broker.service /usr/lib/systemd/system/dbus.service

COPY container-krb5.target /usr/lib/systemd/system/

RUN systemctl set-default container-krb5.target \
    && rmdir -v /etc/systemd/system/multi-user.target.wants \
    && mkdir /etc/systemd/system/container-krb5.target.wants \
	&& ln -s /etc/systemd/system/container-krb5.target.wants /etc/systemd/system/multi-user.target.wants

RUN echo 2.0 > /etc/volume-version
VOLUME [ "/tmp", "/run", "/data" ]

COPY --chown=root:root kubedoop/bin/ /usr/local/libexec/kubedoop-krb5/bin/
COPY --chown=root:root krb5-setup /usr/local/libexec/kubedoop-krb5/bin/setup.sh
COPY --chown=root:root kubedoop/lib/ /usr/local/libexec/kubedoop-krb5/lib/
COPY kubedoop-lifecycle.service /usr/lib/systemd/system/
RUN chmod 0755 /usr/local/libexec/kubedoop-krb5/{bin,lib}/*.sh \
    && mkdir -p /kubedoop/mount/pre-script /kubedoop/mount/post-script /kubedoop/run \
    && chmod 0755 /kubedoop /kubedoop/mount /kubedoop/mount/{pre-script,post-script} \
    && chmod 1777 /kubedoop/run \
    && ln -s /usr/local/libexec/kubedoop-krb5/bin/init.sh /usr/local/sbin/init \
    && mkdir -p /etc/systemd/system/{krb5kdc.service.d,kadmin.service.d} \
    && printf '[Unit]\nRequires=kubedoop-lifecycle.service\nAfter=kubedoop-lifecycle.service\n[Service]\nTimeoutStopSec=30\nKillMode=control-group\n' > /etc/systemd/system/krb5kdc.service.d/lifecycle.conf \
    && cp /etc/systemd/system/krb5kdc.service.d/lifecycle.conf /etc/systemd/system/kadmin.service.d/lifecycle.conf \
    && systemctl enable krb5kdc kadmin kubedoop-lifecycle.service
ENTRYPOINT ["/usr/local/sbin/init"]

EXPOSE 88 88/udp 464 464/udp 749
