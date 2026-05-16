# Studio Deploy

Deployment repo for ComplyTime Studio. Provides Helm charts for Kind/Kubernetes and minimal infrastructure compose for local binary debugging.

## Prerequisites

| Tool | Purpose |
|:--|:--|
| `kind` | Local Kubernetes cluster |
| `kubectl` | Cluster interaction |
| `helm` | Chart installation |
| `docker` or `podman` | Container builds |

Clone all repos as siblings:

```
upstream-repos/
  complytime-core/      # Data Platform (Go gateway, MCP servers)
  studio-ui/            # Preact SPA + Nginx
  complytime-studio/    # Studio Workbench + AI agents
  studio-deploy/        # This repo
```

## Full Stack (Kind + Helm)

```bash
# Create cluster, build images, load into Kind
make kind-reset

# Deploy with OIDC auth (any provider: Google, Dex, Keycloak)
make helm-dev-auth \
  OIDC_ISSUER=https://accounts.google.com \
  OIDC_CLIENT_ID=<your-client-id> \
  OIDC_CLIENT_SECRET=<your-client-secret>
```

Or store credentials in `.env` (see `.env.example`):

```bash
cp .env.example .env   # fill in values
source .env && make helm-dev-auth
```

Access via `kubectl port-forward`:

```bash
kubectl port-forward -n complytime svc/studio-ui 3000:80
kubectl port-forward -n complytime svc/studio-gateway 8080:8080
```

Open [http://localhost:3000](http://localhost:3000).

### Other Helm profiles

```bash
make helm-dev        # Full stack, no auth (OAuth2 Proxy disabled)
make helm-headless   # API-only, no UI, no auth (headless data platform)
```

## Infrastructure Only (Local Debugging)

For developers running gateway or workbench binaries directly:

```bash
make infra-up    # Start postgres + nats
make infra-down  # Stop
```

Connect your local binary to:

| Service | URL |
|:--|:--|
| PostgreSQL | `postgres://studio:complytime-dev@localhost:5432/studio?sslmode=disable` |
| NATS | `nats://localhost:4222` |

## Helm Chart

The chart lives at `charts/complytime/`. Additional commands:

```bash
make helm-template     # Dry-run render
make helm-upgrade      # Upgrade existing release
make helm-uninstall    # Remove release
```

Override values:

```bash
helm install studio charts/complytime -n complytime --create-namespace -f my-values.yaml
```

## Architecture

```
Browser → :3000 (Nginx)
            ├── /api/*        → OAuth2 Proxy → Gateway (localhost:8080 sidecar)
            ├── /auth/*       → OAuth2 Proxy → Gateway
            ├── /oauth2/*     → OAuth2 Proxy (OIDC callbacks)
            ├── /workbench/*  → Workbench (Studio Workbench + Agent)
            └── /*            → Static SPA
```

OAuth2 Proxy runs as a sidecar in the gateway Pod. The gateway binds to `127.0.0.1:8080` when auth is enabled, making it unreachable except through the proxy.

## License

[Apache License 2.0](LICENSE)
