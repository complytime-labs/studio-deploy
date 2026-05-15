#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Integration test: validates ComplyTime Studio operates as a headless
# data platform. Runs against gateway REST API without any UI component.
#
# Usage:
#   GATEWAY_URL=http://localhost:8080 SEED_IDENTITY=test@complytime.dev ./test-headless.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
SEED_IDENTITY="${SEED_IDENTITY:-test@complytime.dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/../complytime-studio/demo"
PASS=0
FAIL=0
SKIP=0

AUTH_HEADER=(-H "X-Forwarded-Email: ${SEED_IDENTITY}")

info()  { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
pass()  { PASS=$((PASS + 1)); printf "  \033[32m✓ %s\033[0m\n" "$*"; }
fail()  { FAIL=$((FAIL + 1)); printf "  \033[31m✗ %s\033[0m\n" "$*"; }
skip()  { SKIP=$((SKIP + 1)); printf "  \033[33m⊘ %s\033[0m\n" "$*"; }

assert_status() {
  local label="$1" method="$2" path="$3" expected="$4"
  shift 4
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
    "${GATEWAY_URL}${path}" "${AUTH_HEADER[@]}" "$@")
  if [[ "${code}" == "${expected}" ]]; then
    pass "${label} → ${code}"
  else
    fail "${label} → ${code} (expected ${expected})"
  fi
}

assert_json_field() {
  local label="$1" path="$2" field="$3"
  shift 3
  local body
  body=$(curl -s "${GATEWAY_URL}${path}" "${AUTH_HEADER[@]}" "$@")
  if echo "${body}" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '${field}' in (d if isinstance(d,dict) else d[0])" 2>/dev/null; then
    pass "${label} — field '${field}' present"
  else
    fail "${label} — field '${field}' missing. Body: $(echo "${body}" | head -c 200)"
  fi
}

