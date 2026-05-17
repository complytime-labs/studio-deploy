# ADR 0032: Architecture Extraction — Core + Studio

**Status:** Accepted
**Date:** 2026-05-15
**Updated:** 2026-05-17 (superseded sections noted)

## Context

Two user groups need different functionality:
- **Group 1** needs a standalone evidence API — headless data platform, no UI, no programs.
- **Group 2** needs a full audit workbench — programs, coverage analysis, agent-driven audit production, UI.

The monolith conflates the data platform with the workbench. Serving Group 1 requires deploying program tables, agent dependencies, and UI routes they do not use.

## Decision

Extract the system into two independent products that compose together.

| Repo | Role | Language |
|:---|:---|:---|
| `complytime-core` | Evidence data platform. Self-contained, self-deploying. | Go |
| `complytime-studio` | Audit workbench + agent. | Python |
| `studio-ui` | Preact SPA. Primary client of the workbench. | TypeScript |
| `studio-deploy` | Full stack composition (core + studio + UI). | YAML |

> **Update (2026-05-17):** `complytime-mcp` and `studio-mcp` were removed per [ADR 0041](drop-mcp-data-proxies.md). Agent tools now call the gateway REST API directly via `@tool`-decorated functions. Only `gemara-mcp` (CUE validation) is retained.

### Data Ownership

Two databases in one Postgres instance. No cross-database queries. All cross-service data flows through APIs.

**core DB:** policies, evidence, catalogs, controls, assessment_requirements, mapping_documents, mapping_entries, threats, risks, risk_threats, control_threats, certifications, evidence_assessments, audit_logs (finalized), users, role_changes, guidance_entries.

**workbench DB:** programs, jobs, program_members, program_findings, draft_audit_logs, LangGraph checkpoints. Future: coverage_snapshots, recommendation_state.

### Serving Contracts

**complytime-core:** REST `/api/*` (full CRUD), SQL `gateway_rw` role (public schema), SQL `studio_reader` role (SELECT-only).

**complytime-studio:** REST `/workbench/*` (programs, drafts, coverage), SQL `workbench_rw` role (workbench schema).

> **Update (2026-05-17):** MCP serving contracts (`complytime-mcp`, `studio-mcp`) removed per [ADR 0041](drop-mcp-data-proxies.md). Postgres roles updated from shared `studio` user to schema-scoped `gateway_rw` / `workbench_rw` per identity trust model hardening.

### Hard Rule

No service writes to another service's database.

## Consequences

- Group 1 can deploy `complytime-core` alone without workbench/agent/UI overhead.
- Group 2 composes both via `studio-deploy`.
- Program migration requires rewriting Go handlers in Python (workbench owns programs now).
- Agent communicates via REST `@tool` functions calling the gateway API directly. Only `gemara-mcp` retained for CUE validation ([ADR 0041](drop-mcp-data-proxies.md)).
