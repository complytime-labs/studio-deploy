# 0037 — Identity Trust Model

**Status:** Accepted
**Date:** 2026-05-16

## Context

The gateway authenticates requests by reading `X-Forwarded-Email` and `X-Forwarded-User` headers. These headers are not cryptographically signed — any HTTP client that can reach the gateway on port 8080 can set them to any value.

This is the standard trust model for reverse-proxy architectures (Nginx + OAuth2 Proxy, Envoy + ext_authz, etc.). The proxy validates the user's OIDC token, then injects identity headers on the internal hop. The upstream service trusts the proxy, not the client.

The question is: how do we enforce that only the proxy can reach the gateway?

## Decision

Two mechanisms, no shared secrets.

### 1. Sidecar + localhost binding

OAuth2 Proxy runs as a sidecar container in the same pod as the gateway. The gateway binds to `127.0.0.1:8080` — only the co-located proxy can reach it. Header spoofing is impossible without pod compromise.

NetworkPolicies enforce default-deny on the gateway port from external pods. Only the UI pod can reach the OAuth2 Proxy port (4180).

| Hop | Enforced by |
|:--|:--|
| Client → OAuth2 Proxy (4180) | OIDC token validation |
| OAuth2 Proxy → Gateway (127.0.0.1:8080) | Localhost binding (network topology) |
| Pod → Gateway (8080) direct | Blocked by NetworkPolicy + localhost bind |

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
- Redundant when sidecar + localhost binding already guarantees source
- Does not provide per-request proof (any holder of the secret can forge requests indefinitely)

### Development (no proxy)

In dev mode (`auth.enabled: false` in Helm values), the gateway accepts `X-Forwarded-Email` from any caller. This allows:

- `curl -H "X-Forwarded-Email: dev@example.com"` for manual testing
- `test-headless.sh` integration tests
- Local `go run` debugging against `make infra-up`

Intentional and acceptable — dev cluster is local (Kind) with no external ingress.

### Internal services (workbench)

The workbench is not externally exposed. It sits behind the UI's Nginx proxy, which is behind the gateway's OAuth2 Proxy. NetworkPolicy restricts workbench ingress to the UI pod only. No additional auth layer is needed for internal pod-to-pod communication in this topology.

## Consequences

- Gateway code never parses OIDC tokens directly for browser flows — identity is a header value from the trusted sidecar.
- JWT validation adds JWKS endpoint dependency but eliminates all shared secrets.
- No secret rotation burden — localhost binding is static, JWT keys rotate via OIDC provider.
- Misconfigured NetworkPolicies degrade the model — policy correctness remains critical.
- Dev mode is explicitly insecure. Production deployments must enable `auth.enabled: true`.

## Related

- [Kind + Helm as Sole Deployment Path](kind-only-deployment.md) — deployment topology
- ADR #0027 (complytime-core) — JWT bearer authentication for headless access
- [Authorization Model](authorization-model.md) — RBAC after identity is established
