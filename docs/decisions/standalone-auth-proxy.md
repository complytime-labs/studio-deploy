# 0040 — Standalone OAuth2 Proxy

**Status:** Accepted
**Date:** 2026-05-16

## Context

OAuth2 Proxy runs as a sidecar in the gateway pod. The gateway reverse-proxies `/workbench/*` to the workbench. This creates a hairpin: browser traffic enters the gateway, leaves to the workbench, then the workbench calls back into the gateway on a separate internal port (8081) for data access.

The sidecar pattern was chosen because it co-locates auth enforcement with the gateway. But the gateway is not the only backend — the workbench is a peer service that also needs auth. Forcing all workbench traffic through the gateway solely for auth adds latency, complexity (two gateway ports, `LISTEN_HOST` binding, internal NetworkPolicy rules), and makes the gateway a single point of failure for workbench availability.

In production, a shared ingress controller with OIDC middleware sits in front of all services. The sidecar does not model that topology.

## Decision

Move OAuth2 Proxy from a gateway sidecar to a standalone Deployment + Service. Nginx routes to the proxy. The proxy routes to backends by path prefix.

### Request flow (after)

```
Browser → Nginx → OAuth2 Proxy (:4180)
  → /api/*, /auth/*    → Gateway (:8080)
  → /workbench/*       → Workbench (:8090)
  → /oauth2/*          → self (login/callback)
```

### What changes

| Component | Before | After |
|:---|:---|:---|
| OAuth2 Proxy | Sidecar in gateway pod | Standalone Deployment + Service |
| Gateway ports | 8080 (via proxy), 8081 (internal bypass) | 8080 only (direct) |
| `LISTEN_HOST` | `127.0.0.1` when auth enabled | Always `0.0.0.0` |
| Nginx upstream | Gateway service :8080 | OAuth2 Proxy service :4180 |
| Gateway reverse proxy for /workbench/* | Required (sole auth entry point) | Removed (proxy routes directly) |
| studio-ui `docker-entrypoint.sh` | Substitutes `GATEWAY_UPSTREAM` | Substitutes `AUTH_PROXY_UPSTREAM` |
| NetworkPolicy for gateway | Allow 4180 + 8080 from anywhere | Allow 8080 from OAuth2 Proxy pod only |
| NetworkPolicy for workbench | Allow 8090 from gateway only | Allow 8090 from OAuth2 Proxy pod only |

### OAuth2 Proxy upstream configuration

OAuth2 Proxy supports multiple upstreams with path-based routing:

```
--upstream=http://studio-gateway:8080/api/
--upstream=http://studio-gateway:8080/auth/
--upstream=http://studio-workbench:8090/workbench/
```

### Internal service-to-service

In-cluster callers (agent tools, workbench) call the gateway on :8080 directly with `X-Forwarded-Email`. No internal port needed — the proxy is no longer in the pod. NetworkPolicy restricts which pods can reach the gateway.

### Dev mode (auth disabled)

When `auth.oauth2Proxy.enabled` is false, Nginx routes directly to the gateway. The standalone proxy deployment is not created. No behavioral change from current dev mode.

## Consequences

- Hairpin eliminated. Workbench traffic no longer passes through the gateway.
- Gateway is simpler: one port, no sidecar coordination, no reverse proxy for `/workbench/*`.
- Adding a new backend service means one new `--upstream` rule on the proxy, not a new reverse proxy in the gateway.
- OAuth2 Proxy becomes a single point of failure for all authenticated traffic. Acceptable for Kind; production would use an HA ingress controller.
- Gateway loses awareness of workbench traffic in its access logs. Proxy access logs cover all backends.

## Related

- [Identity Trust Model](identity-trust-model.md) — updates to trust model with standalone proxy
- [Architecture Extraction](architecture-extraction.md) — gateway/workbench separation
