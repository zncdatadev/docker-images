# Kerberos 5

Install krb5 service using rockylinux9 and automatically initialize krb5kdc and kadmin services when running the container for the first time, then run the services using systemd.

The default mode keeps systemd as PID 1. Docker stop now uses systemd's native
`SIGRTMIN+3` orderly shutdown signal; raw `SIGTERM`/`SIGINT` have systemd
semantics, not the foreground supervisor semantics described below.

## Container lifecycle modes

- No mode flag: initialize once and exec systemd, preserving existing service
  names, ports, configuration paths and root identity.
- `--foreground [setup options]`: run real `krb5kdc -n` and
  `kadmind -nofork` under Tini without privileged/cgroup access. If either
  daemon exits, the other is stopped before post-hooks run.
- `--exec COMMAND [ARG...]`: run an explicit command without initializing a
  KDC. Preserve stdin, clean command stdout and its actual exit status.

For example, a development KDC without host cgroup or daemon changes:

```bash
docker run --name krb5 quay.io/zncdatadev/krb5:1.21.1-kubedoop0.0.0-dev \
  --foreground --realm EXAMPLE.COM --domain example.com \
  --password test-master-password --kadmin-password test-admin-password
```

The passwords above are development examples. Both `--kadmin-password` and the
previous README spelling `--kadmind-password` are accepted. All setup options
are parsed, not only the first one. Missing/unknown values and unsafe realm,
domain or admin-query characters fail closed without printing argument values.
Admin passwords currently accept letters, digits and `._/@%+=:-`.
The generated master-password file is mode 0600.

Mount root-owned executable `.sh` hooks at
`/kubedoop/mount/pre-script` and `/kubedoop/mount/post-script`. They run in
filename order, including projected-volume symlinks; hook stdin is
`/dev/null`. A pre-hook failure aborts startup. Post-hooks run only after the
owned processes stop; foreground post-hook failure does not mask main status.
In systemd mode the ordered oneshot unit records a failed post-hook as a unit
failure, and does not replace systemd's container exit status.

Foreground modes forward TERM, INT and Docker's RTMIN+3 stop signal as TERM
to the owned process group, then escalate to KILL after
`KUBEDOOP_KILL_TIMEOUT` (positive integer, default 30 seconds). Detached
processes escaping that session are unsupported. Systemd mode uses native
service control groups and 30-second stop deadlines; arbitrary
`KUBEDOOP_KILL_TIMEOUT` environment values do not configure systemd units.
Do not add Docker `--init` to the default systemd mode.

Same-container restarts retain the database and never recreate an initialized
realm. The existing `/data` volume is **not** an automatic KDC database mapping:
for replacement-container persistence, preserve both
`/var/kerberos/krb5kdc` and the matching `/etc/krb5.conf`, plus a stable
hostname. Existing data is never reformatted by lifecycle startup.

