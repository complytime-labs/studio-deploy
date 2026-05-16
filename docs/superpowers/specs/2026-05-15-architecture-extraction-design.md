# ComplyTime Architecture Extraction

## Context

Two groups need different functionality from the same system:
- **Group 1** needs a standalone evidence API — headless data platform, no UI, no programs.
- **Group 2** needs a full audit workbench — programs, coverage analysis, agent-driven audit production, UI.

The former monolith (`complytime-studio`, Go) split into `complytime-core` (data platform) and `complytime-studio` (Python workbench, formerly `complytime-agents`). This spec records the target architecture and contracts; the extraction is complete.

## Repos

| Repo | Role | Language |
|:---|:---|:---|
| `complytime-core` | Evidence data platform. Self-contained, self-deploying. Includes NATS and `complytime-mcp`. | Go |
| `complytime-studio` | Audit workbench + agent + workbench MCP (`studio-mcp`). | Python |
| `studio-ui` | Preact SPA. Primary client of the workbench. | TypeScript |
| `studio-deploy` | Full stack composition (core + studio + UI). | YAML |

`complytime-core` is the former Go `complytime-studio` repo (`github.com/complytime-labs/complytime-core`). `complytime-studio` is the former `complytime-agents` workbench repo (`github.com/complytime-labs/complytime-studio`). `studio-ui` stays as its own repo. `studio-deploy` composes them.

## Architecture

```
                    ┌─────────────────┐
                    │    studio-ui    │
                    └───────┬─────────┘
                            │
              ┌─────────────┴──────────────┐
              │ primary                data │
              │ backend            explore  │
              ▼                            ▼
   ┌──────────────────┐        ┌──────────────────┐
   │ complytime-studio │        │  complytime-core  │
   │   (workbench)     │───────▶│  (data platform)  │
   │                   │ REST   │                   │
   │  studio-mcp       │        │  complytime-mcp   │
   └────────┬──────────┘        └──────────┬────────┘
            │                              │
   ┌────────┴──────────┐        ┌──────────┴────────┐
   │   workbench DB    │        │     core DB       │
   └───────────────────┘        └───────────────────┘
            │                              │
            └──────── PostgreSQL ───────────┘
```

## Data Ownership

Two databases in one Postgres instance. No cross-database queries. All cross-service data flows go through APIs.

### core DB (complytime-core)

Owner: `complytime-core` gateway.

Tables: `policies`, `evidence`, `catalogs`, `controls`, `assessment_requirements`, `mapping_documents`, `mapping_entries`, `threats`, `risks`, `risk_threats`, `control_threats`, `certifications`, `evidence_assessments`, `audit_logs` (finalized), `users`, `role_changes`, `guidance_entries`.

Access by others: REST (`/api/*`), MCP (`complytime-mcp`), SQL (`studio_reader` role).

### workbench DB (complytime-studio)

Owner: `complytime-studio` workbench.

Tables: `programs`, `jobs`, `program_members`, `program_findings`, `draft_audit_logs`, LangGraph checkpoint tables. Future: `coverage_snapshots`, `recommendation_state`.

Access by others: REST (`/workbench/*`), MCP (`studio-mcp`).

## Serving Layer

### complytime-core

| Protocol | Surface | Clients |
|:---|:---|:---|
| REST `/api/*` | Full CRUD. Evidence ingest (`POST /api/ingest`), policy import, finalized audit logs. | UI (data exploration), workbench (reads + audit log promotion), CI/services |
| MCP `complytime-mcp` | Complete evidence read surface. Resource URI prefix: `complytime://`. 13 static resources, 5 templates, `query_evidence` tool. No write tools. | Agent, Claude Desktop, Cursor |
| SQL `studio_reader` | SELECT-only Postgres role on core DB only. | Grafana, Metabase, ad-hoc |

### complytime-studio (workbench)

| Protocol | Surface | Clients |
|:---|:---|:---|
| REST `/workbench/*` | Programs CRUD, draft audit logs, coverage queries, recommendations, agent directory, A2A proxy, Gemara validate/migrate. | UI (primary backend), agent |
| MCP `studio-mcp` | Resource URI prefix: `studio://`. Program resources, draft audit log resources, `save_draft_audit_log` tool, `query_coverage` tool, `query_gaps` tool. | Agent, external MCP hosts |

## Evidence Quality Boundary

### Data platform certifier (per-record, deterministic, runs on every ingest)

| Certifier | Check | Data needed |
|:---|:---|:---|
| schema | Required fields, valid enums, timestamps not zero/future | Evidence record |
| provenance | Known registry, attestation ref, engine allowlist | Evidence record |
| freshness (basic) | `collected_at` not future, not older than configurable max age | Evidence record |
| freshness (policy-aware) | Evidence current within policy's compliance window | Evidence + policy |
| relevance | Evidence maps to a valid control/requirement in its declared policy | Evidence + policy + requirements |

### Workbench / Agent (cumulative, on-demand)

| Analysis | Scope |
|:---|:---|
| Coverage | All requirements in a policy covered by evidence? |
| Sufficiency | Program thresholds met? |
| Gap detection | Which requirements lack evidence? |
| Consistency | Conflicting results across sources? |
| Program readiness | Timeline, team, workflow status |

