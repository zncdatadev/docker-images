#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRODUCT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_DIR=$(cd "$PRODUCT_DIR/.." && pwd)
PREFIX="${1:-local/kubedoop-base-downstream}"
expected=$(cd "$PRODUCT_DIR/kubedoop" && sha256sum bin/entrypoint.sh lib/log.sh lib/run.sh lib/signal.sh)
for product in helloworld tools vector go-devel java-devel; do
    count=0
    while IFS= read -r version; do
        count=$((count + 1))
        image="$PREFIX/$product:$version"
        metadata=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
        [[ "$metadata" == '["/usr/bin/tini","--","/usr/local/libexec/kubedoop-base/bin/entrypoint.sh"]' ]]
        actual=$(docker run --rm --entrypoint /bin/bash "$image" -c 'cd /usr/local/libexec/kubedoop-base && sha256sum bin/entrypoint.sh lib/log.sh lib/run.sh lib/signal.sh')
        [[ "$actual" == "$expected" ]]
        expected_uid=0
        [[ "$product" != tools ]] || expected_uid=1001
        output=$(printf 'id -u\n' | docker run --rm -i "$image")
        [[ "$output" == "$expected_uid" ]]
        case "$product" in
            tools)
                output=$(printf '{"value":42}\n' | docker run --rm -i "$image" jq -r .value)
                [[ "$output" == 42 ]]
                docker run --rm "$image" yq --version | grep -F 'yq' >/dev/null
                docker run --rm "$image" kubectl version --client >/dev/null
                output=$(docker run --rm "$image" kubectl create configmap base-cli --from-literal=value=42 --dry-run=client -o json)
                grep -Fq '"value": "42"' <<< "$output"
                ;;
            vector) docker run --rm "$image" vector --version | grep -F "$version" >/dev/null ;;
            go-devel) docker run --rm "$image" go version | grep -F "go$version" >/dev/null ;;
            java-devel)
                if [[ "$version" == 8 ]]; then expected_java=1.8; else expected_java="$version"; fi
                output=$(docker run --rm "$image" java -XshowSettings:properties -version 2>&1)
                grep -Eq "java.specification.version = ${expected_java//./\\.}$" <<< "$output"
                output=$(docker run --rm "$image" javac -version 2>&1)
                grep -Eq "^javac ${expected_java//./\\.}\\." <<< "$output"
                ;;
        esac
        echo "ok - original source-built $product:$version inherits exact base helpers, actual default Bash/UID and native CLI behavior"
    done < <(awk '$1 == "-" && $2 == "product:" {print $3}' "$REPO_DIR/$product/versions.yaml")
    [[ "$count" -gt 0 ]] || { echo "no declared $product versions tested" >&2; exit 1; }
done
