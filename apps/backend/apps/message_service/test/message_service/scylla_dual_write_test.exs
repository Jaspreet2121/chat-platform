defmodule MessageService.ScyllaDualWriteTest do
  @moduledoc """
  C7 live (`@tag :scylla_integration`, both engines): dual-write with Postgres authoritative.

    * SHADOW ISOLATION — with the Scylla client unavailable, the user's write succeeds with Postgres
      semantics and the failure is RECORDED as a row (not just logged);
    * NO DOUBLE WEBHOOKS — the dual path emits via the Postgres transaction only (one pending row,
      zero staged);
    * REPAIR consumes the failure records and rebuilds from authority;
    * THE RACE — backfill runs WHILE concurrent writers send and edit through the dual adapter; the
      verify-then-recopy discipline converges to zero stale diffs (proven, not reasoned);
    * THE GATE — the report splits stale diffs from in-flight lag by the horizon.
  """
  use ExUnit.Case, async: false

  alias MessageService.MessageStore.DualWriteAdapter
  alias MessageService.MessageStore.ScyllaAdapter
  alias MessageService.Repo
  alias MessageService.ScyllaBackfill
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      client: Application.get_env(:message_service, :scylla_client_adapter),
      async: Application.get_env(:message_service, :scylla_shadow_async)
    }

    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)
    # Inline mirrors for determinism (the status-sweep precedent); concurrency in the race test
    # comes from concurrent WRITER tasks, each mirroring inline.
    Application.put_env(:message_service, :scylla_shadow_async, false)

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:message_service, key, value),
          else: Application.delete_env(:message_service, key)
      end

      restore.(:scylla_client_adapter, previous.client)
      restore.(:scylla_shadow_async, previous.async)
      ensure_no_cluster()
    end)

    :ok
  end

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # SHARED mode: the race test's writer/backfill TASKS must see this test's uncommitted fixtures —
    # in the default :auto mode a task checks out a FRESH connection and the conversation row is
    # invisible (every put fails :message_invalid). Shared serializes them onto this one connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    conversation = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [sender, @tenant_zero, "#{sender}@test.local"]
    )

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, sender]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
      [conversation, sender]
    )

    {:ok, conversation: conversation, sender: sender}
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end

    wait_unregistered(50)
  catch
    :exit, _ -> wait_unregistered(50)
  end

  defp wait_unregistered(0), do: :ok

  defp wait_unregistered(tries) do
    case Process.whereis(@cluster) do
      nil -> :ok
      _ -> Process.sleep(20) && wait_unregistered(tries - 1)
    end
  end

  @gregorian_offset 0x01B21DD213814000

  # Production message ids are ALWAYS v1 timeuuids (Messages.generate_timeuuid/0) — the CQL column
  # and the bucket derivation both depend on it. A v4 here is a test bug, not a scenario.
  defp timeuuid_at(%DateTime{} = dt) do
    timestamp = DateTime.to_unix(dt, :microsecond) * 10 + @gregorian_offset

    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = timestamp |> Bitwise.bsr(32) |> Bitwise.band(0xFFFF)
    time_hi = timestamp |> Bitwise.bsr(48) |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x1000)

    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = clock_seq |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
  end

  defp put!(conversation, sender, body) do
    {:ok, message} =
      DualWriteAdapter.put_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body,
        "metadata" => %{},
        "status" => "active",
        "message_id" => timeuuid_at(DateTime.utc_now()),
        "created_at" => DateTime.utc_now()
      })

    message
  end

  defp failures do
    %{rows: rows} =
      Repo.query!(
        "SELECT op, reason, resolved_at FROM scylla_mirror_failures ORDER BY inserted_at",
        []
      )

    Enum.map(rows, fn [op, reason, resolved] -> %{op: op, reason: reason, resolved: resolved} end)
  end

  test "DUAL WRITE: one send lands in BOTH stores; edits, deletes and receipts mirror too",
       %{conversation: conversation, sender: sender} do
    message = put!(conversation, sender, "both stores")

    # Authoritative read (Postgres) and the shadow (Scylla point read) agree.
    assert {:ok, %{body: "both stores"}} =
             MessageService.MessageStore.PostgresAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })

    assert {:ok, shadow} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })

    assert shadow.body == "both stores"

    # Edit mirrors.
    {:ok, _} =
      DualWriteAdapter.update_message(%{
        "conversation_id" => conversation,
        "message_id" => message.message_id,
        "body" => "edited in both",
        "edited_at" => DateTime.utc_now()
      })

    assert {:ok, %{body: "edited in both", status: "edited"}} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })

    # Receipt mirrors (delivered): visible in the Scylla receipts partition.
    reader = Ecto.UUID.generate()

    {:ok, _} =
      DualWriteAdapter.mark_delivered(%{
        "conversation_id" => conversation,
        "message_id" => message.message_id,
        "user_id" => reader,
        "updated_at" => DateTime.utc_now()
      })

    plan =
      MessageService.Persistence.MessageReceipts.list_for_message_plan(%{
        "conversation_id" => conversation,
        "message_id" => message.message_id
      })

    assert {:ok, %{rows: [receipt]}} = XandraAdapter.execute(plan.statement, plan.params, [])
    assert receipt["user_id"] == reader

    # Delete mirrors.
    {:ok, _} =
      DualWriteAdapter.delete_message(%{
        "conversation_id" => conversation,
        "message_id" => message.message_id,
        "deleted_at" => DateTime.utc_now()
      })

    assert {:ok, %{status: "deleted"}} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })

    assert failures() == []
  end

  test "NO DOUBLE WEBHOOKS: the dual path emits via the Postgres transaction only",
       %{conversation: conversation, sender: sender} do
    Repo.query!(
      "UPDATE users_auth SET external_id = $2 WHERE id = $1::text::uuid",
      [sender, "ext-#{sender}"]
    )

    Repo.query!(
      "INSERT INTO webhook_endpoints (app_id, url, signing_secret, enabled, event_types) " <>
        "VALUES ($1::text::uuid, 'https://integrator.test/hook', 'secret', true, ARRAY['message.created'])",
      [@tenant_zero]
    )

    put!(conversation, sender, "webhook once")

    %{rows: rows} = Repo.query!("SELECT status, count(*) FROM webhook_outbox GROUP BY status", [])
    assert rows == [["pending", 1]]
  end

  test "SHADOW ISOLATION: an unavailable Scylla never fails the write — and the failure is a ROW",
       %{conversation: conversation, sender: sender} do
    Application.put_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.UnavailableClient)

    message =
      try do
        put!(conversation, sender, "postgres only, for now")
      after
        Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)
      end

    # The user's write succeeded with full Postgres semantics.
    assert {:ok, %{body: "postgres only, for now"}} =
             MessageService.MessageStore.PostgresAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })

    # RECORDED, not just logged.
    assert [%{op: "put", resolved: nil, reason: reason}] = failures()
    assert reason =~ "unavailable"

    # And REPAIR consumes the record: rebuilds from authority, stamps resolved, Scylla now has it.
    assert %{repaired: 1, gone: 0} = ScyllaBackfill.repair_failures()
    assert [%{resolved: %DateTime{}}] = failures()

    assert {:ok, %{body: "postgres only, for now"}} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation,
               "message_id" => message.message_id
             })
  end

  test "THE RACE: backfill during live dual-writes and edits converges — proven, not reasoned",
       %{conversation: conversation, sender: sender} do
    # 40 pre-existing messages that ONLY Postgres has (written before dual-write was on).
    for i <- 1..40 do
      {:ok, _} =
        MessageService.MessageStore.PostgresAdapter.put_message(%{
          "conversation_id" => conversation,
          "sender_user_id" => sender,
          "message_type" => "text",
          "body" => "history #{i}",
          "metadata" => %{},
          "status" => "active",
          "message_id" => timeuuid_at(DateTime.add(DateTime.utc_now(), -i * 10, :second)),
          "created_at" => DateTime.add(DateTime.utc_now(), -i * 10, :second)
        })
    end

    # Live writers race the backfill: 3 tasks x (5 sends + an edit each) through the DUAL adapter,
    # while the backfill walks the same conversation. Sandbox allowance flows via $callers.
    writers =
      for w <- 1..3 do
        Task.async(fn ->
          for i <- 1..5 do
            message = put!(conversation, sender, "live #{w}-#{i}")

            {:ok, _} =
              DualWriteAdapter.update_message(%{
                "conversation_id" => conversation,
                "message_id" => message.message_id,
                "body" => "live #{w}-#{i} EDITED",
                "edited_at" => DateTime.utc_now()
              })
          end

          :ok
        end)
      end

    backfill = Task.async(fn -> ScyllaBackfill.backfill_conversation(conversation) end)

    Enum.each(writers, &Task.await(&1, 30_000))
    copied = Task.await(backfill, 60_000)
    assert copied >= 40

    # VERIFY-THEN-RECOPY: first pass may catch the stale-overwrite window; the recopy happens-after
    # every edit, so the second pass MUST be clean. horizon -5s => nothing is excused as in-flight.
    first = ScyllaBackfill.verify(conversation, horizon_seconds: -5, sample: 1.0)
    :ok = ScyllaBackfill.recopy(conversation, first.stale_diffs)

    second = ScyllaBackfill.verify(conversation, horizon_seconds: -5, sample: 1.0)
    assert second.stale_diffs == []
    assert second.postgres_count == 55
    assert second.scylla_count == 55
  end

  test "THE GATE: the report separates stale divergence from in-flight lag by the horizon",
       %{conversation: conversation, sender: sender} do
    # One OLD message never mirrored (a true divergence) and one FRESH one never mirrored (lag).
    old = timeuuid_at(DateTime.add(DateTime.utc_now(), -3_600, :second))
    fresh = timeuuid_at(DateTime.utc_now())

    for {id, seconds_ago} <- [{old, 3_600}, {fresh, 1}] do
      {:ok, _} =
        MessageService.MessageStore.PostgresAdapter.put_message(%{
          "conversation_id" => conversation,
          "sender_user_id" => sender,
          "message_type" => "text",
          "body" => "unmirrored",
          "metadata" => %{},
          "status" => "active",
          "message_id" => id,
          "created_at" => DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        })
    end

    result = ScyllaBackfill.verify(conversation, sample: 1.0)

    assert old in result.stale_diffs
    refute fresh in result.stale_diffs
    assert fresh in result.in_flight

    report = ScyllaBackfill.report(conversation_ids: [conversation], sample: 1.0)
    assert report.stale_diff_total >= 1
    assert report.in_flight_total >= 1
  end
end
