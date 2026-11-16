#!/bin/sh
set -eu

image=${1:?Usage: test_kafka_python.sh IMAGE [PLATFORM]}
platform=${2:-}
if [ -n "$platform" ]; then
    set -- --platform "$platform"
else
    set --
fi

docker run --rm --network none "$@" --entrypoint python "$image" -c '
from kafka3 import KafkaConsumer, KafkaProducer
from kafka3.protocol.metadata import MetadataRequest

request = MetadataRequest[0](["test"])
assert request.encode() == bytes.fromhex("00000001000474657374")
print("Kafka client import and protocol serialization passed")
'
