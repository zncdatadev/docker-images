# Go SDK lifecycle and downstream compatibility

Keep the four original SDK versions, root identity, Bash CMD, GOROOT/PATH and
development toolchain. Root-owned base helpers use a private libexec namespace
outside downstream application COPY/chown trees. No service starts by default.

```bash
bash go-devel/tests/source-entrypoint-framework.sh
bash go-devel/tests/image-entrypoint-framework.sh IMAGE
bash go-devel/tests/image-go-lifecycle.sh IMAGE GO_VERSION
```

Run source tests as root too. Build all four complete source images; generic
tests cover actual default Bash/stdin, exact hashes, UID1001 HOME/protection,
projected hooks, orphan reaping, status127 and bounded repeated-signal cleanup.
Each native suite compiles a real standard-library Go binary offline as UID1001
using that exact SDK (no toolchain download), then runs it as UID1001 and root.
TERM/INT must persist state before post-hooks and retain status42 across a
same-container restart. The signal channel is buffered for os/signal delivery,
never closed by the receiver, and deregistered before exit; no fixture goroutine
is spawned. Integration orchestration is in shell, not Go unit tests.

Go-devel is Airflow's git-sync builder but the existing Airflow path filter
does not watch go-devel. Build the original Airflow3.0.1 source target against
this graph, smoke-test actual git-sync and native Airflow CLI. Own CI repeats
that downstream build on both architectures for the Go1.23.12 dependency leg,
without pushing the smoke image. This does not migrate the Airflow operator.
