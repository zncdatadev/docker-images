# Superset lifecycle regression contracts

Run from the repository root, against every versions.yaml image:

```bash
bash superset/tests/source-entrypoint-framework.sh
bash superset/tests/source-runner.sh
bash superset/tests/image-entrypoint-framework.sh IMAGE
bash superset/tests/image-superset-lifecycle.sh IMAGE
```

Run source framework tests as root too. Native source builds, final runtime
hashes/ownership/UID, hooks, stdin/status, bounded shutdown, repeated signals,
orphan reaping and secret non-logging are checked separately from real services.
Capture fixtures are adapter tests, not native product acceptance.

CMD remains a production Gunicorn web service (`webserver`) with the existing
environment defaults. Gunicorn options are quoted and extra arguments are
forwarded. `worker` and `beat` use native Superset Celery application commands;
`superset`, `gunicorn`, `celery`, shell and other commands pass through unchanged.
No key generation, database initialization/migration, user creation, dependency
installation, broker setup or authentication mutation happens automatically.

Gunicorn and Celery masters receive main-only TERM to own worker/task shutdown.
The isolated foreground group is drained after main exit or bounded escalation,
before post-hooks; other arbitrary commands receive group TERM. Source tests
exercise warm task completion as well as leftover graceful/ignoring children.
Explicit daemon/setsid-escaping commands are not supervised foreground workloads.

Real service tests use private disposable SQLite metadata, explicit test-only
initialization and config, no host mounts or public ports. They exercise real
Gunicorn health, metadata persistence, same-container restart and TERM/INT with
post-hooks after worker exit. External databases/brokers, complete Celery task
integration, production authentication and operator migration are not claimed.
