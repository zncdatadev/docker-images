#!/bin/bash
# Real CLI operations without a Kubernetes cluster or external credentials.
set -euo pipefail
IMAGE="${1:?Usage: image-tools-lifecycle.sh IMAGE}"
for user in kubedoop root; do
    docker run --rm --user "$user" "$IMAGE" bash -c '
        set -euo pipefail
        [[ "$(jq --version)" == jq-1.7.1 ]]
        yq --version | grep -Fq v4.44.2
        [[ "$(kubectl version --client -o json | jq -r .clientVersion.gitVersion)" == v1.31.1 ]]
    '
    output=$(printf '{"items":[1,2,3]}\n' | docker run --rm -i --user "$user" "$IMAGE" jq -c '.items | map(. * 2)')
    [[ "$output" == '[2,4,6]' ]] || { echo 'jq stdin/stdout changed' >&2; exit 1; }
    output=$(printf 'message: hello\n' | docker run --rm -i --user "$user" "$IMAGE" yq -o=json -I=0 '.')
    [[ "$output" == '{"message":"hello"}' ]] || { echo 'yq stdin/stdout changed' >&2; exit 1; }
    output=$(docker run --rm --user "$user" "$IMAGE" kubectl create configmap lifecycle --from-literal=message=hello --dry-run=client -o json)
    [[ "$(printf '%s' "$output" | docker run --rm -i "$IMAGE" jq -r '.data.message')" == hello ]] || { echo 'kubectl client dry-run failed' >&2; exit 1; }
    native_rc=0
    printf 'not-json\n' | docker run --rm -i --user "$user" --entrypoint /kubedoop/bin/jq "$IMAGE" . >/dev/null 2>&1 || native_rc=$?
    [[ "$native_rc" -gt 0 ]] || { echo 'invalid JSON did not fail in the native CLI' >&2; exit 1; }
    rc=0
    printf 'not-json\n' | docker run --rm -i --user "$user" "$IMAGE" jq . >/dev/null 2>&1 || rc=$?
    [[ "$rc" == "$native_rc" ]] || { echo "jq parse failure status changed: native=$native_rc supervised=$rc" >&2; exit 1; }
    echo "ok - actual jq/yq pipelines, kubectl client version and dry-run, parse-error status as $user"
done
