#!/usr/bin/env bash
#
# Run the postgres-gated test suites for real. THE SINGLE IMPLEMENTATION — the GitHub Actions
# `integration` job invokes this file rather than restating the commands, because that drift is exactly
# how "runs in your CI" became untrue.
#
#   ./scripts/test-postgres.sh                    # every suite carrying @tag :postgres_integration
#   ./scripts/test-postgres.sh apps/message_service/test/message_service/statuses_test.exs [...]
#
# WHY THIS EXISTS
#   The @tag :postgres_integration suites are excluded from `mix test` so the default path stays
#   Docker-free. That is correct, but it meant status and incoming media both shipped 100% broken on a
#   Postgrex parameter-cast bug ($N::uuid against a string) that a single real run would have caught.
#   Compiling proves nothing about raw SQL — parameter encoding fails at runtime.
#
# ---------------------------------------------------------------------------------------------------
# TWO OPERATIONAL FACTS THAT WILL OTHERWISE COST YOU AN HOUR
#
#   1. A SINGLE UMBRELLA-WIDE RUN IS NOT A TRUSTWORTHY SIGNAL. Every app shares the one
#      `chat_platform_test` database, so suites interfere. Two identical runs of
#      `mix test --include postgres_integration` were observed to DISAGREE ON 33 TESTS. Per-suite is
#      the only honest read, which is why this script loops one suite at a time and never aggregates.
#      (The real fix is per-app test databases — see docs/09-devops/POSTGRES_TESTS.md.)
#
#   2. `cd apps/<app> && mix test` HAS BEEN BROKEN SINCE THE SCYLLA PHASE-B WORK. Xandra declares
#      `decimal ~> 1.7 or ~> 2.0` as an optional dep and Hex enforces it, so the build needs
#      `{:decimal, "~> 3.0", override: true}` — which lives only in the ROOT apps/backend/mix.exs.
#      A per-app run does not inherit it and dies with "Unchecked dependencies". Always run from the
#      umbrella root, as this script does.
# ---------------------------------------------------------------------------------------------------
#
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

DB="${POSTGRES_TEST_DATABASE:-chat_platform_test}"
PGUSER_="${POSTGRES_TEST_USER:-chat_user}"
PGPASS_="${POSTGRES_TEST_PASSWORD:-chat_password}"
PGHOST_="${POSTGRES_TEST_HOST:-localhost}"
PGPORT_="${POSTGRES_TEST_PORT:-5432}"
CONTAINER="chat-platform-postgres"
COMPOSE="infra/docker/docker-compose.yml"

# In CI, Postgres is a service container and `psql` is on PATH. Locally we bring the compose service up
# and shell into it, so no host psql install is required. Same SQL either way.
if [ -n "${CI:-}" ] || command -v psql >/dev/null 2>&1; then
  MODE="psql"
else
  MODE="docker"
fi

psql_db() { # <database> [extra psql args...]
  local db="$1"; shift
  if [ "$MODE" = "psql" ]; then
    PGPASSWORD="$PGPASS_" psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$db" -q "$@"
  else
    docker exec -i "$CONTAINER" psql -U "$PGUSER_" -d "$db" -q "$@"
  fi
}

if [ "$MODE" = "docker" ]; then
  echo "==> starting postgres (compose)"
  docker compose -f "$COMPOSE" up -d postgres
  i=0
  until docker exec "$CONTAINER" pg_isready -U "$PGUSER_" -d chat_platform >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "postgres never became ready"; exit 1; }
    sleep 1
  done
fi

# Rebuild the test DB from the SAME numbered files the prod container initialises from, in order. A
# migration that is not byte-identical between apps/backend/apps/shared_infra/priv/schema and
# infra/docker/postgres/init already fails ReleaseSchemaDriftTest, so loading one side is sufficient.
echo "==> rebuilding $DB from infra/docker/postgres/init/*.sql"
psql_db postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
count=0
for f in infra/docker/postgres/init/*.sql; do
  psql_db "$DB" -v ON_ERROR_STOP=1 -f - < "$f" || { echo "MIGRATION FAILED: $f"; exit 1; }
  count=$((count + 1))
done
echo "==> $count migrations applied"

cd apps/backend

# Collect suites. bash 3.2 (macOS default) has no `mapfile`, so build the list the portable way.
suites=""
if [ "$#" -gt 0 ]; then
  suites="$*"
else
  suites="$(grep -rl "postgres_integration" apps/*/test --include="*_test.exs" | sort | tr '\n' ' ')"
fi

# EXCLUSIONS ARE ALWAYS PRINTED, INCLUDING WHEN THERE ARE NONE. An exclusion nobody sees is
# indistinguishable from a test that does not exist — which is precisely how "runs in your CI" stayed
# believable while nothing ran. The convention: a suite that cannot run here carries an explicit named
# tag saying WHY (`@moduletag :requires_kafka`, `:requires_minio`, ...), never a bare skip.
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

echo "==> $total_count postgres-gated suites; $excluded_count excluded"
if [ "$excluded_count" -gt 0 ]; then
  printf '%b' "$excluded" | sed 's/^/      EXCLUDED: /'
fi

fail=0
for suite in $suites; do
  # Skip the ones just reported, so the count above and the runs below can never disagree.
  if grep -qE '@(module)?tag :requires_[a-z_]+' "$suite" 2>/dev/null; then
    continue
  fi

  printf '%-84s' "$suite"
  if out="$(mix test --include postgres_integration "$suite" 2>&1)"; then
    echo "$(echo "$out" | grep -E '^Result:' | tail -1)"
  else
    echo "FAILED"
    echo "$out" | grep -vE '^[0-9]{2}:[0-9]{2}:[0-9]{2}\.' | tail -40
    echo "--------------------------------------------------------------------------------"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "==> POSTGRES SUITES FAILED"
else
  echo "==> all postgres suites passed"
fi
exit "$fail"
