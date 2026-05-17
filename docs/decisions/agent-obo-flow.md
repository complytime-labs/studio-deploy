# 0038 — On-Behalf-Of Token Flow for Agent MCP Servers

**Status:** Proposed (deferred)
**Date:** 2026-05-16

## Context

MCP servers (`complytime-mcp`, `gemara-mcp`, `oras-mcp`) query the gateway on behalf of the user who initiated a Studio Chat session. Today they authenticate with a static service identity (`X-Forwarded-Email: studio-mcp@complytime.dev`) over the internal service port (8081), bypassing OAuth2 Proxy entirely.

This works but has three gaps:

| Gap | Impact |
|:---|:---|
| No per-user RBAC enforcement | Agent sees all data regardless of the user's role |
| No audit attribution | Gateway audit logs attribute every MCP query to the service account, not the human |
| Privilege escalation risk | A `reviewer` user's chat session can trigger queries that only `admin` should access |

## Decision (Proposed)

Implement On-Behalf-Of (OBO) token propagation:

```
Browser → OAuth2 Proxy → Gateway → Workbench → MCP Server → Gateway
                                   (forwards user's access token)
```

### Token flow

1. OAuth2 Proxy validates the OIDC token and sets `X-Forwarded-Access-Token` on the request to the gateway.
2. Gateway forwards the access token to the workbench via the reverse proxy.
3. Workbench stores the token in the LangGraph thread context.
4. When the agent invokes an MCP tool, the workbench passes the token in the `Authorization: Bearer <token>` header.
5. MCP server forwards the bearer token to the gateway on port 8080 (via OAuth2 Proxy) or validates it directly.
6. Gateway validates the JWT and applies RBAC for the original user.

### Transport change

MCP servers must switch from `stdio` to `http` transport. `stdio` shares a process boundary — no mechanism to pass per-request auth headers. `http` transport enables `Authorization` header propagation on each tool call.

### Scope

All three MCP servers should use OBO. Gemara and ORAS servers may access user-scoped registry data in future.

## Consequences

- MCP servers no longer need a static service identity.
- Gateway audit logs attribute every query to the real user.
- RBAC is enforced end-to-end.
- Requires kagent `http` transport support and workbench token-forwarding plumbing.
- Token expiry during long chat sessions needs refresh handling.

## Why Deferred

The functional test cycle is in progress. The current service-identity model is sufficient for local Kind clusters with no external ingress. OBO should be implemented before any multi-user or external deployment.

## Related

- [Identity Trust Model](identity-trust-model.md) — current auth architecture
- ADR #0027 (complytime-core) — JWT bearer authentication
- [Authorization Model](authorization-model.md) — RBAC after identity is established
