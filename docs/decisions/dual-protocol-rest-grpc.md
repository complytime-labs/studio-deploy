# 0042 — Dual Protocol: REST External, gRPC Internal

**Status:** Accepted
**Date:** 2026-05-16

## Context

ADR 0039 established that the workbench is a pure API consumer of core. ADR 0041 replaces MCP data proxies with direct API calls. The gateway now serves two distinct consumer classes:

| Consumer | Examples | Needs |
|:---|:---|:---|
| External | Browser (via UI), CI pipelines, `curl`, external tools | REST/JSON, OpenAPI docs, broad compatibility |
| Internal | Workbench posture aggregation, agent tools, draft publish | Typed contracts, streaming for large result sets, low latency |

Both consumer classes currently use REST. This works but has gaps:

- No compile-time contract enforcement between Go (gateway) and Python (workbench/agent)
- Evidence queries can return thousands of rows — REST pagination works but streaming is more efficient
- JSON serialization overhead on internal hot paths (posture recalculation)
- API contract changes are caught by integration tests, not at build time

## Decision

Echo (Go) serves external REST permanently. gRPC is additive for internal consumers. Both coexist on separate ports.

| Port | Protocol | Framework | Consumers | Contract |
|:---|:---|:---|:---|:---|
| 8080 | REST/JSON | Echo | External: browser, CI, headless tools | OpenAPI spec (hand-maintained) |
| 9090 | gRPC | google.golang.org/grpc | Internal: workbench, agent tools | Protobuf service definitions |

### Why not grpc-gateway?

grpc-gateway generates REST from proto definitions, but adopting it means replacing Echo — our mature REST framework with custom middleware (auth, CORS, body limits, write-protection). That replacement carries high risk for low reward:

- External consumers already work with the Echo-based REST API
- OpenAPI spec is hand-maintained and aligned with the Echo handlers
- Middleware logic (writeProtect, auth, degraded-mode) would need to be reimplemented for grpc-gateway
- The benefit of gRPC is for internal consumers, not external REST

### Proto definitions

```
proto/
  complytime/v1/
    evidence.proto      # EvidenceService
    policies.proto      # PolicyService
    catalogs.proto      # CatalogService
    audit.proto         # AuditService
```

No `google.api.http` annotations. Protos define gRPC contracts only.

### gRPC server

The gateway conditionally starts a gRPC listener on `GRPC_PORT` (default 9090) alongside the Echo HTTP server. Both share the same store layer. Graceful shutdown covers both listeners.

### Client generation

- **Go (gateway):** `buf generate` produces server stubs. Implementation delegates to `store.PolicyStore` / `store.MappingStore` (same interfaces as Echo handlers).
- **Python (workbench/agent):** `grpc_tools.protoc` generates typed stubs matching the installed protobuf runtime. Agent `@tool` functions conditionally use gRPC when `GATEWAY_GRPC_URL` is set, falling back to REST.

### Auth on gRPC

gRPC metadata carries `x-forwarded-email` (same as REST headers). The gRPC port is restricted by NetworkPolicy to in-cluster consumers only. Same trust model as direct REST calls from workbench to gateway (ADR 0035).

## Implementation status

| Service | gRPC server | Python stub | Agent tool wired |
|:---|:---|:---|:---|
| PolicyService | Done | Done | `list_policies` — conditional gRPC/REST |
| EvidenceService | Pending | Pending | `query_evidence` — REST only |
| AuditService | Pending | Pending | `publish_audit_log` — REST only |
| CatalogService | Pending | Pending | `list_catalogs` — REST only |

### Migration checklist

Each service follows the same pattern:

1. Implement `XxxServer` in `internal/grpcapi/` delegating to store interfaces
2. Register in `grpcapi.NewServer()`
3. Set health status for the service
4. Generate Python stubs with `grpc_tools.protoc`
5. Copy stubs to `complytime-studio/complytime/v1/`
6. Add conditional gRPC transport in the corresponding `@tool` function
7. Add unit tests for the gRPC server

### Endpoints NOT migrated to gRPC

These stay REST-only (Echo handlers):

| Endpoint | Reason |
|:---|:---|
| `/api/ingest` | Multi-part upload + NATS pipeline, no gRPC consumer |
| `/api/posture`, `/api/risks/severity` | Internal proxy targets (ADR 0039 Phase A), temporary |
| `/api/import` | OCI pull + parsing pipeline, no gRPC consumer |
| `/api/system-info` | Diagnostic only |
| `/healthz` | HTTP health check convention |
| `/auth/*` | OAuth2 flow, browser-facing |

## Consequences

- Proto definitions enforce contracts at compile time across Go and Python.
- Streaming evidence queries reduce memory pressure on both client and server.
- Echo framework is retained — no migration risk on the REST side.
- External consumers see no change.
- Internal consumers get typed stubs with IDE autocomplete and compile-time validation.
- Build tooling overhead: `buf`, `grpc_tools.protoc`, CI proto generation.
- Two transports to maintain (Echo + gRPC), but they share store interfaces.

## Related

- [Data Boundary Enforcement](data-boundary-enforcement.md) — workbench as pure API consumer of core
- [Drop MCP Data Proxies](drop-mcp-data-proxies.md) — agent tools replace MCP proxy layer
- [Standalone OAuth2 Proxy](standalone-auth-proxy.md) — simplified network topology