Boundary: data platform answers "is this record trustworthy and applicable?" Workbench answers "do we have enough good evidence to pass?"

## Draft Audit Log Lifecycle

```
Agent produces draft
  → POST /workbench/draft-audit-logs (workbench DB)
  → Human reviews in UI
  → Reviewer approves
  → Workbench promotes: POST /api/audit-logs (core DB)
  → Finalized audit log is permanent, queryable via REST/MCP/SQL
```

`save_draft_audit_log` lives in `studio-mcp` (workbench), not `complytime-mcp` (core). The agent writes drafts to the workbench. Promotion publishes the finalized log to the data platform.

## Agent Boundary (Soft)

The agent and workbench are co-located in `complytime-studio`. Separation enforced in code, not infrastructure.

**Rules:**
- No shared Python imports between `agents/assistant/` and `workbench/`.
- Agent communicates via MCP (`complytime-mcp`, `studio-mcp`, `gemara-mcp`). No in-process function calls to workbench.
- Separate `requirements.txt` files.
- Agent uses `workbench` DB for LangGraph checkpoints only.
- Separate Dockerfiles ready (`Dockerfile.agent`, `Dockerfile.workbench`). Combined entrypoint today.

**Split triggers:** independent scaling, GPU requirement, security boundary, divergent release cycles.

## Contracts Between Services

| From | To | Protocol | Scope |
|:---|:---|:---|:---|
| Agent → Core | MCP (`complytime-mcp`) | Read evidence, policies, posture, catalogs. No writes. |
| Agent → Workbench | MCP (`studio-mcp`) | Read programs, write draft audit logs, query coverage/gaps. |
| Agent → Gemara | MCP (`gemara-mcp`) | Schema validation, artifact migration. |
| Agent → ORAS | MCP (`oras-mcp`) | OCI registry operations (publish, browse). |
| Workbench → Core | REST (`/api/*`) | Read evidence/policies for program-scoped queries. Promote finalized audit logs. |
| UI → Workbench | REST (`/workbench/*`) | Programs, drafts, coverage, recommendations. Primary backend. |
| UI → Core | REST (`/api/*`) | Data exploration (evidence browse, policy list, catalog view). |
| Grafana → Core | SQL (`studio_reader`) | SELECT-only on core DB. |

**Hard rule:** No service writes to another service's database.

## Delivery Priority

| Priority | Action | Serves |
|:---|:---|:---|
| 1 | `complytime-core` self-deploying (Helm chart, standalone Compose, program coupling removed where applicable) | Group 1 |
| 2 | Programs + drafts on `complytime-studio` workbench (Python DB layer, REST, migrations) | Group 2 |
| 3 | Workbench `studio-mcp` for agent program access | Group 2 |
| 4 | `studio-deploy` composes core + studio | Group 2 |
| 5 | Add policy-aware freshness and relevance certifiers to core | Both |
| 6 | `studio-ui` routes program calls to workbench | Group 2 |

**Done:** Repo and MCP naming, `studio-deploy` composition, canonical ingest `POST /api/ingest` (obsolete routes under `/api/evidence/` for sync/async ingest removed).

**Tracked work:** Priority 5 (policy-aware certifiers). Priorities 1–4 describe the landed split; prioritize against the live gateway and Helm chart rather than this table alone.

## Migration from Current State

### Repo renames (done)
- `complytime-studio` (Go data platform) → `complytime-core` (`github.com/complytime-labs/complytime-core`)
- `complytime-agents` (Python workbench) → `complytime-studio` (`github.com/complytime-labs/complytime-studio`)

Core MCP naming: former core `studio-mcp` binary is now `complytime-mcp` (resource prefix `complytime://`). Workbench MCP remains `studio-mcp` (`studio://`).

### What moved
- Program Go handlers (`internal/store/handlers_programs.go`, `internal/store/inventory.go` program_id logic) → Python in `complytime-studio`
- Program migrations (`005_programs.sql`, `009_program_members.sql`, `010_program_findings.sql`, `012_program_score_pct.sql`) → Python migrations in `complytime-studio`
- Draft audit log handlers → Python in `complytime-studio`
- `save_draft_audit_log` MCP tool → workbench `studio-mcp`; removed from core `complytime-mcp`

### What stayed
- Evidence, policy, catalog, mapping, threat, risk, certification code remains in `complytime-core`
- `complytime-mcp` in `complytime-core`: read-only data surface (`save_draft_audit_log` not on core MCP)
- Certifier pipeline stays in `complytime-core`
- `studio-ui` remains its own repo; API routes updated for workbench vs core

### Deferred

- **ClickHouse activation** — Evidence storage scales from Postgres to ClickHouse via `pg_clickhouse` FDW. Remains a core concern. Trigger: evidence volume exceeds Postgres capacity. Helm values already wired.

### Follow-on cleanup (complytime-core)
- Remove program routes, handlers, store interfaces from gateway
- Remove `program_id` parameter from `GET /api/inventory`
- Remove program migrations (tables no longer created by core)
- Remove `save_draft_audit_log` from `complytime-mcp`
- Update OpenAPI spec
