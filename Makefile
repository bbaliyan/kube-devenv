SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

SCRIPTS := $(shell find scripts checks tests .github/scripts -type f -name '*.sh' -o -type f -path 'scripts/kube-*' -o -type f -path scripts/select-cluster | sort -u)
IMAGE   ?= kube-devenv:local

.PHONY: test-commit test-checks test-integration lint-shell lint-dockerfile secrets pipeline-lint

test-commit: lint-shell lint-dockerfile secrets pipeline-lint

lint-shell:
	shellcheck -S warning $(SCRIPTS)

lint-dockerfile:
	hadolint Dockerfile

secrets:
	checks/secrets.sh .

pipeline-lint:
	checks/pipeline-lint.sh .

test-checks:
	tests/checks.sh

test-integration:
	docker build -t $(IMAGE) .
	docker run --rm -v "$(CURDIR)":/workspace $(IMAGE) make test-checks
