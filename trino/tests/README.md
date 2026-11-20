# Trino lifecycle verification

Trino independently vendors tini and the lifecycle framework in its own image.
The default CMD stays `launcher run`, the foreground launcher mode described in
[Trino deployment documentation](https://trino.io/docs/current/installation/deployment.html#running-trino).
Do not use the daemonizing `launcher start` as the managed main process.
Configuration, catalogs, JVM sizing, and node identity remain operator-owned;
the production image does not generate or overwrite them.
Framework directories are root-owned and not writable by the runtime user.
Their root-owned sticky parent preserves HOME cache writes but prevents the
runtime user from renaming and replacing framework directories. The existing
Trino installation remains kubedoop-owned; configured writable data paths still
work. Use `/kubedoop/run` for explicit runtime state.

In Kubernetes, provide launcher options through container `args` to retain the
image ENTRYPOINT. Setting container `command` bypasses tini and the framework.
Operators that replace `command` need an explicit adoption change; this image
does not change their Pod specifications.

    trino/tests/source-entrypoint-framework.sh
    .scripts/build.sh trino:451 --platform linux/amd64
    IMAGE=quay.io/zncdatadev/trino:451-kubedoop0.0.0-dev
    trino/tests/image-entrypoint-framework.sh "$IMAGE"
    trino/tests/image-trino-lifecycle.sh "$IMAGE"

Source regressions also simulate a ready coordinator with a not-yet-registered
worker, ensuring readiness waits for a connector query rather than constant SQL.
The framework suite covers root-owned ConfigMap symlinks, hook ordering and
failure propagation, stdin, real application exit codes, repeated signals,
SIGKILL escalation, and command-argument redaction. Hooks are non-interactive
and receive `/dev/null` stdin.
Framework diagnostics use stderr. Without injected hook output, the main
command's stdout stays machine-readable, including when debug logging is enabled.

The application suite creates a disposable derived image with test-only
configuration, hooks and a TPCH catalog. It runs the unchanged default CMD,
queries SQL and TPCH data, stops without forced termination, verifies post-hooks
execute after the Trino JVM exits, and restarts the same container. It checks
SQL again and verifies the node configuration was not modified. No existing
containers, external data services, host ports, or volumes are used. CLI
deadlines are enforced inside the container, with a longer host-side watchdog.
Regression probes verify both normal and SIGTERM-ignoring commands are removed
after their deadlines.

CI runs both image suites on all supported versions (451, 470, 476), on native
amd64 and arm64 runners. Local results must state the actual platform tested.

Follow-up regressions require installed-source hashes, root stdin/stdout, genuine
exit142, graceful/TERM-ignoring descendants after normal main exit, and safe
TERM-resistant timer cancellation/reaping before removing the ALRM handler.
The application owns a separate process group; post-hooks must not observe live
group members. The worker-readiness mock and inner CLI deadline checks remain.

Run `sudo bash trino/tests/source-entrypoint-framework.sh` for root hook coverage.
All three real application suites run as kubedoop and root, with three starts
of the same container per identity, TERM/INT/Docker stop, constant and TPCH SQL,
unchanged node identity and exact PRE/POST ordering after JVM exit. Cleanup uses
only test-created containers/anonymous volumes, a unique fixture image tag and
its own temporary directory. No existing user data, clusters or host ports.
