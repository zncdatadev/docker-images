# Kerberos lifecycle acceptance

Run from the repository root after building the full original `krb5-1_21_1`
target with `--load`, no cache export and no push:

```bash
bash krb5/tests/source-entrypoint-framework.sh
sudo bash krb5/tests/source-entrypoint-framework.sh
bash krb5/tests/image-entrypoint-framework.sh IMAGE
bash krb5/tests/image-kerberos.sh IMAGE
```

The source harness covers exact packaging paths, valid statuses including
127/142/165, interrupted waits, repeated shutdown signals, descendants after
normal exit, KILL deadlines, TERM-resistant timer cancellation before SIGALRM
handler removal, hook ordering/discovery failure and stdin/stdout.
The image harness hashes installed sources, follows projected hook symlinks,
checks failure policies, TERM/INT/RTMIN+3, orphan reaping and argv confidentiality.
The real KDC suite verifies `kinit`/`klist`, authenticated `kadmin` RPC,
and deterministically checks that post-hook assertions reject live daemons but
allow terminated zombies awaiting reaping (both daemon names).
It checks database persistence over nine same-container starts (three complete
TERM/INT/native-stop sequences in foreground mode), default systemd PID 1,
optional foreground Tini and post-hooks after both real daemons have stopped.
Failures retain container logs/state and process names/states without command
arguments; both native CI legs finish independently to preserve diagnostics.

The systemd test uses an isolated privileged container with a private cgroup
namespace, never a host cgroup mount or host daemon configuration change.
Readiness or unsupported runtime failures are failures, not skipped acceptance.
The fixture derives only from the locally source-built image. Cleanup is scoped
to the harness's own container IDs, anonymous volumes and unique fixture tag.