Native behavior references:
[systemd container interface](https://systemd.io/CONTAINER_INTERFACE/),
[MIT krb5kdc](https://web.mit.edu/kerberos/krb5-1.21/doc/admin/admin_commands/krb5kdc.html),
[MIT kadmind](https://web.mit.edu/kerberos/krb5-1.21/doc/admin/admin_commands/kadmind.html).

## Usage

Since the container manages multiple services using systemd, when running a systemd-based container, you may need to pass additional parameters to your runtime or use a specific runtime.

### quick start

```bash
docker run --rm -it \
    --name krb5 \
    -p 88:88 \
    -p 464:464 \
    -p 749:749 \
    quay.io/zncdatadev-test/krb5:dev
```

For higher performance, you can open udp ports:

```bash
docker run --rm -it \
    --name krb5 \
    -p 88:88 \
    -p 88:88/udp \
    -p 464:464 \
    -p 464:464/udp \
    -p 749:749 \
    quay.io/zncdatadev-test/krb5:dev
```

alternative, you can use the following command to run the container with a specific password, realm, and domain:

```bash
docker run --rm -it \
    --name krb5 \
    -p 88:88 \
    -p 464:464 \
    -p 749:749 \
    quay.io/zncdatadev-test/krb5:dev \
      --password kdcpasswd \
      --kadmind-password kadminpasswd \
      --realm EXAMPLE.COM \
      --domain example.com
```

you can also use the following command to get help:

```bash
docker run --rm -it \
    --name krb5 \
    -p 88:88 \
    -p 464:464 \
    -p 749:749 \
    quay.io/zncdatadev-test/krb5:dev \
      --help
```

#### more info

After running the container with minimal parameters, the initialization process will create some default values.
Most files and configurations still follow the official Kerberos documentation. Here are some pre-configured contents:

- kadmin configuration file location: `/etc/krb5.conf`
- kdc configuration file location: `/var/kerberos/krb5kdc/kdc.conf`
- kdc database location: `/var/lib/krb5kdc/principal`
- kadmin keytab location: `/var/lib/krb5kdc/kadmin.keytab`
- kdc default password: `$(openssl rand -base64 12)`
- kdc default password storage location: `/tmp/krb5kdc_admin_password`. Please save it promptly after configuration. You can also provide a custom password when starting the container.
- kadmin default password: `changeit`. Note that the default password is the string `changeit`. Please provide a custom password when starting the container if possible.
- realm default value: `EXAMPLE.COM`. Please provide a custom realm when starting the container.
- domain default value: By default, it is the lowercase form of the realm, such as `example.com`. Please provide a custom domain when starting the container.

### podman

In a podman environment, you can simply run it using `podman run` without any additional settings.

### rootless docker

When using [rootless docker](https://docs.docker.com/engine/security/rootless/) with cgroups v2 support, you need to add the following parameters:

```bash
--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
```

> Check if cgroup v2 is supported: `docker info --format '{{ json .CgroupVersion }}'`

### rootful docker

In a docker environment running with root privileges, you need to enable [user namespace remapping](https://docs.docker.com/engine/security/userns-remap/) to start systemd services with read-write access.

Add the following to `/etc/docker/daemon.json`:

```json
{ "userns-remap": "default" }
```

Then restart the docker service.

**Note:** After modification, resources previously run as root will be lost and need to be recreated.

### cgroups v1 docker

In a docker environment that does not support cgroups v2, you need to add the following parameter:

```bash
-v /sys/fs/cgroup/unified:/sys/fs/cgroup:rw
```

### kubernetes with containerd

In a kubernetes environment that uses containerd, you can refer to the Deployment example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: krb5
spec:
  selector:
    matchLabels:
      app: krb5
  template:
    metadata:
      labels:
        app: krb5
    spec:
      containers:
      - name: krb5
        image: quay.io/zncdatadev-test/krb5:dev
        securityContext:
          privileged: true
          capabilities:
            add:
              - SYS_ADMIN
        ports:
          - containerPort: 88
            protocol: TCP
            name: kdc
          - containerPort: 88
            protocol: UDP
            name: kdc-udp
          - containerPort: 464
            protocol: TCP
            name: kpasswd
          - containerPort: 464
            protocol: UDP
            name: kpasswd-udp
          - containerPort: 749
            protocol: TCP
            name: kadmin
        volumeMounts:
          - name: tmp
            mountPath: /tmp
          - name: tmp
            mountPath: /run
          - name: tmp
            mountPath: /run/lock
            subPath: run-lock
          - name: tmp
            mountPath: /data
        resources:
          limits:
            memory: "1024Mi"
            cpu: "1000m"
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: krb5-service
  labels:
    app: krb5
spec:
  selector:
    app: krb5
  ports:
    - protocol: TCP
      port: 88
      targetPort: 88
      name: kdc
    - protocol: UDP
      port: 88
      targetPort: 88
      name: kdc-udp
    - protocol: TCP
      port: 464
      targetPort: 464
      name: kpasswd
    - protocol: UDP
      port: 464
      targetPort: 464
      name: kpasswd-udp
    - protocol: TCP
      port: 749
      targetPort: 749
      name: kadmin
  type: NodePort

```

**Note:** The current container design does not take into account the potential data loss caused by container restarts or changes in container names.
Therefore, it is recommended to only use it in a development environment!

## Build

To build the container image, you can use the following command:

```bash
docker buildx create --name krb5-builder
docker buildx use krb5-builder
docker buildx build --push --platform linux/arm64,linux/amd64 -t quay.io/zncdatadev-test/krb5:dev .
docker buildx rm krb5-builder
```

## Inspiration

- [freeipa-container](https://github.com/freeipa/freeipa-container)
