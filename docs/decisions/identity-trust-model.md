# 0037 — Identity Trust Model

**Status:** Accepted
**Date:** 2026-05-16
**Updated:** 2026-05-17 (known limitations, Calico enforcement, Postgres role separation)

## Context

The gateway authenticates requests by reading `X-Forwarded-Email` and `X-Forwarded-User` headers. These headers are not cryptographically signed — any HTTP client that can reach the gateway on port 8080 can set them to any value.

This is the standard trust model for reverse-proxy architectures (Nginx + OAuth2 Proxy, Envoy + ext_authz, etc.). The proxy validates the user's OIDC token, then injects identity headers on the internal hop. The upstream service trusts the proxy, not the client.

The question is: how do we enforce that only the proxy can reach the gateway?

## Decision

Two mechanisms, no shared secrets.

### 1. Standalone proxy + NetworkPolicy isolation

OAuth2 Proxy runs as a standalone Deployment + Service (ADR 0040). Nginx routes all user-facing traffic to the proxy on port 4180. The proxy routes authenticated requests to backends by path prefix:

| Path prefix | Backend |
|:--|:--|
| `/api/*`, `/auth/*` | Gateway (:8080) |
| `/workbench/*` | Workbench (:8090) |
| `/oauth2/*` | Self (login/callback) |

NetworkPolicies restrict which pods can reach each backend:

| Hop | Enforced by |
|:--|:--|
| Client → OAuth2 Proxy (4180) | OIDC token validation |
| OAuth2 Proxy → Gateway (8080) | NetworkPolicy (only proxy pod allowed) |
| OAuth2 Proxy → Workbench (8090) | NetworkPolicy (only proxy pod allowed) |
| Internal pod → Gateway (8080) direct | NetworkPolicy (workbench pod allowed) |
| External pod → Gateway (8080) direct | Blocked by NetworkPolicy |

Internal services (workbench, agent tools) call the gateway directly on port 8080 with `X-Forwarded-Email` headers. NetworkPolicy restricts this to labeled pods only.

> **Note:** The direct gateway path trusts `X-Forwarded-Email` from in-cluster callers. Acceptable for single-tenant Kind deployments. For multi-user deployments, adopt [OBO token flow](agent-obo-flow.md) to enforce per-user RBAC on internal calls.

### 2. JWT validation for headless clients

Service-to-service callers (CI pipelines, agents, external tools) authenticate with JWT bearer tokens (ADR #0027). OAuth2 Proxy is configured with `--pass-access-token=true`. The gateway validates the JWT signature against the OIDC issuer's JWKS endpoint.

This provides per-request cryptographic proof of identity — no shared secrets, no rotation burden. Works regardless of deployment topology.

| Client type | Auth flow |
|:--|:--|
| Browser | OIDC authorization code → OAuth2 Proxy → `X-Forwarded-Email` |
| Headless / service | JWT bearer token → OAuth2 Proxy or direct → JWKS validation |

### Rejected: PROXY_SECRET

A shared static secret between proxy and gateway was considered and rejected:

- Requires manual rotation and pod restarts
- Single secret compromise grants full identity spoofing
- Redundant when NetworkPolicy already restricts source
- Does not provide per-request proof

### Development (no proxy)

In dev mode (`auth.oauth2Proxy.enabled: false` in Helm values), the gateway accepts `X-Forwarded-Email` from any caller. This allows:

- `curl -H "X-Forwarded-Email: dev@example.com"` for manual testing
- `test-headless.sh` integration tests
- Local `go run` debugging against `make infra-up`

Intentional and acceptable — dev cluster is local (Kind) with no external ingress.

## Consequences

- Gateway code never parses OIDC tokens directly for browser flows — identity is a header value from the trusted proxy.
- JWT validation adds JWKS endpoint dependency but eliminates all shared secrets.
- No secret rotation burden — NetworkPolicy is static, JWT keys rotate via OIDC provider.
- Misconfigured NetworkPolicies degrade the model — policy correctness remains critical.
- Dev mode is explicitly insecure. Production deployments must enable `auth.oauth2Proxy.enabled: true`.
- Standalone proxy eliminates the sidecar hairpin where workbench traffic looped through the gateway.

## Known Limitations

Security review (2026-05-17). Items below are acknowledged risks with documented mitigations or deferral rationale.

| Finding | Severity | Status |
|:---|:---|:---|
| Header spoofing without crypto proof | High | Mitigated by Calico NetworkPolicy. Full fix: mTLS or service JWT (deferred). |
| RBAC bypass via internal `X-Forwarded-Email` | High | Mitigated by NetworkPolicy. Full fix: OBO token flow (ADR 0038, deferred). |
| Static agent identity | Medium | Documented. Fix: workload identity or per-agent service accounts (deferred). |
| OAuth2 Proxy SPOF | Medium | Documented. Fix: replicas + PDB (production concern). |
| Dev mode = open | Critical if reachable | Acceptable for local-only Kind. Production MUST enable `auth.oauth2Proxy.enabled: true`. |
| Shared Postgres user | High | Fixed. Migration 017 creates `gateway_rw` and `workbench_rw` with schema-scoped grants. |

**Header spoofing.** Any pod that can reach the gateway on port 8080 can inject arbitrary `X-Forwarded-Email` headers. Calico CNI now enforces NetworkPolicies in Kind clusters, restricting gateway ingress to labeled pods (oauth2-proxy, workbench). For production, adopt mTLS or signed identity tokens on internal hops.

**Static agent identity.** The workbench and agent tools call the gateway with a static `X-Forwarded-Email` header (the user who initiated the session). The gateway cannot distinguish "user clicked a button" from "agent acted on user's behalf." This is acceptable for single-tenant POC. Multi-tenant deployments should adopt per-agent service accounts or the [OBO token flow](agent-obo-flow.md).

**OAuth2 Proxy availability.** The proxy is a single replica. If it crashes, all browser-based authentication fails. Headless JWT flows are unaffected (validated by the gateway directly). Production deployments should run 2+ replicas with a PodDisruptionBudget.

**Dev mode.** When `auth.oauth2Proxy.enabled: false`, the gateway accepts identity headers from any caller without validation. This is intentional for local Kind clusters with no external ingress. Never expose a dev-mode cluster to a network.

## Related

- [Standalone OAuth2 Proxy](standalone-auth-proxy.md) — deployment topology change
- [Kind + Helm as Sole Deployment Path](kind-only-deployment.md) — deployment topology
- ADR #0027 (complytime-core) — JWT bearer authentication for headless access
- [Authorization Model](authorization-model.md) — RBAC after identity is established
