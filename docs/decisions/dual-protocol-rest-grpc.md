# 0042 — gRPC Streaming for Internal Data-Intensive Paths

**Status:** Proposed
**Date:** 2026-05-16

## Context

The gateway serves two consumer classes:

| Consumer | Examples | Needs |
|:---|:---|:---|
| External | Browser (via UI), CI pipelines, `curl`, external tools | REST/JSON, OpenAPI docs, broad compatibility |
| Internal | Workbench posture aggregation, agent tools, draft publish | Low latency, efficient bulk reads |

REST handles both today. The internal/external boundary is enforced by NetworkPolicy and OAuth2 Proxy (ADR 0040), not by transport.

Most internal API calls are small result sets (policies, catalogs, certifications) where REST with JSON is efficient. Two patterns would benefit from gRPC server-side streaming.

## Candidates

### Candidate 1: EvidenceService Streaming

**Problem:** Gap analysis is exhaustive. The agent must prove *absence* of evidence for each `(target, control, plan)` combination within an audit window. This requires scanning all evidence in scope — there is no short-circuit.

**Current REST flow:**
1. Gateway buffers all matching rows into a JSON array
2. Serializes the entire array
3. Agent downloads and deserializes the full payload
4. Agent starts processing row 1

For a policy with 10 targets, 50 controls, evaluated weekly over 90 days: ~45,000 evidence rows. Both gateway and agent buffer the full set in memory before processing begins.

**gRPC streaming alternative:**
1. Gateway reads one row from the Postgres cursor
2. Sends it immediately over a gRPC stream
3. Agent receives and classifies while gateway reads the next row
4. Peak memory: O(1) per side instead of O(N)
5. Built-in backpressure (HTTP/2 flow control) and cancellation

**Trigger:** Evidence volume per audit exceeds comfortable single-response size (~10K+ rows), or memory pressure becomes observable on agent pods.

### Candidate 2: PolicyCriteria Enumeration

**Problem:** Today the agent downloads the entire policy YAML and parses assessment plans, criteria, and control references client-side. If the gateway were to expose structured `ListPolicyCriteria(policy_id)` or `ListAssessmentPlans(policy_id)` endpoints, a policy with hundreds of criteria entries across catalogs would have the same exhaustive enumeration pattern as evidence.

**Trigger:** Decision to move YAML parsing responsibility from the agent to the gateway, exposing structured criteria as individual records.

## Decision

Deferred. REST is sufficient at POC scale. Proto definitions are retained in `proto/` as contract documentation for the future gRPC surface. No gRPC runtime, codegen, or Helm wiring is deployed.

When a trigger condition is met:

1. Implement the gRPC server in `internal/grpcapi/` alongside Echo (shared store interfaces)
2. Add `GRPC_PORT` env var and conditional listener in `cmd/gateway/main.go`
3. Generate Python stubs with `grpc_tools.protoc`
4. Add conditional gRPC transport in the corresponding `@tool` function
5. Enable via `gateway.grpc.enabled` in Helm values

## What stays

- Proto definitions in `proto/complytime/v1/` — contract documentation, no runtime cost
- `buf.yaml` — future codegen configuration
- Echo handlers for all REST endpoints — permanent external API

## What does NOT justify gRPC

| Endpoint | Why REST is sufficient |
|:---|:---|
| `list_policies` | Handful of results, no streaming benefit |
| `list_catalogs` | Small result sets |
| `get_certifications` | Moderate volume, pagination sufficient |
| `publish_audit_log` | Single-document write |
| `posture` / `risk-severity` | Aggregated results, small payloads |

## Related

- [Data Boundary Enforcement](data-boundary-enforcement.md) — workbench as pure API consumer of core
- [Drop MCP Data Proxies](drop-mcp-data-proxies.md) — agent tools replace MCP proxy layer
- [Standalone OAuth2 Proxy](standalone-auth-proxy.md) — network-level internal/external boundary
