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

# EVERY SUITE RUNS, AND THE RUN ENDS WITH A TABLE.
#
# It did not used to. The failure branch below piped awk into `head -80`; when head had its 80 lines
# it exited, awk took SIGPIPE, and under `set -o pipefail` + `set -e` that non-zero status killed the
# WHOLE SCRIPT at the first failing suite. Every suite after it silently never ran — and because the
# script died mid-loop it printed no verdict either, so the output looked like a run that had simply
# stopped. Two real failures were hidden behind one flake that way.
#
# Nothing here pipes into a short-circuiting reader any more: awk writes a FILE and `sed -n 1,80p`
# reads that file, so there is no upstream process left to signal. `|| true` guards the greps whose
# "no match" is a perfectly normal outcome (pipefail would otherwise treat it as a fatal error).
#
# Results accumulate into a temp file rather than an array: macOS ships bash 3.2, which has neither
# associative arrays nor `mapfile`.
fail=0
results="$(mktemp)"
failure_block="$(mktemp)"
trap 'rm -f "$results" "$failure_block"' EXIT

for suite in $suites; do
  # Skip the ones just reported, so the count above and the runs below can never disagree.
  if grep -qE '@(module)?tag :requires_[a-z_]+' "$suite" 2>/dev/null; then
    printf 'SKIP\t-\t%s\n' "$suite" >> "$results"
    continue
  fi

  printf '%-84s' "$suite"
  # ELIXIR_LOG_LEVEL=warning: without it, SQL debug logging floods the output and (as happened in CI)
  # buries the actual assertion so far above the failure marker that a tail cannot reach it.
  if out="$(ELIXIR_LOG_LEVEL=warning mix test --include postgres_integration "$suite" 2>&1)"; then
    line="$(printf '%s\n' "$out" | grep -E '^Result:' | tail -1 || true)"
    echo "$line"
    printf 'PASS\t%s\t%s\n' "$(printf '%s' "$line" | grep -oE '[0-9]+ passed' || echo '? passed')" "$suite" >> "$results"
  else
    echo "FAILED"
    # Print the ExUnit FAILURE BLOCKS (test name → stacktrace), not a raw tail: the raw tail showed
    # whatever happened to be last — usually noise — and the person reading CI never saw the assertion.
    printf '%s\n' "$out" |
      awk '/^  [0-9]+\) test /{p=1} p{print} p&&/^$/{blank++; if (blank>=2) {p=0; blank=0}}' \
      > "$failure_block"
    sed -n '1,80p' "$failure_block"

    summary="$(printf '%s\n' "$out" | grep -E "tests, [0-9]+ failure" | tail -1 || true)"
    [ -n "$summary" ] && echo "$summary"
    echo "--------------------------------------------------------------------------------"

    printf 'FAIL\t%s\t%s\n' "$(printf '%s' "$summary" | grep -oE '[0-9]+ failures?' || echo '? failures')" "$suite" >> "$results"
    fail=1
  fi
done

# THE TABLE. A run that ends without one is indistinguishable from a run that died halfway, which is
# exactly the ambiguity this replaces.
passed_suites=$(grep -c '^PASS' "$results" || true)
failed_suites=$(grep -c '^FAIL' "$results" || true)
skipped_suites=$(grep -c '^SKIP' "$results" || true)

echo ""
echo "==> SUMMARY"
awk -F'\t' '{ printf "  %-6s %-14s %s\n", $1, $2, $3 }' "$results"
echo ""
echo "==> ${passed_suites:-0} passed, ${failed_suites:-0} failed, ${skipped_suites:-0} skipped (of $total_count)"

if [ "$fail" -ne 0 ]; then
  echo "==> POSTGRES SUITES FAILED"
  grep '^FAIL' "$results" | awk -F'\t' '{ print "      " $3 }'
else
  echo "==> all postgres suites passed"
fi
exit "$fail"
