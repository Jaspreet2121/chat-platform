#!/usr/bin/env bash
#
# THE ROLLBACK DRILL (C8): boots both engines, then runs scripts/rollback_drill.exs inside the
# message-service context — flip to Scylla reads, BREAK Scylla mid-traffic, observe, roll back
# (timed), prove zero loss. Run it BEFORE any production flip; the runbook
# (docs/09-devops/SCYLLA_FLIP_RUNBOOK.md) requires a green drill as a precondition.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Both engines, same ownership rules as test-scylla.sh.
if ! (command -v pg_isready >/dev/null 2>&1 && pg_isready -h localhost -p 5432 >/dev/null 2>&1); then
  docker compose -f infra/docker/docker-compose.yml up -d postgres
  i=0
  until docker exec chat-platform-postgres pg_isready -U chat_user >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "postgres never became ready"; exit 1; }
    sleep 1
  done
fi

docker compose -f infra/docker/docker-compose.yml up -d scylladb
i=0
until docker exec chat-platform-scylladb cqlsh -e "SELECT release_version FROM system.local" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -ge 60 ] && { echo "scylla never became ready"; exit 1; }
  sleep 3
done

for f in infra/docker/scylladb/init/*.cql; do
  out="$(docker exec -i chat-platform-scylladb cqlsh < "$f" 2>&1)" && continue
  echo "$out" | grep -q "conflicts with an existing column" || { echo "CQL LOAD FAILED: $f"; echo "$out"; exit 1; }
done

cd apps/backend

# The drill runs against the REAL test database with the REAL adapters; persistence on, shadow
# mirrors inline so every phase is deterministic.
SCYLLA_TEST_NODES="${SCYLLA_TEST_NODES:-localhost:9042}" \
MIX_ENV=test \
mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:message_service)
  {:ok, _} = MessageService.Repo.start_link()
  # :auto sandbox mode = real connections, writes persist in chat_platform_test (the drill uses its
  # own conversation; the gate rebuilds the DB anyway).
  Ecto.Adapters.SQL.Sandbox.mode(MessageService.Repo, :auto)
  nodes = System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)
  case SharedInfra.Scylla.XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages") do
    {:ok, _} -> :ok
    # already supervised by the app tree — the boot-safety :ignore, fine.
    :ignore -> :ok
  end
  Process.sleep(2_000)
  Application.put_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.XandraAdapter)
  Application.put_env(:message_service, :scylla_shadow_async, false)
  Application.put_env(:message_service, :message_persistence, true)
  Code.eval_file("../../scripts/rollback_drill.exs")
'
