REGISTRY ?= quay.io/zncdatadev
KUBEDOOP_VERSION ?= 0.0.0-dev
CI_DEBUG ?= false

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

LOCAL_BIN = ./bin

##@ Install dependencies

# install yq
.PHONY: yq
YQ = $(LOCAL_BIN)/yq
yq: ## Download yq locally if necessary.
ifeq (,$(wildcard $(YQ)))
ifeq (,$(shell which yq 2>/dev/null))
	@{ \
		set -e ;\
		mkdir -p $(dir $(YQ)) ;\
		OS=$(shell uname -s | tr '[:upper:]' '[:lower:]') && \
		ARCH=$(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/') && \
		if [ "$${OS}" = "darwin" ]; then OS="macos"; fi && \
		curl -sSLo $(YQ) https://github.com/mikefarah/yq/releases/latest/download/ya_$${OS}_$${ARCH} ;\
		chmod +x $(YQ) ;\
	}
else
YQ = $(shell which yq)
endif
endif

# install jq
.PHONY: jq
JQ = $(LOCAL_BIN)/jq
jq: yq ## Download jq locally if necessary.
ifeq (,$(wildcard $(JQ)))
ifeq (,$(shell which jq 2>/dev/null))
	@{ \
		set -e ;\
		mkdir -p $(dir $(JQ)) ;\
		OS=$(shell uname -s | tr '[:upper:]' '[:lower:]') && \
		ARCH=$(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/') && \
		if [ "$${OS}" = "darwin" ]; then OS="macos"; fi && \
		curl -sSLo $(JQ) https://github.com/jqlang/jq/releases/latest/download/jq-$${OS}-$${ARCH} ;\
		chmod +x $(JQ) ;\
	}
else
JQ = $(shell which jq)
endif
endif

.PHONY: cosign
COSIGN = $(LOCAL_BIN)/cosign
cosign: ## Download cosign locally if necessary.
ifeq (,$(wildcard $(COSIGN)))
ifeq (,$(shell which cosign 2>/dev/null))
	@{ \
		set -e ;\
		mkdir -p $(dir $(COSIGN)) ;\
		OS=$(shell uname -s | tr '[:upper:]' '[:lower:]') && \
		ARCH=$(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/') && \
		if [ "$${OS}" = "darwin" ]; then OS="macos"; fi && \
		curl -sSLo $(COSIGN) https://github.com/sigstore/cosign/releases/latest/download/cosign-$$OS-$${ARCH} ;\
		chmod +x $(COSIGN) ;\
	}
else
COSIGN = $(shell which cosign)
endif
endif

##@ infra

.PHONY:
kubedoop-base-build: jq ## Build kubedoop-base image
	.scripts/build.sh kubedoop-base

.PHONY:
kubedoop-base-buildx: jq ## Build kubedoop-base image with buildx
	.scripts/build.sh kubedoop-base --push

.PHONY:
vector-build: ## Build Vector image
	.scripts/build.sh vector

.PHONY:
vector-buildx: jq ## Build Vector image with buildx
	.scripts/build.sh vector --push

.PHONY:
helloworld-build: jq ## Build helloworld image
	.scripts/build.sh helloworld

.PHONY:
helloworld-buildx: jq ## Build helloworld image with buildx
	.scripts/build.sh helloworld --push

##@ develop environment

.PHONY:
go-devel-build: jq ## Build Go development image
	.scripts/build.sh go-devel

.PHONY:
go-devel-buildx: jq ## Build Go development image with buildx
	.scripts/build.sh go-devel --push

.PHONY:
java-base-build: jq ## Build Java base image
	.scripts/build.sh java-base

.PHONY:
java-base-buildx: jq ## Build Java base image with buildx
	.scripts/build.sh java-base --push

.PHONY:
java-devel-build: jq ## Build Java development image
	.scripts/build.sh java-devel

.PHONY:
java-devel-buildx: jq ## Build Java development image with buildx
	.scripts/build.sh java-devel --push

##@ tools

.PHONY:
krb5-build: jq ## Build krb5 image
	.scripts/build.sh krb5

.PHONY:
krb5-buildx: jq ## Build krb5 image with buildx
	.scripts/build.sh krb5 --push

.PHONY:
tools-build: jq ## Build tools image
	.scripts/build.sh tools

.PHONY:
tools-buildx: jq ## Build tools image with buildx
	.scripts/build.sh tools --push

.PHONY:
testing-tools-build: jq ## Build testing-tools image
	.scripts/build.sh testing-tools

.PHONY:
testing-tools-buildx: jq ## Build testing-tools image with buildx
	.scripts/build.sh testing-tools --push

##@ app

.PHONY:
airflow-build: jq ## Build Airflow image
	.scripts/build.sh airflow

.PHONY:
airflow-buildx: jq ## Build Airflow image with buildx
	.scripts/build.sh airflow --push

.PHONY:
dolphinscheduler-build: jq ## Build DolphinScheduler image
	.scripts/build.sh dolphinscheduler

.PHONY:
dolphinscheduler-buildx: jq ## Build DolphinScheduler image with buildx
	.scripts/build.sh dolphinscheduler --push

.PHONY:
hadoop-build: jq ## Build Hadoop image
	.scripts/build.sh hadoop

.PHONY:
hadoop-buildx: jq ## Build Hadoop image with buildx
	.scripts/build.sh hadoop --push

.PHONY:
hbase-build: jq ## Build HBase image
	.scripts/build.sh hbase

.PHONY:
hbase-buildx: jq ## Build HBase image with buildx
	.scripts/build.sh hbase --push

.PHONY:
hive-build: jq ## Build Hive image
	.scripts/build.sh hive

.PHONY:
hive-buildx: jq ## Build Hive image with buildx
	.scripts/build.sh hive --push

.PHONY:
zookeeper-build: jq ## Build Zookeeper image
	.scripts/build.sh zookeeper

.PHONY:
zookeeper-buildx: jq ## Build Zookeeper image with buildx
	.scripts/build.sh zookeeper --push

.PHONY:
kafka-build: jq ## Build Kafka image
	.scripts/build.sh kafka

.PHONY:
kafka-buildx: jq ## Build Kafka image with buildx
	.scripts/build.sh kafka --push

.PHONY:
spark-build: jq ## Build Spark image
	.scripts/build.sh spark

.PHONY:
spark-buildx: jq ## Build Spark image with buildx
	.scripts/build.sh spark --push

.PHONY:
superset-build: jq ## Build Superset image
	.scripts/build.sh superset

.PHONY:
superset-buildx: jq ## Build Superset image with buildx
	.scripts/build.sh superset --push

.PHONY:
trino-build: jq ## Build Trino image
	.scripts/build.sh trino

.PHONY:
trino-buildx: jq ## Build Trino image with buildx
	.scripts/build.sh trino --push

.PHONY:
nifi-build: jq ## Build Nifi image
	.scripts/build.sh nifi

.PHONY:
nifi-buildx: jq ## Build Nifi image with buildx
	.scripts/build.sh nifi --push
