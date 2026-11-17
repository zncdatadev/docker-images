#!/bin/sh
set -eu

image=${1:?Usage: test_python_runtime.sh IMAGE [PLATFORM]}
platform=${2:-}
if [ -n "$platform" ]; then
    set -- --platform "$platform"
else
    set --
fi

docker run --rm --network none "$@" --entrypoint python "$image" -c '
from importlib import import_module
from pathlib import Path
import subprocess
import sys

assert sys.version_info[:2] == (3, 13), sys.version
assert "VERSION_CODENAME=bookworm" in Path("/etc/os-release").read_text()
for name in (
    "bs4", "charset_normalizer", "gssapi", "kerberos", "nipyapi", "pandas",
    "puresasl", "pytest", "requests", "thrift", "trino",
):
    import_module(name)
assert hasattr(import_module("hive_metastore_client"), "HiveMetastoreClient")
subprocess.run([sys.executable, "-m", "pip", "check"], check=True)
print("Python runtime and representative client imports passed")
'
