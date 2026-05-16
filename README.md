# Studio Deploy

Central deployment repo for ComplyTime Studio. Orchestrates all three component repos for local development and deployment.

## Prerequisites

Clone all repos as siblings:

```
upstream-repos/
  complytime-core/      # Data Platform (Go gateway, MCP servers)
  studio-ui/            # Preact SPA + Nginx
  complytime-studio/    # Studio Workbench + AI agents
  studio-deploy/        # This repo
```

## Local Development

```bash
make build    # Build all images
make up       # Start the stack
make seed     # Seed demo data
```

Open [http://localhost:3000](http://localhost:3000).

## Services

| Service | Port | Source Repo |
|:--|:--|:--|
| Studio UI (Nginx) | 3000 | studio-ui |
| Data Platform (gateway) | 8080 | complytime-core |
| Studio Workbench + Agent | 8090 | complytime-studio |
| PostgreSQL | 5432 | -- |
| NATS | 4222 | -- |
| gemara-mcp | 3000 (internal) | complytime-core |
| complytime-mcp | 3000 (internal) | complytime-core |

## Architecture

```
Browser → localhost:3000 (Nginx)
            ├── /api/*        → gateway:8080   (Data Platform)
            ├── /auth/*       → gateway:8080
            ├── /workbench/*  → workbench:8090  (Studio Workbench)
            └── /*            → static SPA
```

## Kubernetes (Helm)

The Helm chart lives at `charts/complytime/`. It deploys the Data Platform, Studio Workbench, Studio UI, PostgreSQL, NATS, and MCP servers into a Kubernetes cluster.

```bash
make helm-template     # Dry-run — render templates locally
make helm-install      # Install into cluster (creates namespace)
make helm-upgrade      # Upgrade existing release
make helm-uninstall    # Remove release
```

Override values with `-f`:

```bash
helm install studio charts/complytime -n complytime --create-namespace -f my-values.yaml
```

## License

[Apache License 2.0](LICENSE)

