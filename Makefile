# SPDX-License-Identifier: Apache-2.0

CHART := charts/complytime
RELEASE := studio
NAMESPACE := complytime

.PHONY: up down build logs seed ps helm-template helm-install helm-upgrade helm-uninstall

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

# --- Helm (Kubernetes) ---

helm-template: ## Render chart templates locally
	helm template $(RELEASE) $(CHART)

helm-install: ## Install chart into cluster
	helm install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace

helm-upgrade: ## Upgrade existing release
	helm upgrade $(RELEASE) $(CHART) -n $(NAMESPACE) --reuse-values

helm-uninstall: ## Remove release from cluster
	helm uninstall $(RELEASE) -n $(NAMESPACE)
