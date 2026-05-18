# 0043 — Trusted Publisher Model for Evidence Ingestion

**Status:** Proposed
**Date:** 2026-05-18

## Context

ComplyTime Core ingests evidence from deterministic tools (scanners, linters, policy engines) running on behalf of groups. These tools run in CI pipelines (GitHub Actions, GitLab CI, Tekton), in-cluster workloads, or external automation. Today, the ingest path (`POST /api/ingest`) records no publisher identity. Any caller that passes NetworkPolicy can submit evidence for any policy with no provenance trail.

Package registries (PyPI, NPM) solved this problem with **trusted publishing**: publishers authenticate via OIDC tokens from their CI provider, the registry verifies claims against a pre-registered configuration, and artifacts carry cryptographic provenance linking them to a specific origin.

The same pattern applies to compliance evidence. An auditor needs to know: who submitted this evidence, from which pipeline, and can we verify that claim?

## Decision

Adopt OIDC-based trusted publishing for evidence ingestion. Publisher identity is a **trust signal, not an access gate** — evidence from unverified publishers is still ingested but receives a lower trust certification from the certifier pipeline.

### Layered Approach

The design is implemented incrementally. Each layer builds on the previous one.

| Layer | Scope | Dependencies | Effort |
|:---|:---|:---|:---|
| 1 — Provenance metadata | Schema + request context capture | None | Half day |
| 2 — OIDC verification | JWT validation, PublisherCertifier, trusted publisher config | `coreos/go-oidc/v3` | 1-2 weeks |
| 3 — Signed attestation | DSSE/in-toto envelope verification | `sigstore/sigstore-go` | 1 week |

### Layer 1: Provenance Metadata

Add publisher identity fields to the evidence schema. Populate from request context at ingest time. No cryptographic verification.

**Schema (migration 018):**

| Column | Type | Default | Purpose |
|:---|:---|:---|:---|
| `submitted_by` | `TEXT` | `''` | Publisher identity (email or OIDC `sub` claim) |
| `publisher_issuer` | `TEXT` | `''` | OIDC issuer URL when available |
| `publisher_type` | `TEXT` | `''` | Category: `user`, `service`, `pipeline`, `api` |
| `publisher_verified` | `BOOLEAN` | `false` | Whether identity was cryptographically verified |

**Ingest behavior:** The ingest worker reads identity from the request context (`X-Forwarded-Email` via existing auth middleware) and writes `submitted_by` and `publisher_type`. All evidence ingested at this layer has `publisher_verified=false`.

No behavior change for existing callers. No new dependencies.

### Layer 2: OIDC Verification

Gateway validates JWT tokens on write paths. Verified claims populate provenance fields. A new `PublisherCertifier` joins the certifier pipeline.

**Auth middleware changes:** When a request includes `Authorization: Bearer <JWT>`, the gateway validates the token against registered OIDC issuers using JWKS discovery. Verified claims (`sub`, `iss`) are injected into request context alongside the existing `X-Forwarded-Email` path. Both paths coexist — JWT-bearing requests get `publisher_verified=true`, header-only requests get `publisher_verified=false`.

**PublisherCertifier** (fourth certifier in the pipeline):

```
Pipeline:
  1. SchemaCertifier      — required fields, valid enums, timestamps
  2. ProvenanceCertifier   — source_registry or attestation_ref present
  3. ExecutorCertifier     — engine_name present, engine registered
  4. PublisherCertifier    — publisher identity verified, issuer+sub trusted
```

Verdicts:
- **pass** — `publisher_verified=true` and `(issuer, sub)` matches a trusted publisher entry
- **skip** — `publisher_verified=false` (no JWT presented; does not block certification)
- **fail** — `publisher_verified=true` but `(issuer, sub)` not in trusted config

**Trusted publisher config** (environment-based, consistent with `KNOWN_REGISTRIES` and `KNOWN_ENGINES`):

```
TRUSTED_PUBLISHERS=issuer1:sub_pattern1,issuer2:sub_pattern2
```

Example:

```
TRUSTED_PUBLISHERS=https://token.actions.githubusercontent.com:repo:org/scanner:*,https://kubernetes.default.svc:system:serviceaccount:complytime:*
```

Glob matching on `sub` for flexibility across providers.

