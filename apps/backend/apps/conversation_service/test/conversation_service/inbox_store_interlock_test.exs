defmodule ConversationService.InboxStoreInterlockTest do
  @moduledoc """
  THE MIRROR INTERLOCK. `MessageService.Projections.InboxFromTopic` refuses to run while the store IS
  Postgres; `ConversationService.InboxCounters` must refuse to run while it is NOT. Between them,
  exactly one writer maintains the inbox row in any configuration.

  WHAT THIS GUARDS, measured in production on 2026-08-08 under `MESSAGE_STORE_ADAPTER=scylla`: the
  reconciler recomputed `unread_count`, `oldest_unread_at` and all six `conversations.last_message_*`
  columns from the Postgres `messages` table, which had stopped receiving writes a week earlier. It
  reverted a live conversation's preview to a week-old message and reset the counter, every 300
  seconds, with no error anywhere — writes and reads were healthy the whole time.

  The assertions are on the ROWS, not on a return value. A gate that returns `:ok` while still
  writing would pass a return-value test, and "it returned :ok" is exactly the evidence that failed
  us: the reconciler always returned `:ok`.
  """
  use ConversationService.DataCase, async: false

  import ExUnit.CaptureLog

  alias ConversationService.InboxCounters

  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:shared_infra, :message_store_backend)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :message_store_backend, previous),
        else: Application.delete_env(:shared_infra, :message_store_backend)
    end)

    :ok
  end

  # A conversation whose MAINTAINED row says one thing and whose Postgres `messages` rows say
  # another — the exact production shape: the projection wrote a preview the frozen table cannot
  # justify. A reconciler that runs will overwrite the maintained values with the message row's.
  defp seed_divergent_row! do
    conversation = Ecto.UUID.generate()
    peer = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    stale_message = Ecto.UUID.generate()

    for u <- [sender, peer] do
      Repo.query!(
        "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
        [u, @app_id, "+1555#{System.unique_integer([:positive])}"]
      )
    end

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conversation, @app_id, sender]
    )

    for u <- [sender, peer] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [conversation, u]
      )
    end

    # The OLD message — all that a frozen Postgres store still holds.
    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
        "body, created_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "$4::text::uuid, 'text', 'stale postgres body', now() - interval '8 days')",
      [stale_message, conversation, @app_id, sender]
    )

    # The MAINTAINED row, as the topic projection left it: a newer message that exists only in the
    # new store, and an unread count the projection incremented.
    Repo.query!(
      "UPDATE conversations SET last_message_id = $2::text::uuid, last_message_at = now(), " <>
        "last_message_body = 'live scylla body', last_message_type = 'text', " <>
        "last_message_sender_id = $3::text::uuid WHERE id = $1::text::uuid",
      [conversation, Ecto.UUID.generate(), sender]
    )

    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 7, oldest_unread_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, peer]
    )

    %{conversation: conversation, peer: peer}
  end

  defp row(conversation) do
    %{rows: [[body, count]]} =
      Repo.query!(
        "SELECT c.last_message_body, cp.unread_count FROM conversations c " <>
          "JOIN conversation_participants cp ON cp.conversation_id = c.id " <>
          "WHERE c.id = $1::text::uuid AND cp.unread_count > 0",
        [conversation]
      )

    {body, count}
  end

  @tag :postgres_integration
  test "under scylla the reconciler writes NOTHING — preview and counter survive untouched" do
    %{conversation: conversation} = seed_divergent_row!()
    Application.put_env(:shared_infra, :message_store_backend, "scylla")

    log =
      capture_log(fn ->
        InboxCounters.reconcile_conversation(conversation)
      end)

    # The whole bug in one assertion: before the gate this read {"stale postgres body", <recount>}.
    assert row(conversation) == {"live scylla body", 7}
    assert log =~ "SKIPPED"
  end

  @tag :postgres_integration
  test "under scylla recount/2 writes nothing either — the reconciler is not its only caller" do
    %{conversation: conversation, peer: peer} = seed_divergent_row!()
    Application.put_env(:shared_infra, :message_store_backend, "scylla")

    capture_log(fn -> InboxCounters.recount(conversation, peer) end)

    assert row(conversation) == {"live scylla body", 7}
  end

  @tag :postgres_integration
  test "under POSTGRES it still reconciles — the gate is an interlock, not a disablement" do
    %{conversation: conversation} = seed_divergent_row!()
    Application.put_env(:shared_infra, :message_store_backend, "postgres")

    InboxCounters.reconcile_conversation(conversation)

    # Postgres IS the store here, so its `messages` rows are the truth and must win.
    assert {"stale postgres body", _} = row(conversation)
  end

  test "an UNKNOWN backend is treated as NOT Postgres — unset must never mean 'go ahead'" do
    Application.delete_env(:shared_infra, :message_store_backend)
    refute InboxCounters.postgres_authoritative?()

    # A container that never received MESSAGE_STORE_ADAPTER cannot claim the Postgres tables are
    # authoritative. Guessing "yes" is what corrupted production.
    for backend <- ["scylla", "scylla_read", "shadow_read", "", "nonsense"] do
      Application.put_env(:shared_infra, :message_store_backend, backend)
      refute InboxCounters.postgres_authoritative?(), "#{backend} must not be authoritative"
    end

    # dual_write still writes Postgres, so the recount is still correct on that rung.
    for backend <- ["postgres", "dual_write"] do
      Application.put_env(:shared_infra, :message_store_backend, backend)
      assert InboxCounters.postgres_authoritative?(), "#{backend} must be authoritative"
    end
  end

  test "reconcile_recent reports 0 reconciled rather than claiming work it refused" do
    Application.put_env(:shared_infra, :message_store_backend, "scylla")

    assert capture_log(fn -> assert InboxCounters.reconcile_recent(3600, 200) == 0 end) =~
             "SKIPPED"
  end
end
