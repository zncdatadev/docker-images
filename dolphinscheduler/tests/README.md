# DolphinScheduler universal process management

Both 3.3.2 and 3.2.2 retain their source build, Java 11 distribution and default
kubedoop UID 1001. ENTRYPOINT is `tini -- /kubedoop/bin/entrypoint.sh`; CMD is
`run-dolphinscheduler standalone-server`. The standalone role retains the
upstream H2 defaults; production users must supply appropriate secure deployment
configuration. This change does not initialize an external production database.

Select a distributed role explicitly:

```sh
docker run --rm IMAGE run-dolphinscheduler master-server
docker run --rm IMAGE run-dolphinscheduler worker-server
docker run --rm IMAGE run-dolphinscheduler api-server
docker run --rm IMAGE run-dolphinscheduler alert-server
```

The foreground launcher invokes each role's generated `start-foreground.sh`, a
copy of native `start.sh`. Runtime assembly asserts the expected native Java/class
lines, adds `exec` and argument forwarding, and removes JAVA_HOME/JAVA_OPTS echoing
only in this copy. The original `start.sh` is unchanged for legacy daemon PID/status/stop
and existing operator callers. Native role config sourcing, JVM options,
plugin discovery and version-specific classpaths remain upstream-owned. It does
not copy bin/env over role configuration. The upstream daemon remains available
for traditional administration, but its backgrounding `start` command is not an
appropriate main process for the universal lifecycle.

The native scripts differ between versions: 3.2.2 computes a role-local
DOLPHINSCHEDULER_HOME whereas 3.3.2 computes a distribution-wide home. The new
launcher does not impose a HOME override. Application arguments remain distinct
words; JAVA_OPTS retains native shell splitting semantics.

Root-owned executable `.sh` hooks in `/kubedoop/mount/pre-script` and
`post-script` run in filename order. Projected ConfigMap links are followed and
their targets checked for ownership/executability. Pre-hook/discovery errors
abort startup; post-hook errors are logged without replacing application status.
Hooks have /dev/null stdin, while the main process retains stdin. Framework
diagnostics use stderr and omit argv, including in debug mode. Tini reaps orphans.
TERM/INT initiate TERM-based graceful shutdown, bounded by the positive integer
`KUBEDOOP_KILL_TIMEOUT` (default 30 seconds). Repeated signals cannot interrupt
cleanup or cause duplicate post-hooks. Root-owned sticky HOME permits user cache
writes while preventing replacement of root-owned framework directories.
Managed commands own a separate session/process group. Live descendants drain
before post-hooks, including after normal main exit, using the same shutdown
deadline, measured with Linux's monotonic uptime clock so Bash's integer-second
boundaries cannot prematurely shorten a descendant's grace period. Owned ALRM
timers are forcibly cancelled and reaped before restoring
their handler; true application statuses including 127, 142 and 165 are preserved.

Docker arguments replace CMD and are managed verbatim. Kubernetes `command`
overrides ENTRYPOINT and bypasses these hooks. The existing operator constructs
its own shell/trap command and backgrounds role start.sh; this image PR does not
modify that operator or automatically activate the new lifecycle for such Pods.
Use `args` or explicitly invoke the universal entrypoint to use these hooks.

## Verification

```sh
bash dolphinscheduler/tests/source-entrypoint-framework.sh
sudo bash dolphinscheduler/tests/source-entrypoint-framework.sh
bash dolphinscheduler/tests/source-launcher-adaptation.sh
sudo bash dolphinscheduler/tests/source-launcher-adaptation.sh
bash dolphinscheduler/tests/image-entrypoint-framework.sh IMAGE
bash dolphinscheduler/tests/image-role-launchers.sh IMAGE
bash dolphinscheduler/tests/image-dolphinscheduler-lifecycle.sh IMAGE
```

The host needs Docker and jq (the build setup provides jq). CI runs all five
suites after every native amd64/arm64 version build. CI also runs the source
and launcher-adaptation suites using the image's native
Bash as both kubedoop and root. The framework image suite
checks exact runtime source hashes, metadata/UID, protected directories/writable
HOME, projected hooks, stdin/clean stdout, status 7/127/42, signal forwarding,
repeated cleanup signals, escalation, orphan reaping and argv confidentiality.

Five-role tests execute the foreground copies of actual shipped native launchers with an instrumented
JVM to verify class selection, option/argument retention, exec PID identity and
normal/signal exit status. They are wiring tests, not distributed cluster tests.
An additional regression exercises the actual legacy daemon start/status/stop
with its original launcher and verifies its owned JVM child stops and PID file
is removed.

The real standalone suite uses production default CMD as both UID1001 and root,
authenticates against the actual API, creates a project, and starts each same
container three times. It reads the project's identity/description across those
starts and checks explicit TERM, INT and docker stop with exact PRE/POST ordering,
no KILL escalation and no surviving JVM. Container-side CLI deadlines verify
both normal and TERM-ignoring commands stop completely. Disposable fixture
configuration selects private file H2
and loopback HTTP, initializes only on first start and preserves schema on
restart. No host data is mounted and no ports are published. These regressions
validate process management and basic API/database continuity, not multi-node
registry/database deployment or arbitrary workflow execution.
