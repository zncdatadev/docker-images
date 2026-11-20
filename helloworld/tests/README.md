# Helloworld process management

The original image prints its hello during the Docker build, not at runtime.
Keep that behavior and the inherited root USER and `/bin/bash` CMD. Commands
passed by callers run unchanged under Tini and the universal foreground-process
supervisor; this image has no additional application daemon to configure.

Run the source suite under the normal user and root, then build the full image
with its original kubedoop-base source dependency and run the image suite:

```bash
bash helloworld/tests/source-entrypoint-framework.sh
bash helloworld/tests/image-entrypoint-framework.sh IMAGE
```

The image suite verifies actual default Bash stdin, explicit hello under root
and UID1001, exact runtime/source hashes, writable HOME, protected helpers,
ConfigMap-style hooks, status127, stdin/stdout isolation, orphan reaping,
TERM/INT cleanup and bounded escalation. Source tests also cover descendants
left behind after normal main-command exit. CI runs both suites on native
amd64 and arm64. No runtime network service, port or external fixture is needed.
