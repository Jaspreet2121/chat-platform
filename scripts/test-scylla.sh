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

# THE STARS HYBRID (C2) MADE THIS GATE NEED POSTGRES TOO: starred_messages is a relational satellite,
# so list_starred's live test writes Postgres and hydrates from Scylla. Without this check the gate
# silently depended on whatever container happened to be running — the it-works-on-my-machine false
# green this repo has already paid for. In CI the service container + the postgres gate (an earlier
# step of the same job) provide a migrated chat_platform_test; locally we boot compose postgres if
# nothing answers, and REFUSE (with the fix) if the test DB was never migrated — this script loads
# CQL, not SQL, and must not half-own the relational schema.
if command -v pg_isready >/dev/null 2>&1 && pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
  : # something already answers on 5432 (CI service container, or a local server)
else
  echo "==> starting postgres (compose service — the stars hybrid needs it)"
  docker compose -f "$COMPOSE" up -d postgres
  i=0
  until docker exec chat-platform-postgres pg_isready -U chat_user >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "postgres never became ready"; exit 1; }
    sleep 1
  done
fi

db_exists="$(docker exec chat-platform-postgres psql -U chat_user -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='chat_platform_test'" 2>/dev/null || \
  PGPASSWORD=chat_password psql -h localhost -U chat_user -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='chat_platform_test'" 2>/dev/null || true)"

if [ "$db_exists" != "1" ]; then
  echo "ERROR: chat_platform_test does not exist. Run ./scripts/test-postgres.sh first (it owns the SQL schema)."
  exit 1
fi

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
  out="$(docker exec -i "$CONTAINER" cqlsh < "$f" 2>&1)" && continue
  # Scylla 5.4 has no `ALTER ... ADD IF NOT EXISTS` (verified live — SyntaxException), so ALTER
  # migrations rerun as "conflicts with an existing column". That NARROW error is already-applied,
  # not failure; anything else still fails the load loudly.
  if echo "$out" | grep -q "conflicts with an existing column"; then
    echo "      (already applied: $f)"
  else
    echo "CQL LOAD FAILED: $f"
    echo "$out"
    exit 1
  fi
done

# Truncate between runs so suites assert against known state (IF NOT EXISTS load keeps data).
for t in messages_by_conversation message_receipts_by_conversation message_reactions_by_message messages_by_user_inbox messages_by_media media_by_conversation; do
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
