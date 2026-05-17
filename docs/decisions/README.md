# Architecture Decision Records

Decisions specific to deployment, infrastructure, and cross-cutting auth.
Platform decisions live in [complytime-core](https://github.com/complytime-labs/complytime-core/tree/main/docs/decisions).

## Active

| # | Decision | Status | Date |
|:--|:--|:--|:--|
| 0032 | [Architecture Extraction — Core + Studio](architecture-extraction.md) | Accepted | 2026-05-15 |
| 0035 | [Kind + Helm as Sole Deployment Path](kind-only-deployment.md) | Accepted | 2026-05-16 |
| 0037 | [Identity Trust Model](identity-trust-model.md) | Accepted | 2026-05-16 |
| 0039 | [Data Boundary: Record-Level vs. Cross-Record Synthesis](data-boundary-enforcement.md) | Accepted | 2026-05-16 |
| 0040 | [Standalone OAuth2 Proxy](standalone-auth-proxy.md) | Accepted | 2026-05-16 |

## Proposed / Deferred

| # | Decision | Status | Date |
|:--|:--|:--|:--|
| 0038 | [Agent On-Behalf-Of Token Flow](agent-obo-flow.md) | Proposed | 2026-05-16 |
| 0041 | [Drop MCP Data Proxies, Use LangChain Tools](drop-mcp-data-proxies.md) | Proposed | 2026-05-16 |
| 0042 | [Dual Protocol: REST + gRPC](dual-protocol-rest-grpc.md) | Proposed | 2026-05-16 |

## Superseded / Deferred

| Decision | Status |
|:--|:--|
| [Authorization Model: RACI-Scoped](authorization-model.md) | Superseded — simple admin/reviewer RBAC for now |
| [Session Persistence Storage](session-persistence-storage.md) | Accepted — in-memory, moves to durable with auth |
| [Session Token Storage](session-token-storage.md) | Proposed — not implemented |