assert_json_array() {
  local label="$1" path="$2"
  shift 2
  local body count
  body=$(curl -s "${GATEWAY_URL}${path}" "${AUTH_HEADER[@]}" "$@")
  count=$(echo "${body}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "-1")
  if [[ "${count}" -ge 0 ]]; then
    pass "${label} → array with ${count} items"
  else
    fail "${label} — not a JSON array. Body: $(echo "${body}" | head -c 200)"
  fi
}

# ── 1. Health ──
info "1. Health & liveness"
assert_status "GET /healthz returns 200" GET "/healthz" "200"

# ── 2. Config (unauthenticated) ──
info "2. Public config endpoint"
assert_status "GET /api/config returns 200" GET "/api/config" "200"
assert_json_field "Config has github_org" "/api/config" "github_org"

# ── 3. System info ──
info "3. System info"
assert_status "GET /api/system-info returns 200" GET "/api/system-info" "200"

# ── 4. Setup status ──
info "4. Setup status"
assert_status "GET /api/setup-status returns 200" GET "/api/setup-status" "200"

# ── 5. Auth enforcement ──
# Without X-Forwarded-Email, /api/* returns 401. With it, requests succeed.
# In production, OAuth2 Proxy injects this header after OIDC/JWT validation.
info "5. Auth enforcement (X-Forwarded-Email)"
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/api/system-info")
if [[ "${UNAUTH_CODE}" == "401" ]]; then
  pass "Unauthenticated /api/system-info → 401"
else
  fail "Unauthenticated /api/system-info → ${UNAUTH_CODE} (expected 401)"
fi

# ── 5b. Bootstrap admin ──
# First-run: promote the seed identity to admin so write tests succeed.
info "5b. Bootstrap admin identity"
BOOTSTRAP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/api/bootstrap" "${AUTH_HEADER[@]}")
if [[ "${BOOTSTRAP_CODE}" =~ ^2 ]]; then
  pass "POST /api/bootstrap → ${BOOTSTRAP_CODE} (admin created)"
elif [[ "${BOOTSTRAP_CODE}" == "409" ]]; then
  pass "POST /api/bootstrap → 409 (admin already exists)"
else
  fail "POST /api/bootstrap → ${BOOTSTRAP_CODE} (expected 2xx or 409)"
fi

# ── 6. Policy listing ──
info "6. Policy listing"
assert_json_array "GET /api/policies returns array" "/api/policies"

# ── 7. Evidence ingest (Gemara YAML) ──
info "7. Evidence ingest via REST"
if [[ -f "${DEMO_DIR}/eval-ampel-complyctl.yaml" ]]; then
  assert_status "POST /api/evidence/ingest (YAML)" POST "/api/evidence/ingest" "201" \
    -H "Content-Type: application/x-yaml" --data-binary @"${DEMO_DIR}/eval-ampel-complyctl.yaml"
else
  skip "Evidence fixture not found at ${DEMO_DIR}/eval-ampel-complyctl.yaml"
fi

# ── 7b. Async evidence ingest ──
info "7b. Async evidence ingest via NATS"
if [[ -f "${DEMO_DIR}/eval-ampel-complyctl.yaml" ]]; then
  ASYNC_RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "${GATEWAY_URL}/api/evidence/ingest/async" "${AUTH_HEADER[@]}" \
    -H "Content-Type: application/x-yaml" --data-binary @"${DEMO_DIR}/eval-ampel-complyctl.yaml")
  ASYNC_CODE=$(echo "${ASYNC_RESP}" | tail -1)
  ASYNC_BODY=$(echo "${ASYNC_RESP}" | sed '$d')
  if [[ "${ASYNC_CODE}" == "202" ]]; then
    pass "POST /api/evidence/ingest/async → 202"
    JOB_ID=$(echo "${ASYNC_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || echo "")
    if [[ -n "${JOB_ID}" ]]; then
      pass "Async job_id: ${JOB_ID}"
      # Poll for completion (max 10 attempts, 1s apart)
      for attempt in $(seq 1 10); do
        sleep 1
        JOB_STATUS=$(curl -s "${GATEWAY_URL}/api/evidence/ingest/jobs/${JOB_ID}" "${AUTH_HEADER[@]}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        if [[ "${JOB_STATUS}" == "completed" ]]; then
          pass "Async ingest job completed (attempt ${attempt})"
          break
        elif [[ "${JOB_STATUS}" == "failed" ]]; then
          fail "Async ingest job failed (attempt ${attempt})"
          break
        fi
        if [[ "${attempt}" -eq 10 ]]; then
          fail "Async ingest job did not complete within 10s (status: ${JOB_STATUS})"
        fi
      done
    else
      skip "Could not extract job_id from async response"
    fi
  else
    fail "POST /api/evidence/ingest/async → ${ASYNC_CODE} (expected 202)"
  fi
else
  skip "Evidence fixture not found — skipping async ingest test"
fi

# ── 8. Evidence query ──
info "8. Evidence query"
assert_json_array "GET /api/evidence returns array" "/api/evidence?limit=10"

# ── 9. Catalogs ──
info "9. Catalog listing"
assert_json_array "GET /api/catalogs returns array" "/api/catalogs"

# ── 10. Posture ──
info "10. Posture summary"
assert_json_array "GET /api/posture returns array" "/api/posture"

# ── 11. Threats & risks ──
info "11. Threats and risks"
assert_json_array "GET /api/threats returns array" "/api/threats"
assert_json_array "GET /api/risks returns array" "/api/risks"

# ── 12. Draft audit logs ──
info "12. Draft audit logs"
assert_json_array "GET /api/draft-audit-logs returns array" "/api/draft-audit-logs"

# ── 13. Audit logs ──
info "13. Audit logs"
assert_json_array "GET /api/audit-logs returns array" "/api/audit-logs"

# ── 14. Auth introspection ──
# /auth/me returns user info when X-Forwarded-Email is present (as it would be
# behind OAuth2 Proxy). Without any identity header, it returns 401.
info "14. Auth introspection"
ME_UNAUTH=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/auth/me")
if [[ "${ME_UNAUTH}" == "401" ]]; then
  pass "GET /auth/me (no identity) → 401"
else
  fail "GET /auth/me (no identity) → ${ME_UNAUTH} (expected 401)"
fi
assert_status "GET /auth/me (with identity) returns 200" GET "/auth/me" "200"

# ── 15. Programs CRUD ──
info "15. Programs CRUD"
assert_json_array "GET /api/programs returns array" "/api/programs"

PROGRAM_BODY='{"name":"e2e-test-program","framework":"NIST-800-53","description":"Created by test-headless.sh"}'
CREATE_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  "${GATEWAY_URL}/api/programs" "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" -d "${PROGRAM_BODY}")
CREATE_CODE=$(echo "${CREATE_RESP}" | tail -1)
CREATE_BODY=$(echo "${CREATE_RESP}" | sed '$d')
if [[ "${CREATE_CODE}" =~ ^2 ]]; then
  pass "POST /api/programs → ${CREATE_CODE}"
  PROGRAM_ID=$(echo "${CREATE_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  if [[ -n "${PROGRAM_ID}" ]]; then
    pass "Created program id: ${PROGRAM_ID}"

    PROGRAM_VERSION=$(echo "${CREATE_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',1))" 2>/dev/null || echo "1")
    UPDATE_BODY="{\"name\":\"e2e-test-program-updated\",\"framework\":\"NIST-800-53\",\"status\":\"intake\",\"description\":\"Updated by test-headless.sh\",\"version\":${PROGRAM_VERSION},\"green_pct\":90,\"red_pct\":50}"
    assert_status "PUT /api/programs/${PROGRAM_ID}" PUT "/api/programs/${PROGRAM_ID}" "200" \
      -H "Content-Type: application/json" -d "${UPDATE_BODY}"

    assert_status "DELETE /api/programs/${PROGRAM_ID}" DELETE "/api/programs/${PROGRAM_ID}" "200"
  else
    skip "Could not extract program id — skipping PUT and DELETE"
  fi
else
  fail "POST /api/programs → ${CREATE_CODE} (expected 2xx)"
fi

# ── 16. RBAC boundary — reviewer identity gets 403 on write endpoints ──
info "16. RBAC boundary (reviewer role)"
REVIEWER_IDENTITY="${REVIEWER_IDENTITY:-reviewer@complytime.dev}"
REVIEWER_HEADER=(-H "X-Forwarded-Email: ${REVIEWER_IDENTITY}")

RBAC_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/api/programs" "${REVIEWER_HEADER[@]}" \
  -H "Content-Type: application/json" -d '{"name":"rbac-test"}')
if [[ "${RBAC_CODE}" == "403" ]]; then
  pass "Reviewer POST /api/programs → 403 (write blocked)"
elif [[ "${RBAC_CODE}" == "401" ]]; then
  pass "Reviewer POST /api/programs → 401 (unauthenticated — no user record, still blocked)"
else
  fail "Reviewer POST /api/programs → ${RBAC_CODE} (expected 403 or 401)"
fi

if [[ -f "${DEMO_DIR}/eval-ampel-complyctl.yaml" ]]; then
  RBAC_EV_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/api/evidence/ingest" "${REVIEWER_HEADER[@]}" \
    -H "Content-Type: application/x-yaml" --data-binary @"${DEMO_DIR}/eval-ampel-complyctl.yaml")
  if [[ "${RBAC_EV_CODE}" == "403" ]]; then
    pass "Reviewer POST /api/evidence/ingest → 403 (write blocked)"
  elif [[ "${RBAC_EV_CODE}" == "401" ]]; then
    pass "Reviewer POST /api/evidence/ingest → 401 (unauthenticated — still blocked)"
  else
    fail "Reviewer POST /api/evidence/ingest → ${RBAC_EV_CODE} (expected 403 or 401)"
  fi
else
  skip "Evidence fixture not found — skipping RBAC evidence test"
fi

RBAC_READ_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/policies" "${REVIEWER_HEADER[@]}")
if [[ "${RBAC_READ_CODE}" == "200" ]]; then
  pass "Reviewer GET /api/policies → 200 (read allowed)"
else
  fail "Reviewer GET /api/policies → ${RBAC_READ_CODE} (expected 200)"
fi

# ── Summary ──
TOTAL=$((PASS + FAIL + SKIP))
info "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total)"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
