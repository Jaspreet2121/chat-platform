#!/usr/bin/env bash
#
# CI Layer 3 — distributed-failure differential against a RUNNING docker-compose.prod.yml stack.
#
# Proves the microservices split's graceful-degradation contract over the real network, on the same
# gateway→auth path proven live in the compose-prod slice (see docs/11-decisions/DECISION_LOG.md):
#
#   (a) auth UP       → GET /api/v1/auth/session (bogus token) → HTTP 401 "auth.session_invalid"
#                       (gateway reached auth over HTTP; domain error, gateway alive)
#   (b) auth STOPPED  → same call                              → HTTP 503 "auth.unavailable"
#                       (HTTP adapter transport-failure → 503, graceful, NO crash)
#   (c) auth RESTARTED→ same call                              → HTTP 401 "auth.session_invalid"
#                       (auto-recovery once auth is back)
#
# This script does NOT bring the stack up or tear it down — the caller (CI job / human) owns that.
# It only drives the auth container's stop/start and asserts the three states. Exits non-zero on the
# first mismatch.
#
# Usage (from repo root, with the stack already `up`):
#   bash scripts/ci/compose_differential.sh
#
# Overridable via env: COMPOSE_FILE, GATEWAY_URL, AUTH_SVC, ENDPOINT, READY_TIMEOUT.

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:4000}"
AUTH_SVC="${AUTH_SVC:-auth}"
ENDPOINT="${ENDPOINT:-/api/v1/auth/session}"
READY_TIMEOUT="${READY_TIMEOUT:-90}" # seconds to wait for each expected state

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Curl the differential endpoint with a deliberately invalid bearer token.
# Echoes "<http_status> <body>" (body newlines stripped to keep it one line).
probe() {
  local body_file status
  body_file="$(mktemp)"
  status="$(curl -s -o "$body_file" -w '%{http_code}' --max-time 5 \
    -H 'authorization: Bearer bogus' "${GATEWAY_URL}${ENDPOINT}" 2>/dev/null || echo 000)"
  printf '%s %s' "$status" "$(tr -d '\n' < "$body_file")"
  rm -f "$body_file"
}

# Poll `probe` until the status == $1 AND the body contains $2, or fail after READY_TIMEOUT.
# $3 is a human label for logging.
wait_for_state() {
  local want_status="$1" want_substr="$2" label="$3"
  local deadline=$((SECONDS + READY_TIMEOUT)) last=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    last="$(probe)"
    local code="${last%% *}" body="${last#* }"
    if [ "$code" = "$want_status" ] && printf '%s' "$body" | grep -q "$want_substr"; then
      echo "  PASS [$label] HTTP $code, body contains \"$want_substr\""
      echo "       → $body"
      return 0
    fi
    sleep 2
  done
  echo "  FAIL [$label] expected HTTP $want_status + \"$want_substr\" within ${READY_TIMEOUT}s"
  echo "       last seen: $last"
  return 1
}

echo "== CI Layer 3: gateway→auth distributed-failure differential =="
echo "   compose=$COMPOSE_FILE  gateway=$GATEWAY_URL  endpoint=$ENDPOINT  auth_svc=$AUTH_SVC"

# Gateway must be listening before we assert anything.
echo "-- waiting for gateway /health --"
deadline=$((SECONDS + READY_TIMEOUT))
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${GATEWAY_URL}/health" 2>/dev/null || echo 000)" = "200" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then echo "  FAIL gateway /health never returned 200"; exit 1; fi
  sleep 2
done
echo "  gateway /health = 200"

# (a) Steady state: auth reachable → domain 401 (also serves as readiness for the gateway→auth path).
echo "-- (a) auth UP → expect 401 auth.session_invalid --"
wait_for_state 401 "auth.session_invalid" "auth up → 401"

# (b) Stop auth → transport failure → 503 auth.unavailable.
echo "-- (b) STOP auth → expect 503 auth.unavailable --"
dc stop "$AUTH_SVC"
wait_for_state 503 "auth.unavailable" "auth down → 503"

# (c) Start auth → recovery back to 401.
echo "-- (c) START auth → expect 401 auth.session_invalid (recovery) --"
dc start "$AUTH_SVC"
wait_for_state 401 "auth.session_invalid" "auth recovered → 401"

echo "== differential PASSED: 401 (domain) / 503 (auth down) / 401 (recovery) =="
