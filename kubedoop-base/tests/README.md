# Foundational process management

Preserve UBI root USER, working directory, Bash CMD/stdin, uid/gid1001 and
`/kubedoop` HOME. Checksum-pinned Tini is PID1; foreground commands own a
separate process group, with bounded TERM/KILL, orphan reaping, real status,
ordered root-owned projected pre/post hooks and stderr diagnostics without argv.

Helpers live in `/usr/local/libexec/kubedoop-base`, outside legacy downstream
COPY/chown trees. Child CMD overrides inherit that supervisor; explicit child
ENTRYPOINT overrides replace it, without nested supervisors. Docker RUN does not
invoke ENTRYPOINT. Applications needing special graceful-shutdown policies may
supply their own launcher/ENTRYPOINT. Detached/setsid-escaping programs are
outside this foreground contract.

Run from the repository root after original generated-bake source builds:

```bash
bash kubedoop-base/tests/source-entrypoint-framework.sh
bash kubedoop-base/tests/image-entrypoint-framework.sh BASE_IMAGE
bash kubedoop-base/tests/image-inheritance.sh BASE_IMAGE
bash kubedoop-base/tests/image-direct-children.sh local/kubedoop-base-downstream
bash kubedoop-base/tests/image-downstream-zookeeper.sh ZOOKEEPER_IMAGE
```

Repeat source behavior tests as root. Generic image tests check source hashes,
actual default Bash/root/stdin/stdout, projected hooks and failures, valid127,
repeated TERM/INT, orphan reaping and bounded cleanup. The child fixture exercises
three persisted starts, TERM/INT/docker stop, status42 and flush-before-exactly-once
post hooks as root and uid1001, despite conflicting legacy entrypoint content.

Full local downstream builds include all original direct children/SDK versions
and ZooKeeper:3.9.3's complete Maven source graph, followed by actual native CLI
checks and znode creation/read after same-container restart. No external prebuilt
product images substitute for these builds. Version-specific SDK toolchain fixes
belong to their independent SDK PRs, not this foundational image change.

Own native amd64/arm64 CI runs source/generic/inheritance suites. All affected
downstream build workflows must pass the exact PR HEAD before rollout advances.
