# SPDX-License-Identifier: Apache-2.0

CHART := charts/complytime
RELEASE := studio
NAMESPACE := complytime

.PHONY: up down build logs seed ps test-headless test-helm-headless test-api test-ui test-agents test-e2e helm-template helm-install helm-upgrade helm-uninstall

# --- Docker Compose (local dev) ---

up: ## Start the full stack
	docker compose up -d

down: ## Stop and remove containers
	docker compose down

build: ## Rebuild all images
	docker compose build

logs: ## Tail logs from all services
	docker compose logs -f

seed: ## Seed demo data into the gateway
	@echo "Waiting for gateway to be healthy..."
	@until curl -sf http://localhost:8080/healthz > /dev/null 2>&1; do sleep 2; done
	cd ../complytime-studio && make seed

ps: ## Show running services
	docker compose ps

# --- Headless Platform Tests ---

test-headless: ## Run headless API integration tests against a running gateway
	./test-headless.sh

test-api: test-headless test-helm-headless ## Run all API-layer tests

test-ui: ## Run Playwright E2E smoke tests against a running stack
	cd ../studio-ui && npx playwright test

test-agents: ## Run agent unit + workbench integration tests
	cd ../complytime-agents && make test

test-e2e: test-api test-agents test-ui ## Run all E2E test layers

test-helm-headless: ## Validate Helm renders without UI (studio.enabled=false)
	@helm template $(RELEASE) $(CHART) \
		--set studio.enabled=false \
		--set auth.oauth2Proxy.enabled=false \
		--set kagent.crdsAvailable=false > /dev/null \
		&& echo "✓ Helm headless render passed" \
		|| (echo "✗ Helm headless render failed" && exit 1)
	@helm template $(RELEASE) $(CHART) \
		--set studio.enabled=false \
		--set auth.oauth2Proxy.enabled=false \
		--set kagent.crdsAvailable=false 2>/dev/null | grep -c "studio-ui" | xargs test 0 -eq \
		&& echo "✓ No studio-ui resources in headless mode" \
		|| (echo "✗ studio-ui resources leaked into headless render" && exit 1)

# --- Helm (Kubernetes) ---

helm-template: ## Render chart templates locally
	helm template $(RELEASE) $(CHART)

helm-install: ## Install chart into cluster
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace

helm-upgrade: ## Upgrade existing release
	helm upgrade $(RELEASE) $(CHART) -n $(NAMESPACE) --reuse-values

helm-uninstall: ## Remove release from cluster
	helm uninstall $(RELEASE) -n $(NAMESPACE)
