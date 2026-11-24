# Airflow process lifecycle regressions

Run from the repository root:

```bash
bash airflow/tests/source-entrypoint-framework.sh
bash airflow/tests/source-runner.sh
bash airflow/tests/image-entrypoint-framework.sh IMAGE
bash airflow/tests/image-airflow-lifecycle.sh IMAGE
```

Run source framework tests as root too. Build every versions.yaml entry before
image acceptance. No external database, broker, cluster or public port is used
by generic lifecycle tests. Real scheduler/database/service acceptance is required
separately; the capture fixture is not a product functionality test. The real
application suite covers version-specific native CLI commands, project venv
access as root, a real SQLite-backed scheduler, registered job state retained
on restart, TERM/INT and exactly-once hooks. SQLite is private test-only;
Celery broker/task integration and external production database remain separate.
The adapter source suite checks broker connectivity success/failure against a
private loopback TCP fixture and keeps credentials out of its diagnostics.

The default CMD is `airflow --help`; it does not require a database. Native
Airflow 2 webserver and Airflow 3 api-server, scheduler, dag-processor, triggerer
and celery commands are not translated between versions. Native CLI owns version
availability and validation. Use explicit `airflow` to invoke plugin CLI commands.
Other executable commands pass through without Airflow initialization. Native
`bash` and `python` retain optional DB checks (disable with
`CONNECTION_CHECK_MAX_COUNT=0` for diagnostics). Existing opt-in migration,
user creation and development requirements remain explicit, not auto-enabled.
Requested database migration failures stop startup.

UID/GID 1001:1001 is the project default. The original official-image GID=0
allowance remains, but arbitrary UID support is not newly promised. UBI's real
libstdc++ location is preloaded only when readable; existing preloads are kept.
The venv remains the application source for root and non-root users.

The universal entrypoint owns pre/post-hooks under /kubedoop/mount, stderr-only
diagnostics, stdin and main status preservation. Root-owned helpers and sticky
HOME prevent replacement while preserving HOME/run writes. Workload processes
have a separate process group; post-hooks run only after live members stop.
Celery worker gets main-process TERM first for warm task shutdown; descendants
are signaled after the main process exits, or forcibly killed at the deadline.
Other roles receive group TERM. Explicit daemonizing/setsid-escaping commands
are not supervised foreground workloads.
