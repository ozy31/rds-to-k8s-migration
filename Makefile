SHELL := /usr/bin/env bash
include versions.env
export

CLUSTER ?= db-migration

.PHONY: help cluster platform legacy postgres-test down lint

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

cluster: ## Create the kind cluster
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config kind/cluster.yaml --image $(KIND_NODE_IMAGE) --wait 2m

platform: ## cert-manager, CloudNativePG + Barman Cloud, MOCO, local S3
	platform/install.sh

legacy: ## The "RDS" instances: PostgreSQL and MySQL
	hack/ensure-secret.sh legacy legacy-pg-credentials POSTGRES_PASSWORD MASTER_PASSWORD MIGRATOR_PASSWORD APP_PASSWORD
	hack/ensure-secret.sh legacy legacy-mysql-credentials ROOT_PASSWORD ADMIN_PASSWORD REPL_PASSWORD APP_PASSWORD
	kubectl apply -f legacy/certificates.yaml
	kubectl -n legacy wait certificate --all --for=condition=Ready --timeout=2m
	kubectl apply -f legacy/postgres.yaml -f legacy/mysql.yaml
	kubectl -n legacy rollout status sts/legacy-pg --timeout=5m
	kubectl -n legacy rollout status sts/legacy-mysql --timeout=5m

postgres-test: ## Full PostgreSQL migration under load (copy, cutover, rollback, finalize, restore drill)
	tests/e2e/postgres.sh

down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

lint: ## yamllint and shellcheck
	yamllint -s -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}, comments: {min-spaces-from-content: 1}, braces: {max-spaces-inside: 1}}}' .
	shellcheck -x $$(git ls-files '*.sh')
