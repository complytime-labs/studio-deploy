# SPDX-License-Identifier: Apache-2.0

CHART := charts/complytime
RELEASE := studio
NAMESPACE := complytime
KIND_CLUSTER := complytime

# Sibling repo roots (override if layout differs)
STUDIO_REPO := ../complytime-studio
UI_REPO := ../studio-ui
AGENTS_REPO := ../complytime-agents

# Images built from sibling repos
IMAGES := studio-gateway complytime-studio studio-workbench complytime-mcp

# OIDC settings for dev-auth profile (pass via env or CLI)
OIDC_ISSUER ?=
OIDC_CLIENT_ID ?=
OIDC_CLIENT_SECRET ?=

VALUES_DEV := -f $(CHART)/values-dev.yaml
VALUES_HEADLESS := $(VALUES_DEV) -f $(CHART)/values-headless.yaml
VALUES_DEV_AUTH := $(VALUES_DEV) -f $(CHART)/values-dev-auth.yaml

.PHONY: help up down build logs seed ps \
	kind-create kind-delete kind-build kind-load kind-reset \
	helm-headless helm-dev helm-dev-auth helm-template helm-upgrade helm-uninstall \
	test-headless test-helm-headless test-api test-ui test-agents test-e2e

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Docker Compose (local dev) ---

up: ## Start the full stack (docker compose)
	docker compose up -d

down: ## Stop and remove containers
	docker compose down

build: ## Rebuild all images (docker compose)
	docker compose build

logs: ## Tail logs from all services
	docker compose logs -f

seed: ## Seed demo data into the gateway
	@echo "Waiting for gateway to be healthy..."
	@until curl -sf http://localhost:8080/healthz > /dev/null 2>&1; do sleep 2; done
	cd $(STUDIO_REPO) && make seed

ps: ## Show running services
	docker compose ps

# --- Kind cluster lifecycle ---

kind-create: ## Create a kind cluster
	kind create cluster --config kind.yaml

kind-delete: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

kind-build: ## Build all container images
	docker build -f $(STUDIO_REPO)/Dockerfile.gateway -t studio-gateway:latest $(STUDIO_REPO)
	docker build -f $(STUDIO_REPO)/Dockerfile.complytime-mcp -t complytime-mcp:latest $(STUDIO_REPO)
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

helm-dev-auth: ## Install dev + OAuth profile (requires OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET)
	@test -n "$(OIDC_ISSUER)" || (echo "Set OIDC_ISSUER"; exit 1)
	@test -n "$(OIDC_CLIENT_ID)" || (echo "Set OIDC_CLIENT_ID"; exit 1)
	@test -n "$(OIDC_CLIENT_SECRET)" || (echo "Set OIDC_CLIENT_SECRET"; exit 1)
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
		&& echo "✓ Helm headless render passed" \
		|| (echo "✗ Helm headless render failed" && exit 1)
	@helm template $(RELEASE) $(CHART) $(VALUES_HEADLESS) 2>/dev/null | grep -c "studio-ui" | xargs test 0 -eq \
		&& echo "✓ No studio-ui resources in headless mode" \
		|| (echo "✗ studio-ui resources leaked into headless render" && exit 1)