**Kubernetes changes:** Workbench and agent pods mount projected ServiceAccount tokens (`audience: complytime-core`) to authenticate as verified internal publishers.

**Key dependency:** `coreos/go-oidc/v3` — industry-standard OIDC relying party library. Handles JWKS discovery, caching, rotation, and token verification. Used by Kubernetes, Dex, and most Go OIDC implementations.

**OIDC issuer claim mapping:**

| Issuer | `sub` claim format |
|:---|:---|
| GitHub Actions | `repo:org/repo:ref:refs/heads/main` |
| GitLab CI | `project_path:org/repo:ref_type:branch:ref:main` |
| Kubernetes SA | `system:serviceaccount:namespace:name` |
| Google (browser) | Opaque user ID |
| Dex | Connector-dependent |

### Layer 3: Signed Attestation Envelopes (Future)

Evidence payloads wrapped in DSSE (Dead Simple Signing Envelope) / in-toto attestation format. Core verifies the signature at ingest, providing integrity proof in addition to identity proof.

**Key dependency:** `sigstore/sigstore-go` — minimal-dependency Sigstore bundle verification. Handles DSSE envelope parsing, signature verification, and optional Rekor transparency log integration.

**Publisher-side requirement:** Every pipeline adds a signing step (e.g., `cosign sign-blob`). This is the highest adoption cost of any layer.

**Schema addition:** `attestation_verified` (bool), `attestation_digest` (text) on evidence records.

## Tradeoffs

### Why trust signal, not access gate?

Evidence from an untrusted publisher is still evidence. Rejecting it loses data. The certifier pipeline already works this way — evidence with missing `engine_name` gets ingested with `certified=false`. Publisher verification follows the same pattern: annotate trust level, let the aggregate verdict drive `certified`.

### Why OIDC everywhere (not API keys)?

API keys are long-lived secrets that can leak, have no provenance chain, and require manual rotation. OIDC tokens are short-lived, cryptographically verifiable, and tied to a specific workload identity. PyPI moved away from API keys for these reasons. Every target publisher environment (GitHub Actions, GitLab CI, Kubernetes, GCP) already has an OIDC identity provider.

### Why environment config before API-managed registry?

Consistent with how `KNOWN_REGISTRIES` and `KNOWN_ENGINES` are configured today. Avoids building CRUD + UI for publisher management before the core verification works. Migrate to API-managed (`POST /api/trusted-publishers`) when the UX is ready.

### Infrastructure cost cliff

The cost jump is between Layer 1 and Layer 2. Layer 1 is nearly free (schema + context capture). Layer 2 introduces outbound network dependency (JWKS fetching), publisher-side workflow changes (CI must present JWT), Kubernetes config changes (projected SA tokens), and claim mapping complexity across OIDC providers. Layer 3 is additive — moderate code but heavy publisher adoption cost.

## Consequences

- Every evidence record carries provenance metadata from Layer 1 onward, even before verification is enforced.
- The certifier pipeline gains a fourth dimension of trust. Evidence trustworthiness becomes a composite of schema validity, provenance, executor, and publisher identity.
- CI pipelines that adopt OIDC token presentation get higher-trust evidence without managing long-lived secrets.
- Publishers that do not present JWT tokens still work — their evidence is ingested with `publisher_verified=false` and the PublisherCertifier returns `skip`.
- Dev mode (`X-Forwarded-Email` without JWT) continues to work. Verified path requires a valid JWT.
- Claim mapping documentation per CI provider is required for Layer 2 adoption.
- Future: API-managed trusted publisher registry replaces environment config.
- Future: Signed attestation envelopes provide integrity proof on top of identity proof.

## Related

- [Identity Trust Model](identity-trust-model.md) — current auth architecture
- [Agent On-Behalf-Of Token Flow](agent-obo-flow.md) — per-user delegation (overlaps with Layer 2)
- ADR #0027 (complytime-core) — JWT bearer authentication for headless access
- [Data Boundary Enforcement](data-boundary-enforcement.md) — core owns evidence records
- [PyPI Trusted Publishing Internals](https://docs.pypi.org/trusted-publishers/internals/) — reference model
- [Sigstore](https://sigstore.dev/) — signing and verification for software supply chain
