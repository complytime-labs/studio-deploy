# 0041 — Drop MCP Data Proxies, Use LangChain Tools

**Status:** Proposed
**Date:** 2026-05-16

## Context

Three MCP servers are deployed via kagent MCPServer CRDs:

| Server | What it does | Unique logic? |
|:---|:---|:---|
| `complytime-mcp` | Proxies gateway REST endpoints as MCP resources/tools | No — pure pass-through with `X-Forwarded-Email` |
| `studio-oras-mcp` | OCI registry operations | Stubs only, not wired |
| `gemara-mcp` | CUE-based Gemara artifact validation and migration | Yes — third-party, unique capability |

`complytime-mcp` is a 200-line Go binary that translates MCP JSON-RPC calls into REST calls to the gateway. The agent calls MCP, MCP calls REST, REST calls Postgres. The MCP layer adds protocol translation overhead with no unique logic.

The agent already calls the gateway REST API directly for draft audit log publishing (`publish_audit_log` in `tools.py`). The MCP path is inconsistent with this pattern.

## Decision

### Drop

- **`complytime-mcp`** — delete the Go binary, MCPServer CRD, Helm template, and all `STUDIO_MCP_URL` env var references.
- **`studio-oras-mcp`** — delete the MCPServer CRD and Helm template. OCI operations are stubs.

### Keep

- **`gemara-mcp`** — third-party server providing CUE validation and migration. No equivalent exists in the codebase. Stays as an MCPServer CRD managed by kagent.

### Replace with LangChain tools

Agent data access becomes `@tool`-decorated Python functions that call the gateway API with `httpx` (REST today, gRPC when ADR 0042 is implemented).

```python
@tool
async def query_evidence(policy_id: str = "", limit: int = 100) -> str:
    """Query evidence records filtered by policy."""
    ...

@tool
async def list_policies() -> str:
    """List all imported policies."""
    ...

@tool
async def get_posture(policy_id: str = "") -> str:
    """Get compliance posture aggregates."""
    ...
```

### Gemara validation path

The agent continues calling gemara-mcp for `validate_gemara_artifact`. Two options:

1. **Direct MCP call** — agent uses `langchain_mcp_adapters` to connect to gemara-mcp. Single MCP connection instead of three.
2. **Workbench endpoint** — agent calls `/workbench/validate` (which wraps gemara-mcp). Simpler wiring, one fewer protocol.

Option 2 preferred — the workbench already has the endpoint wired.

## Consequences

- 2 fewer pods, 2 fewer MCPServer CRDs, 2 fewer services.
- `complytime-mcp` Go binary removed from `complytime-core`.
- `MultiServerMCPClient` wiring in `graph.py` simplified to single gemara-mcp connection (or eliminated if using workbench endpoint).
- Agent tools are plain Python — unit testable without MCP server infrastructure.
- `STUDIO_MCP_URL` and `ORAS_MCP_URL` env vars removed from workbench and assistant templates.
- kagent is still required for agent runtime (checkpointing, agent card) and gemara-mcp deployment.
- Loss of MCP interoperability for evidence data. Acceptable — the REST API is the external contract for headless consumers.

## Related

- [Data Boundary Enforcement](data-boundary-enforcement.md) — workbench as pure API consumer
- [Dual Protocol: REST + gRPC](dual-protocol-rest-grpc.md) — internal gRPC replaces REST-through-MCP
