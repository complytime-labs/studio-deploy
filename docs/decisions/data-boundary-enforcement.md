# 0039 — Data Boundary: Record-Level vs. Cross-Record Synthesis

**Status:** Accepted
**Date:** 2026-05-16

## Context

ADR 0032 established the core/workbench split and the rule "no service writes to another service's database." In practice, the boundary has two violations and one ambiguity:

1. **Cross-schema read:** Workbench queries `public.mapping_documents` directly for guidance catalog resolution instead of calling `GET /api/catalogs`.
2. **Misplaced aggregation:** `GET /api/posture` and `GET /api/risks/severity` live in the gateway but perform cross-record aggregation — joining evidence, certifications, controls, and risks across policies and targets. This is synthesis, not record access.
3. **Ambiguous ownership of `draft_audit_logs`:** ADR 0032 lists drafts under workbench, but the table lives in `public` and the gateway handles CRUD. Drafts are part of the audit trail — core's domain.

## Decision

### Boundary Definition

**complytime-core** answers: "What artifacts and records exist?"
- Stores and serves Gemara artifacts (policies, catalogs, mappings, evidence, threats, risks, controls, guidance)
- Certifies individual evidence records (schema, provenance, executor)
- Manages audit trail (draft and finalized audit logs)
- Manages users and RBAC
- All endpoints return stored records or single-record lookups — no cross-record joins for derived views

**complytime-studio (workbench)** answers: "What do the records mean together?"
- Programs: group policies into compliance lifecycle
- Posture aggregation: synthesize evidence, certifications, and risk data across policies and targets
- Risk severity summaries: derive per-policy risk profiles
- Recommendations: identify gaps from cross-cutting analysis
- Agent-driven audit production: orchestrate multi-step workflows
- Pure API consumer of core — zero direct SQL to `public` schema

### Migration

Migration proceeds in two phases to avoid breaking the data path.

**Phase A (current):** Routing redirect. UI calls workbench, workbench proxies to gateway.

| Item | Status | Current path |
|:---|:---|:---|
| `GET /workbench/posture` | Done | Proxies to `GET /api/posture` on gateway |
| `GET /workbench/risks/severity` | Done | Proxies to `GET /api/risks/severity` on gateway |
| `public.mapping_documents` read | Done | Replaced with `GET /api/catalogs` via `httpx` |

Gateway retains `/api/posture` and `/api/risks/severity` as internal endpoints consumed only by the workbench. Not advertised in OpenAPI or documented for external consumers.

**Phase B (target):** Full aggregation. Workbench implements its own logic.

| Item | Method |
|:---|:---|
| `GET /workbench/posture` | Workbench calls `GET /api/evidence`, `GET /api/certifications`, aggregates in Python |
| `GET /workbench/risks/severity` | Workbench calls `GET /api/risks`, `GET /api/control-threats`, derives severity |
| Gateway posture/risk-severity | Remove from gateway once Phase B is complete |

### Retained in Core

`draft_audit_logs` stays in the `public` schema. Drafts are part of the audit trail, not program management. The workbench POSTs drafts via `POST /api/draft-audit-logs` — it never reads or writes the table directly.

### Enforcement Rules

1. Workbench process must not hold a connection to the `public` schema. The `workbench` Postgres role should have `USAGE` on `workbench` schema only, with no grants on `public`.
2. All compliance data access from workbench goes through gateway REST API (`http://studio-gateway:8080`). NetworkPolicy restricts which pods can reach the gateway directly (ADR 0040).
3. Core endpoints must remain single-record or flat filtered queries. If a new endpoint requires joining across multiple entity types to produce a derived view, it belongs in the workbench.
4. The litmus test: "Could a headless API consumer (CI pipeline, external tool) use this endpoint without caring about programs or audit workflows?" If yes, it belongs in core. If no, workbench.

## Consequences

- Workbench becomes a pure API consumer. Core could be swapped for a managed service or external provider.
- Posture and risk endpoints move from `/api/*` to `/workbench/*`. UI components that call these must update their paths.
- Workbench latency for posture increases slightly (HTTP round-trip to core vs. direct SQL). Acceptable for dashboard views; cacheable if needed.
- The `workbench` Postgres role grant in migration 016 (`SELECT` on `workbench` schema for `studio_reader`) remains valid. The `public` schema grants for the workbench role should be revoked.
- Future: core could run as a separate Postgres instance entirely — the workbench has no dependency on shared database state.

## Related

- [Architecture Extraction](architecture-extraction.md) — original core/workbench split
- [Agent On-Behalf-Of Token Flow](agent-obo-flow.md) — service-to-service auth for API calls
- [Standalone OAuth2 Proxy](standalone-auth-proxy.md) — proxy routes traffic; workbench calls gateway directly
- [Identity Trust Model](identity-trust-model.md) — NetworkPolicy-based auth model
