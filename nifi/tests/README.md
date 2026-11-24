# NiFi lifecycle verification

NiFi independently vendors checksum-verified tini and the universal lifecycle
framework. Its default command remains `nifi.sh run`: NiFi 2.4.0's native
script execs the application JVM in this mode. Do not use daemonizing
`nifi.sh start` as the managed main process.
See the [pinned upstream startup script](https://github.com/apache/nifi/blob/rel/nifi-2.4.0/nifi-framework-bundle/nifi-framework/nifi-resources/src/main/resources/bin/nifi.sh).

The source builder mirrors the legacy Shibboleth repository ID to its
[canonical release URL](https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2891317253/MavenRepositories).
The old redirecting URL failed TLS downloads with the pinned Maven 3.9.9
wrapper during local verification. The mirror changes only that repository
location; dependency versions, Maven transport and certificate checks are
unchanged. It is not copied into the runtime image.

The existing default root user is preserved. Explicit kubedoop (UID 1001)
execution is also verified, matching ownership of the NiFi installation.
Configuration, TLS, authentication, and repository
locations remain operator-owned; the production entrypoint does not generate,
overwrite, or downgrade them. Existing writable NiFi directories remain writable.
Framework bin/lib/mount directories are root-owned. A root-owned sticky HOME
preserves cache writes while preventing the non-root user from replacing those
directories. Root execution is not a security boundary against framework edits.
`/kubedoop/run` is available for explicit runtime state.

Pass commands using container args to retain the ENTRYPOINT. Kubernetes
`command` overrides bypass tini and lifecycle hooks; operator adoption is
a separate change, not part of this image PR.

    nifi/tests/source-entrypoint-framework.sh
    .scripts/build.sh nifi:2.4.0 --platform linux/amd64
    IMAGE=quay.io/zncdatadev/nifi:2.4.0-kubedoop0.0.0-dev
    nifi/tests/image-entrypoint-framework.sh "$IMAGE"
    nifi/tests/image-nifi-lifecycle.sh "$IMAGE"

The framework suites cover hook discovery through ConfigMap symlinks,
root ownership, hook ordering/failures, stdin, clean machine-readable stdout,
exit codes (including 127), repeated signals and bounded SIGKILL escalation.
Hooks receive /dev/null stdin and diagnostics go to stderr.

The real-application suite uses a disposable derived image with test-only
loopback HTTP and reduced heap configuration. Production TLS/auth defaults are
unchanged. It runs the unchanged default CMD, queries the actual REST API,
creates a process group, stops without escalation, checks the JVM is gone before
the post-hook, starts the same container three times, and verifies root identity and the
created group survived, under both root and kubedoop users. It uses no host
ports, volumes or external services.
HTTP timeouts are enforced inside the container, with a longer host watchdog.
The three stops use explicit SIGTERM, SIGINT and docker stop.
Each initiates the framework's documented SIGTERM-based graceful main-process
shutdown, preserving the actual JVM status and running post-hooks once.

CI runs source and both image suites on native amd64 and arm64 for every
supported version. State the actual platform when reporting local results.

Owned live process groups must drain before post-hooks even when the main
process exits normally. Timer cancellation/reaping must precede ALRM handler
removal; a deterministic TERM-resistant timer regression preserves status 42,
while a real application status 142 is also retained. Image regressions compare
installed runtime hashes, require setsid, and exercise graceful/TERM-ignoring
descendants. The real API suite also requires exact PRE/POST ordering and
container-side deadlines for normal and TERM-ignoring commands. Cleanup removes
only disposable containers/images created by the current test, never user data.
