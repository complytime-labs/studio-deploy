# 0042 — Dual Protocol: REST External, gRPC Internal

**Status:** Proposed
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

The gateway exposes two ports:

| Port | Protocol | Consumers | Contract |
|:---|:---|:---|:---|
| 8080 | REST/JSON | External: browser, CI, headless tools | OpenAPI spec (generated from proto) |
| 9090 | gRPC | Internal: workbench, agent tools | Protobuf service definitions |

### Proto definitions as single source of truth

```
proto/
  complytime/v1/
    evidence.proto      # EvidenceService
    policies.proto      # PolicyService
    catalogs.proto      # CatalogService
    audit.proto         # AuditService
    certifications.proto
    threats.proto
    risks.proto
```

### REST generation

Use [grpc-gateway](https://github.com/grpc-ecosystem/grpc-gateway) to generate REST handlers from proto definitions with `google.api.http` annotations. The REST API becomes a thin layer over gRPC — one implementation, two protocols.

### gRPC services (initial scope)

```protobuf
service EvidenceService {
  rpc QueryEvidence(QueryEvidenceRequest) returns (stream EvidenceRecord);
  rpc GetCertifications(GetCertificationsRequest) returns (CertificationsResponse);
}

service PolicyService {
  rpc ListPolicies(ListPoliciesRequest) returns (ListPoliciesResponse);
  rpc GetPolicy(GetPolicyRequest) returns (Policy);
}

service AuditService {
  rpc CreateDraftAuditLog(CreateDraftRequest) returns (CreateDraftResponse);
  rpc ListDraftAuditLogs(ListDraftsRequest) returns (ListDraftsResponse);
  rpc PromoteDraft(PromoteDraftRequest) returns (PromoteDraftResponse);
}

service CatalogService {
  rpc ListCatalogs(ListCatalogsRequest) returns (ListCatalogsResponse);
}
```

### Client generation

- **Python (workbench/agent):** `grpcio-tools` generates typed stubs. Agent `@tool` functions call gRPC stubs instead of `httpx`.
- **Go (gateway):** Server implementation generated from proto. Replaces hand-written Echo handlers.

### Migration path

1. Define proto files for core data types
2. Implement gRPC server in gateway alongside existing REST handlers
3. Generate REST gateway from protos (replaces hand-written REST handlers incrementally)
4. Migrate workbench and agent tools from `httpx` REST to gRPC stubs
5. Remove hand-written REST handlers once grpc-gateway covers all endpoints

### Auth on gRPC

gRPC metadata carries `x-forwarded-email` (same as REST headers). Gateway middleware reads metadata instead of HTTP headers. Same RBAC logic, different transport.

## Consequences

- Proto definitions enforce contracts at compile time across Go and Python.
- Streaming evidence queries reduce memory pressure on both client and server.
- REST API maintained automatically via grpc-gateway — no drift between protocols.
- Build tooling overhead: `protoc`, `buf`, CI proto generation.
- Echo framework potentially replaced by grpc-gateway for REST. Incremental migration avoids big-bang rewrite.
- External consumers see no change — REST API stays identical, just generated from protos instead of hand-written.
- Internal consumers get typed stubs with IDE autocomplete and compile-time validation.

## Implementation phases

| Phase | Scope | Depends on |
|:---|:---|:---|
| 1 | Proto definitions + gRPC server for evidence + policies | — |
| 2 | grpc-gateway REST generation, run alongside Echo | Phase 1 |
| 3 | Python gRPC stubs in workbench/agent, replace httpx calls | Phase 1 |
| 4 | Migrate remaining endpoints (audit, catalogs, threats, risks) | Phase 2 |
| 5 | Remove Echo handlers, grpc-gateway is sole REST source | Phase 4 |

## Related

- [Data Boundary Enforcement](data-boundary-enforcement.md) — workbench as pure API consumer of core
- [Drop MCP Data Proxies](drop-mcp-data-proxies.md) — agent tools replace MCP proxy layer
- [Standalone OAuth2 Proxy](standalone-auth-proxy.md) — simplified network topology
