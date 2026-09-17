defmodule MessageService.ViewOnceLedgerTest do
  @moduledoc """
  THE VIEW-ONCE EXPIRY LEDGER (127) — and the sweep that had never seen a single candidate.

  Production, 2026-09-20: `messages` 0 rows, `messages.view_once` 0 rows, `view_once_opens` **10
  rows**. The feature was in daily use and `expired_unopened_media/0` selected `FROM messages`,
  which is empty under `MESSAGE_STORE_ADAPTER=scylla`. Every unopened view-once blob ever sent is
  still in MinIO.

  EVERY TEST HERE RUNS UNDER THE SCYLLA ADAPTER, deliberately. A Postgres-adapter test passes
  against the broken code — the `messages` row exists there — which is exactly how this shipped and
  survived a green suite. The store is the test.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.{Messages, MessageStore, ViewOnce, ViewOnceLedger}

  @tenant "00000000-0000-0000-0000-000000000001"

  # Captures every owner-scoped purge the sweep attempts, and can be told to fail.
  defmodule MediaFake do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{purges: [], fail: false} end, name: __MODULE__)
    def purges, do: Agent.get(__MODULE__, & &1.purges) |> Enum.reverse()
    def fail!, do: Agent.update(__MODULE__, &%{&1 | fail: true})

    def purge_asset(attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        {state.fail, %{state | purges: [attrs | state.purges]}}
      end)
      |> case do
        true -> {:error, :media_unavailable}
        false -> {:ok, %{purged: true}}
      end
    end
  end

  # The put FAILS: everything else behaves, but the authoritative Scylla write does not land. This is
  # the crash window the write ORDER exists to make safe.
  defmodule FailingScyllaClient do
    @moduledoc false
    @behaviour SharedInfra.Scylla.Client

    @impl true
    def prepare(statement, opts \\ []),
      do: MessageService.TestScyllaClient.prepare(statement, opts)

    @impl true
    def execute(statement, params, opts \\ []) do
      if String.contains?(statement, "INSERT INTO messages_by_conversation") do
        {:error, :simulated_crash_before_put}
      else
        MessageService.TestScyllaClient.execute(statement, params, opts)
      end
    end
  end

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        ),
      scylla: Application.get_env(:message_service, :scylla_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:message_service, :message_persistence, true)
    # THE STORE PRODUCTION RUNS. See the moduledoc.
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)
    Application.put_env(:shared_infra, :media_client_adapter, MediaFake)

    case MessageService.TestScyllaClient.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    MessageService.TestScyllaClient.reset()
    start_supervised!(%{id: MediaFake, start: {MediaFake, :start_link, []}})

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)
      Application.put_env(:message_service, :message_store_adapter, prev.adapter)

      if prev.scylla,
        do: Application.put_env(:message_service, :scylla_client_adapter, prev.scylla),
        else: Application.delete_env(:message_service, :scylla_client_adapter)

      if prev.media,
        do: Application.put_env(:shared_infra, :media_client_adapter, prev.media),
        else: Application.delete_env(:shared_infra, :media_client_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, 'active', now(), now())",
      [id, @tenant, hd(members)]
    )

    for member <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, member]
      )
    end

    id
  end

  defp send_view_once!(conversation, sender, media_id \\ nil) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "media",
        "media_id" => media_id || Ecto.UUID.generate(),
        "view_once" => true
      })

    message
  end

  defp ledger_row(message_id) do
    case Repo.query!(
           "SELECT media_id::text, sender_user_id::text, purged_at, expires_at " <>
             "FROM view_once_expiry WHERE message_id = $1::text::uuid",
           [message_id]
         ) do
      %{rows: [[media_id, sender, purged_at, expires_at]]} ->
        %{
          media_id: media_id,
          sender_user_id: sender,
          purged_at: purged_at,
          expires_at: expires_at
        }

      %{rows: []} ->
        nil
    end
  end

  # Move a row's deadline into the past — the sweep's candidate condition, without moving the clock.
  defp make_due!(message_id) do
    Repo.query!(
      "UPDATE view_once_expiry SET expires_at = now() - interval '1 day' " <>
        "WHERE message_id = $1::text::uuid",
      [message_id]
    )
  end

  @tag :postgres_integration
  test "MUT-1 guard: a view-once send writes a ledger row carrying the SENDER (the purge needs it)" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    media_id = Ecto.UUID.generate()

    message = send_view_once!(conversation, sender, media_id)

    row = ledger_row(message.message_id)
    refute is_nil(row), "no ledger row — the sweep can never see this message"
    assert row.media_id == media_id
    # Without this the owner-scoped purge refuses and the sweep deletes nothing.
    assert row.sender_user_id == sender
    assert row.purged_at == nil
    # 14 days out, materialised at write time.
    assert DateTime.diff(row.expires_at, DateTime.utc_now(), :second) > 13 * 86_400
    assert DateTime.diff(row.expires_at, DateTime.utc_now(), :second) <= 14 * 86_400
  end

  @tag :postgres_integration
  test "an ORDINARY media message and a text message write NO ledger row" do
    sender = user!()
    conversation = conversation!([sender, user!()])

    {:ok, plain} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "media",
        "media_id" => Ecto.UUID.generate()
      })

    {:ok, text} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => "hello"
      })

    assert ledger_row(plain.message_id) == nil
    assert ledger_row(text.message_id) == nil
  end

  @tag :postgres_integration
  test "MUT-3 guard: the sweep finds a candidate that exists ONLY in Scylla" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    media_id = Ecto.UUID.generate()

    message = send_view_once!(conversation, sender, media_id)
    make_due!(message.message_id)

    # THE FACT THAT BROKE IT: the message is not in Postgres at all.
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*)::int FROM messages", [])

    assert %{candidates: 1, purged: 1, failed: 0} = ViewOnce.sweep()

    # The purge was owner-scoped with the LEDGER's sender, not the opener or the app.
    assert [purge] = MediaFake.purges()
    assert purge["media_id"] == media_id
    assert purge["expected_owner_user_id"] == sender

    assert ledger_row(message.message_id).purged_at != nil
  end

  @tag :postgres_integration
  test "MUT-2 guard: OPENING deletes the row, so an opened message is never swept" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message = send_view_once!(conversation, sender)

    refute is_nil(ledger_row(message.message_id))

    assert {:ok, %{first_open?: true}} =
             ViewOnce.open(conversation, message.message_id, peer)

    assert ledger_row(message.message_id) == nil

    # Even long past the deadline there is nothing to find, and NOTHING is purged.
    make_due!(message.message_id)
    assert %{candidates: 0, purged: 0} = ViewOnce.sweep()
    assert MediaFake.purges() == []
  end

  @tag :postgres_integration
  test "MUT-5 guard: a FAILED purge leaves purged_at NULL and is retried next sweep" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    message = send_view_once!(conversation, sender)
    make_due!(message.message_id)

    MediaFake.fail!()

    log = capture_log(fn -> assert %{candidates: 1, purged: 0, failed: 1} = ViewOnce.sweep() end)
    assert log =~ "view_once purge failed"

    # UNSTAMPED: the blob is not confirmed gone, so the row must survive to be retried.
    assert ledger_row(message.message_id).purged_at == nil
    assert length(MediaFake.purges()) == 1

    # The next sweep sees it again.
    assert %{candidates: 1} = ViewOnce.sweep()
    assert length(MediaFake.purges()) == 2
  end

  @tag :postgres_integration
  test "MUT-4 guard: a ZERO-ROW run logs — 'ran and found nothing' must differ from 'never ran'" do
    log = capture_log([level: :info], fn -> assert %{candidates: 0} = ViewOnce.sweep() end)
    assert log =~ "view_once sweep purged=0 failed=0 candidates=0"
  end

  @tag :postgres_integration
  test "every run logs its counts, including a successful one" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    message = send_view_once!(conversation, sender)
    make_due!(message.message_id)

    log = capture_log([level: :info], fn -> ViewOnce.sweep() end)
    assert log =~ "view_once sweep purged=1 failed=0 candidates=1"
  end

  @tag :postgres_integration
  test "DRY RUN reports what it would purge and touches nothing" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    message = send_view_once!(conversation, sender)
    make_due!(message.message_id)

    log =
      capture_log([level: :info], fn ->
        assert %{candidates: 1, purged: 0, failed: 0, dry_run: true} =
                 ViewOnce.sweep(dry_run: true)
      end)

    assert log =~ "candidates=1"
    assert log =~ "dry_run=true"

    # Nothing deleted, nothing stamped.
    assert MediaFake.purges() == []
    assert ledger_row(message.message_id).purged_at == nil
  end

  @tag :postgres_integration
  test "a row NOT yet due is never a candidate" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    message = send_view_once!(conversation, sender)

    assert %{candidates: 0} = ViewOnce.sweep()
    assert MediaFake.purges() == []
    assert ledger_row(message.message_id).purged_at == nil
  end

  @tag :postgres_integration
  test "MUT-6 guard: the Scylla put FAILS and the ledger row still exists — never a blob with no row" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    media_id = Ecto.UUID.generate()

    # The staging transaction (which carries the ledger write) commits BEFORE the put. Make the put
    # fail and the asymmetry becomes visible: the row survives, the message does not.
    Application.put_env(:message_service, :scylla_client_adapter, FailingScyllaClient)

    result =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "media",
        "media_id" => media_id,
        "view_once" => true
      })

    assert {:error, _} = result

    %{rows: rows} =
      Repo.query!(
        "SELECT message_id::text FROM view_once_expiry WHERE media_id = $1::text::uuid",
        [media_id]
      )

    assert [[message_id]] = rows,
           "the ledger row is MISSING after a failed put — this blob could never be reclaimed"

    # A ROW WITH NO BLOB, which is the safe direction: the sweep purges a media id that does not
    # exist, the media service answers success, and the row stamps rather than retrying forever.
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)
    make_due!(message_id)

    assert %{candidates: 1, purged: 1, failed: 0} = ViewOnce.sweep()
    assert ledger_row(message_id).purged_at != nil
  end

  @tag :postgres_integration
  test "the batch is bounded at 50" do
    sender = user!()
    conversation = conversation!([sender, user!()])

    for _ <- 1..55 do
      message = send_view_once!(conversation, sender)
      make_due!(message.message_id)
    end

    assert ViewOnceLedger.sweep_batch() == 50
    assert %{candidates: 50, purged: 50} = ViewOnce.sweep()
    # The remainder is picked up by the next run.
    assert %{candidates: 5, purged: 5} = ViewOnce.sweep()
    assert %{candidates: 0} = ViewOnce.sweep()
  end

  @tag :postgres_integration
  test "an idempotent RESEND does not duplicate the ledger row" do
    sender = user!()
    conversation = conversation!([sender, user!()])

    attrs = %{
      "view_once" => true,
      "message_id" => Ecto.UUID.generate(),
      "media_id" => Ecto.UUID.generate(),
      "conversation_id" => conversation,
      "sender_user_id" => sender,
      "app_id" => @tenant,
      "created_at" => DateTime.utc_now()
    }

    ViewOnceLedger.record(attrs, 14)
    ViewOnceLedger.record(attrs, 14)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*)::int FROM view_once_expiry WHERE message_id = $1::text::uuid",
               [attrs["message_id"]]
             )
  end
end
