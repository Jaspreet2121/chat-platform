# THE ROLLBACK DRILL (C8) — run with:  ./scripts/rollback-drill.sh
#
# Proves, against LIVE engines, the four things the runbook claims — by doing them, not describing
# them: (1) flip reads to Scylla under dual-write; (2) BREAK IT (stop the Scylla container
# mid-traffic) and observe exactly what a user experiences; (3) flip back and prove ZERO LOSS by
# count and field-diff; (4) measure the rollback, end to end, as an operator would perform it.
#
# Safe to run repeatedly: uses its own conversation, restarts the container it stops.

alias MessageService.MessageStore.{DualWriteAdapter, PostgresAdapter, ScyllaReadAdapter}

defmodule Drill do
  @tenant_zero "00000000-0000-0000-0000-000000000001"
  @gregorian_offset 0x01B21DD213814000

  def timeuuid_now do
    timestamp = System.os_time(:microsecond) * 10 + @gregorian_offset
    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = timestamp |> Bitwise.bsr(32) |> Bitwise.band(0xFFFF)
    time_hi = timestamp |> Bitwise.bsr(48) |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x1000)
    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = clock_seq |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low, time_mid, time_hi, clock_seq, node
    ])
    |> IO.iodata_to_binary()
  end

  def setup! do
    conversation = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()

    MessageService.Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [sender, @tenant_zero, "#{sender}@drill.local"]
    )

    MessageService.Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, sender]
    )

    MessageService.Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
      [conversation, sender]
    )

    {conversation, sender}
  end

  def send!(adapter, conversation, sender, body) do
    adapter.put_message(%{
      "conversation_id" => conversation,
      "sender_user_id" => sender,
      "message_type" => "text",
      "body" => body,
      "metadata" => %{},
      "status" => "active",
      "message_id" => timeuuid_now(),
      "created_at" => DateTime.utc_now()
    })
  end

  def pg_bodies(conversation) do
    %{rows: rows} =
      MessageService.Repo.query!(
        "SELECT message_id::text, body FROM messages WHERE conversation_id = $1::text::uuid " <>
          "ORDER BY created_at",
        [conversation]
      )

    Map.new(rows, fn [id, body] -> {id, body} end)
  end

  def banner(text), do: IO.puts("\n=== #{text} ===")
end

{conversation, sender} = Drill.setup!()
sent = :ets.new(:drill_sent, [:public, :ordered_set])

record = fn id, body -> :ets.insert(sent, {id, body}) end

# ------------------------------------------------------------------ PHASE 1: dual-write baseline
Drill.banner("PHASE 1 — dual-write on, 10 messages")
Application.put_env(:message_service, :message_store_adapter, DualWriteAdapter)

for i <- 1..10 do
  {:ok, m} = Drill.send!(DualWriteAdapter, conversation, sender, "phase1-#{i}")
  record.(m.message_id, "phase1-#{i}")
end

Process.sleep(1_000)
IO.puts("sent 10 via dual-write; scylla shadow settling")

# ------------------------------------------------------------------ PHASE 2: THE FLIP (reads -> scylla)
Drill.banner("PHASE 2 — FLIP: reads served from Scylla (writes still dual)")
flip_started = System.monotonic_time(:millisecond)
Application.put_env(:message_service, :message_store_adapter, ScyllaReadAdapter)
flip_ms = System.monotonic_time(:millisecond) - flip_started

{:ok, page} = ScyllaReadAdapter.list_messages(%{"conversation_id" => conversation, "limit" => 5})
IO.puts("flip took #{flip_ms}ms; scylla-served page of #{length(page.messages)} (newest: #{hd(page.messages).body})")

for i <- 1..5 do
  {:ok, m} = Drill.send!(ScyllaReadAdapter, conversation, sender, "phase2-#{i}")
  record.(m.message_id, "phase2-#{i}")
end

IO.puts("5 more sent DURING the scylla-read window")

# ------------------------------------------------------------------ PHASE 3: BREAK IT ON PURPOSE
Drill.banner("PHASE 3 — BREAK: stopping the scylla container mid-traffic")
{_, 0} = System.cmd("docker", ["stop", "chat-platform-scylladb"], stderr_to_stdout: true)
Process.sleep(500)

# What does the USER experience? Writes and reads, observed separately:
write_result = Drill.send!(ScyllaReadAdapter, conversation, sender, "phase3-during-outage")

case write_result do
  {:ok, m} ->
    record.(m.message_id, "phase3-during-outage")
    IO.puts("WRITE during outage: SUCCEEDED (Postgres authoritative; shadow failure recorded)")

  other ->
    IO.puts("WRITE during outage: #{inspect(other)}  <-- would be a FINDING")
end

read_result = ScyllaReadAdapter.list_messages(%{"conversation_id" => conversation, "limit" => 5})

case read_result do
  {:error, reason} ->
    IO.puts("READ during outage: FAILED LOUDLY with #{inspect(reason)} (gateway maps to 503) — not silent")

  {:ok, page} ->
    IO.puts("READ during outage: returned #{length(page.messages)} rows  <-- would be a FINDING (should fail)")
end

%{rows: [[failure_count]]} =
  MessageService.Repo.query!(
    "SELECT count(*)::int FROM scylla_mirror_failures WHERE resolved_at IS NULL", []
  )

IO.puts("recorded shadow failures during outage: #{failure_count}")

# ------------------------------------------------------------------ PHASE 4: ROLLBACK, timed
Drill.banner("PHASE 4 — ROLLBACK (the operator's move, timed end to end)")
rollback_started = System.monotonic_time(:millisecond)
Application.put_env(:message_service, :message_store_adapter, PostgresAdapter)
{:ok, _} = PostgresAdapter.list_messages(%{"conversation_id" => conversation, "limit" => 1})
rollback_ms = System.monotonic_time(:millisecond) - rollback_started
IO.puts("ROLLBACK: put_env + first successful postgres-served read = #{rollback_ms}ms")

{:ok, m} = Drill.send!(PostgresAdapter, conversation, sender, "phase4-after-rollback")
record.(m.message_id, "phase4-after-rollback")

# ------------------------------------------------------------------ PHASE 5: ZERO LOSS, asserted
Drill.banner("PHASE 5 — ZERO LOSS: count + field-diff of EVERY message sent in every phase")
expected = :ets.tab2list(sent) |> Map.new()
actual = Drill.pg_bodies(conversation)

missing = Map.keys(expected) -- Map.keys(actual)

diverged =
  Enum.filter(expected, fn {id, body} -> Map.get(actual, id) != body end)

IO.puts("sent=#{map_size(expected)}  in_postgres=#{map_size(actual)}  missing=#{length(missing)}  field_diffs=#{length(diverged)}")

if missing == [] and diverged == [] and map_size(expected) == map_size(actual) do
  IO.puts("ZERO LOSS: PROVEN — every message from every phase (including during the outage and the scylla-read window) is present and correct in Postgres")
else
  IO.puts("LOSS DETECTED: #{inspect(missing: missing, diverged: diverged)}  <-- DRILL FAILED")
  System.halt(1)
end

# ------------------------------------------------------------------ restore
Drill.banner("RESTORE — restarting scylla for the next run")
{_, 0} = System.cmd("docker", ["start", "chat-platform-scylladb"], stderr_to_stdout: true)
Application.delete_env(:message_service, :message_store_adapter)
IO.puts("drill complete")
