# Tools process management

Preserve the original kubedoop UID1001, `/kubedoop` working directory, tool PATH,
tool versions and inherited Bash CMD. Commands pass through unchanged under
Tini and an owned foreground process group. Root-owned helpers live outside
the existing writable tool directory at `/usr/local/libexec/kubedoop-tools`.

```bash
bash tools/tests/source-entrypoint-framework.sh
bash tools/tests/image-entrypoint-framework.sh IMAGE
bash tools/tests/image-tools-lifecycle.sh IMAGE
```

Run source tests as root too, and build the full original kubedoop-base source
graph. The generic image suite verifies actual default Bash/stdin, runtime/source
hashes, writable HOME/protected helpers, ConfigMap hooks, status127, orphan
reaping, repeated cleanup signals and bounded escalation. The native CLI suite
uses actual jq/yq stdin pipelines, kubectl client version and offline ConfigMap
dry-run, plus jq parse-error exit status, as UID1001 and root. No real cluster,
network credentials or production resources are used. CI repeats all three
suites on native amd64 and arm64; source tests also cover leftover descendants.
