# SPDX-License-Identifier: Apache-2.0

-include .env
export

CHART := charts/complytime
RELEASE := studio
NAMESPACE := complytime
KIND_CLUSTER := complytime

# Sibling repo roots (override if layout differs)
STUDIO_REPO := ../complytime-core
UI_REPO := ../studio-ui
AGENTS_REPO := ../complytime-studio

# Images built from sibling repos
IMAGES := studio-gateway complytime-studio studio-workbench

# OIDC settings for helm-dev-auth: define in `.env` (included above) or export
# into the shell environment. Never pass OIDC_* as `make VAR=value` CLI
# overrides (shows up in shell history).

VALUES_DEV := -f $(CHART)/values-dev.yaml
VALUES_HEADLESS := $(VALUES_DEV) -f $(CHART)/values-headless.yaml
VALUES_DEV_AUTH := $(VALUES_DEV) -f $(CHART)/values-dev-auth.yaml
VALUES_GHCR := $(VALUES_DEV) -f $(CHART)/values-ghcr.yaml

.PHONY: help infra-up infra-down \
	kind-create kind-delete kind-build kind-load kind-reset \
	helm-headless helm-dev helm-dev-auth helm-ghcr helm-template helm-upgrade helm-uninstall \
	test-headless test-helm-headless test-api test-ui test-agents test-e2e

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Local infrastructure (for go run / python debugging) ---

infra-up: ## Start postgres + nats for local binary debugging
	docker compose up -d

infra-down: ## Stop infrastructure containers
	docker compose down

# --- Kind cluster lifecycle ---

CALICO_VERSION := v3.29.3
CALICO_MANIFEST := https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VERSION)/manifests/calico.yaml

kind-create: ## Create a kind cluster (Calico CNI for NetworkPolicy enforcement)
	kind create cluster --config kind.yaml
	kubectl apply -f $(CALICO_MANIFEST)
	kubectl -n kube-system wait --for=condition=Ready pods -l k8s-app=calico-node --timeout=90s

kind-delete: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

kind-build: ## Build all container images
	docker build -f $(STUDIO_REPO)/Dockerfile.gateway -t studio-gateway:latest $(STUDIO_REPO)
	docker build -f $(UI_REPO)/Dockerfile -t complytime-studio:latest $(UI_REPO)
	docker build -f $(AGENTS_REPO)/Dockerfile.workbench -t studio-workbench:latest $(AGENTS_REPO)

kind-load: ## Load images into the kind cluster (handles podman tag prefix)
	@for img in $(IMAGES); do \
		echo "Loading $$img:latest into kind..."; \
		kind load docker-image $$img:latest --name $(KIND_CLUSTER); \
		podman exec $(KIND_CLUSTER)-control-plane \
			ctr --namespace=k8s.io images tag \
			"localhost/$$img:latest" "docker.io/library/$$img:latest" 2>/dev/null || true; \
	done

kind-reset: kind-delete kind-create kind-build kind-load ## Recreate cluster with fresh images

# --- Helm profiles ---

helm-headless: ## Install headless profile (API-only, no auth)
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES_HEADLESS)

helm-dev: ## Install full dev profile (all components, no auth)
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES_DEV)

helm-ghcr: ## Install dev profile using published GHCR images
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES_GHCR)

helm-dev-auth: ## Dev+OAuth: OIDC_* from `.env`/env only (not make CLI args)
	@test -n "$(OIDC_ISSUER)" || (echo "OIDC_ISSUER: add to .env (.env.example)"; exit 1)
	@test -n "$(OIDC_CLIENT_ID)" || (echo "OIDC_CLIENT_ID: add to .env (.env.example)"; exit 1)
	@test -n "$(OIDC_CLIENT_SECRET)" || (echo "OIDC_CLIENT_SECRET in .env, not CLI"; exit 1)
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES_DEV_AUTH) \
		--set auth.oauth2Proxy.issuerUrl=$(OIDC_ISSUER) \
		--set auth.oauth2Proxy.clientId=$(OIDC_CLIENT_ID) \
		--set auth.oauth2Proxy.clientSecret=$(OIDC_CLIENT_SECRET)

helm-template: ## Render chart templates locally
	helm template $(RELEASE) $(CHART) $(VALUES_DEV)

helm-upgrade: ## Upgrade existing release
	helm upgrade $(RELEASE) $(CHART) -n $(NAMESPACE) --reuse-values

helm-uninstall: ## Remove release from cluster
	helm uninstall $(RELEASE) -n $(NAMESPACE)

# --- Tests ---

test-headless: ## Run headless API integration tests against a running gateway
	./test-headless.sh

test-api: test-headless test-helm-headless ## Run all API-layer tests

test-ui: ## Run Playwright E2E smoke tests against a running stack
	cd $(UI_REPO) && npx playwright test

test-agents: ## Run agent unit + workbench integration tests
	cd $(AGENTS_REPO) && make test

test-e2e: test-api test-agents test-ui ## Run all E2E test layers

test-helm-headless: ## Validate Helm renders without UI (studio.enabled=false)
	@helm template $(RELEASE) $(CHART) $(VALUES_HEADLESS) > /dev/null \
		&& echo "Helm headless render passed" \
		|| (echo "Helm headless render failed" && exit 1)
	@helm template $(RELEASE) $(CHART) $(VALUES_HEADLESS) 2>/dev/null | grep -c "studio-ui" | xargs test 0 -eq \
		&& echo "No studio-ui resources in headless mode" \
		|| (echo "studio-ui resources leaked into headless render" && exit 1)
