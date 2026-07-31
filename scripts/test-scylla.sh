#!/usr/bin/env bash
#
# Run the Scylla-gated test suites against a REAL ScyllaDB. THE SINGLE IMPLEMENTATION — the GitHub
# Actions `integration` job invokes this file rather than restating the commands (the
# test-postgres.sh rule: a re-implementation is the drift that lets "runs in CI" quietly become
# untrue).
#
#   ./scripts/test-scylla.sh                    # every suite carrying @tag :scylla_integration
#   ./scripts/test-scylla.sh <suite path> [...]
#
# WHY A REAL ENGINE AND NOT A FAKE: a fake client validated 7 store functions for months while they
# carried guaranteed type errors (ISO strings against `date`, nested maps against `map<text,text>`) —
# the same failure shape as the $N::uuid cast bug, which shipped twice. A fake is exactly what lets a
# real CQL error ship. Unit-level fakes remain for boot-safety tests; they are never again the only
# coverage.
#
# Boots via the dev compose service `scylladb` (works locally AND in CI — GH service containers can't
# carry Scylla's required command flags, so the script owns the container in both places). First boot
# initialises system keyspaces: expect ~60-90s.
#
# Operational notes shared with test-postgres.sh: run from the umbrella ROOT (the decimal override
# lives only in the root mix.exs), one suite at a time, exclusions printed every run.
#
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="infra/docker/docker-compose.yml"
CONTAINER="chat-platform-scylladb"
NODES="${SCYLLA_TEST_NODES:-localhost:9042}"

echo "==> starting scylla (compose service 'scylladb')"
docker compose -f "$COMPOSE" up -d scylladb

echo "==> waiting for CQL (first boot takes ~60-90s)"
i=0
until docker exec "$CONTAINER" cqlsh -e "SELECT release_version FROM system.local" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -ge 60 ] && { echo "scylla never became ready"; exit 1; }
  sleep 3
done
echo "==> scylla ready after ~$((i * 3))s"

# Load the schema — idempotent (every statement IF NOT EXISTS), so rerunning is always safe.
echo "==> loading infra/docker/scylladb/init/*.cql"
for f in infra/docker/scylladb/init/*.cql; do
  docker exec -i "$CONTAINER" cqlsh < "$f" || { echo "CQL LOAD FAILED: $f"; exit 1; }
done

# Truncate between runs so suites assert against known state (IF NOT EXISTS load keeps data).
for t in messages_by_conversation message_receipts_by_conversation message_reactions_by_message messages_by_user_inbox; do
  docker exec "$CONTAINER" cqlsh -e "TRUNCATE chat_messages.$t" >/dev/null
done

cd apps/backend

suites=""
if [ "$#" -gt 0 ]; then
  suites="$*"
else
  suites="$(grep -rl "scylla_integration" apps/*/test --include="*_test.exs" | sort | tr '\n' ' ')"
fi

# Exclusions are ALWAYS printed, including zero — the test-postgres.sh convention: an exclusion
# nobody sees is indistinguishable from a test that does not exist.
excluded=""
for suite in $suites; do
  tag="$(grep -ohE '@(module)?tag :requires_[a-z_]+' "$suite" 2>/dev/null | head -1 | sed 's/.*:requires_/requires_/' || true)"
  if [ -n "$tag" ]; then
    excluded="$excluded$suite ($tag)\n"
  fi
done
excluded_count=$(printf '%b' "$excluded" | grep -c . || true)
excluded_count=${excluded_count:-0}
total_count=$(echo $suites | wc -w | tr -d ' ')
echo "==> $total_count scylla-gated suites; $excluded_count excluded"
if [ "$excluded_count" -gt 0 ]; then
  printf '%b' "$excluded" | sed 's/^/      EXCLUDED: /'
fi

fail=0
for suite in $suites; do
  if grep -qE '@(module)?tag :requires_[a-z_]+' "$suite" 2>/dev/null; then
    continue
  fi

  printf '%-84s' "$suite"
  if out="$(SCYLLA_TEST_NODES="$NODES" ELIXIR_LOG_LEVEL=warning mix test --include scylla_integration "$suite" 2>&1)"; then
    echo "$(echo "$out" | grep -E '^Result:' | tail -1)"
  else
    echo "FAILED"
    echo "$out" | awk '/^  [0-9]+\) test /{p=1} p{print} p&&/^$/{blank++; if (blank>=2) {p=0; blank=0}}' | head -80
    echo "$out" | grep -E "tests, [0-9]+ failure" | tail -1
    echo "--------------------------------------------------------------------------------"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "==> SCYLLA SUITES FAILED"
else
  echo "==> all scylla suites passed"
fi
exit "$fail"
