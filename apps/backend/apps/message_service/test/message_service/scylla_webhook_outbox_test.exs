defmodule MessageService.ScyllaWebhookOutboxTest do
  @moduledoc """
  THE WRITE-AHEAD INTENT (C6), live against both engines (`@tag :scylla_integration`). This rung
  changed a PROMISE: the same-transaction enqueue is gone on the Scylla path, replaced by
  stage -> put -> promote with a sweeper resolving crash windows. What must hold, and is proven here
  rather than reasoned about:

    * NO LOST WEBHOOK — a crash between put and promote leaves a staged row the sweeper PROMOTES
      once it sees the message in Scylla (the crash-window test kills the flow between put and
      promote, literally skipping the promote call).
    * NO DUPLICATES — promotion is idempotent (only status='staged' flips) and the sweeper never
      creates rows; after sweep + sweep again there is EXACTLY ONE deliverable row, claimable once.
    * ABORT IS KEPT-AND-MARKED — a staged row whose message never landed becomes status='aborted'
      with a last_error an operator can read; it is never deleted and never claimed.
    * OUTAGE IS NOT ABSENCE — an unreachable store leaves rows staged; only the store ANSWERING
      "not found" aborts.
  """
  use ExUnit.Case, async: false

  alias MessageService.MessageStore.ScyllaAdapter
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Repo
  alias MessageService.WebhookOutboxSweeper
  alias SharedInfra.Scylla.XandraAdapter
  alias SharedInfra.WebhookOutbox

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @gregorian_offset 0x01B21DD213814000
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = Application.get_env(:message_service, :scylla_client_adapter)
    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:message_service, :scylla_client_adapter, previous),
        else: Application.delete_env(:message_service, :scylla_client_adapter)

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

    # One enabled endpoint subscribed to message.created, and a sender WITH an external_id (the
    # event builder drops senders without one).
    Repo.query!(
      "INSERT INTO webhook_endpoints (app_id, url, signing_secret, enabled, event_types) " <>
        "VALUES ($1::text::uuid, 'https://integrator.test/hook', 'secret', true, ARRAY['message.created'])",
      [@tenant_zero]
    )

    sender = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'x', now(), now())",
      [sender, @tenant_zero, "ext-#{sender}", "#{sender}@test.local"]
    )

    conversation = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, sender]
    )

    {:ok, sender: sender, conversation: conversation}
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

  defp timeuuid_now do
    timestamp = System.os_time(:microsecond) * 10 + @gregorian_offset

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

  defp message_attrs(conversation, sender) do
    now = DateTime.utc_now()

    %{
      "conversation_id" => conversation,
      "bucket_date" => now |> DateTime.to_date() |> Date.to_iso8601(),
      "message_id" => timeuuid_now(),
      "sender_user_id" => sender,
      "message_type" => "text",
      "body" => "webhook me",
      "media_id" => nil,
      "reply_to_message_id" => nil,
      "status" => "active",
      "metadata" => %{},
      "created_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil
    }
  end

  # `now()` is transaction-frozen in the sandbox (the raw-sql memory rule): a row created "now" is
  # never `created_at < now()`, so staleness must be STATED, not waited for.
  defp age_staged! do
    Repo.query!("UPDATE webhook_outbox SET created_at = now() - interval '2 seconds' WHERE status = 'staged'", [])
  end

  defp outbox_rows do
    %{rows: rows} =
      Repo.query!("SELECT id::text, status, last_error FROM webhook_outbox ORDER BY created_at", [])

    Enum.map(rows, fn [id, status, last_error] -> %{id: id, status: status, last_error: last_error} end)
  end

  test "HAPPY PATH: put stages then promotes — exactly one pending row, claimable exactly once",
       %{sender: sender, conversation: conversation} do
    {:ok, _} = ScyllaAdapter.put_message(message_attrs(conversation, sender))

    assert [%{status: "pending"}] = outbox_rows()

    # Claimable exactly once: the first claim takes it (-> delivering, hidden for the visibility
    # window); the second finds nothing due.
    assert [_row] = WebhookOutbox.claim_due(Repo, 10)
    assert [] = WebhookOutbox.claim_due(Repo, 10)
  end

  test "THE CRASH WINDOW: killed between put and promote — the sweeper delivers EXACTLY once",
       %{sender: sender, conversation: conversation} do
    attrs = message_attrs(conversation, sender)

    # Reproduce the crash literally: stage, execute the authoritative put, and DIE — no promote.
    {:ok, staged_ids} = MessageService.WebhookEvents.stage(@tenant_zero, attrs)
    assert length(staged_ids) == 1
    plan = MessageTimelineWrites.insert_message_plan(attrs)
    {:ok, _} = XandraAdapter.execute(plan.statement, plan.params, [])

    # The dispatcher CANNOT deliver a staged row — nothing is due before the sweeper resolves it.
    assert [] = WebhookOutbox.claim_due(Repo, 10)
    assert [%{status: "staged"}] = outbox_rows()

    # Sweep (stale window 0; rows explicitly aged past it — now() is frozen in the sandbox):
    age_staged!()
    assert %{promoted: 1, aborted: 0, left: 0} = WebhookOutboxSweeper.sweep(0)
    assert [%{status: "pending"}] = outbox_rows()

    # Sweep AGAIN — the re-promote race: nothing is staged, nothing changes, still ONE row.
    assert %{promoted: 0, aborted: 0, left: 0} = WebhookOutboxSweeper.sweep(0)
    assert [%{status: "pending"}] = outbox_rows()

    # And promote_staged aimed at the SAME id again (the lost-response retry) is a guarded no-op.
    assert {:ok, 0} = WebhookOutbox.promote_staged(Repo, staged_ids)

    # Exactly one delivery: one claim succeeds, the next finds nothing.
    assert [_row] = WebhookOutbox.claim_due(Repo, 10)
    assert [] = WebhookOutbox.claim_due(Repo, 10)
  end

  test "ABORT: a staged row whose message never landed is KEPT and MARKED, never delivered",
       %{sender: sender, conversation: conversation} do
    attrs = message_attrs(conversation, sender)

    # Stage the intent; the authoritative write never happens (the other half of the crash window).
    {:ok, _staged} = MessageService.WebhookEvents.stage(@tenant_zero, attrs)
    age_staged!()

    assert %{promoted: 0, aborted: 1, left: 0} = WebhookOutboxSweeper.sweep(0)

    # KEPT: the row still exists, marked, with an operator-readable reason naming what happened.
    assert [%{status: "aborted", last_error: reason}] = outbox_rows()
    assert reason =~ "never landed"

    # Never claimed, never delivered.
    assert [] = WebhookOutbox.claim_due(Repo, 10)
  end

  test "OUTAGE IS NOT ABSENCE: an unreachable store leaves rows staged for the next sweep",
       %{sender: sender, conversation: conversation} do
    attrs = message_attrs(conversation, sender)
    {:ok, _} = MessageService.WebhookEvents.stage(@tenant_zero, attrs)
    age_staged!()

    # Point the sweeper's store check at the unavailable stub — the store cannot ANSWER.
    Application.put_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.UnavailableClient)

    try do
      assert %{promoted: 0, aborted: 0, left: 1} = WebhookOutboxSweeper.sweep(0)
      assert [%{status: "staged"}] = outbox_rows()
    after
      Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)
    end
  end

  test "SYNCHRONOUS FAILURE: a put that errors aborts its staged rows immediately, with the reason",
       %{sender: sender, conversation: conversation} do
    Application.put_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.UnavailableClient)

    try do
      assert {:error, :message_store_unavailable} =
               ScyllaAdapter.put_message(message_attrs(conversation, sender))
    after
      Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)
    end

    assert [%{status: "aborted", last_error: reason}] = outbox_rows()
    assert reason =~ "before promote"
  end
end
