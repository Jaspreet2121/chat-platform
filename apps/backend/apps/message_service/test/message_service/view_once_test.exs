defmodule MessageService.ViewOnceTest do
  @moduledoc """
  View-once (115) against a real database: the open ledger, the gate's state machine, and lazy
  expiry. The behaviour that matters here is all SQL — write-once inserts, idempotent replay, and
  a NOT EXISTS scan — none of which compiling proves anything about.
  """
  use MessageService.DataCase, async: false

  alias MessageService.MessageStore
  alias MessageService.ViewOnce

  @app "00000000-0000-0000-0000-000000000001"

  setup do
    # THE LOOKUPS GO THROUGH THE CONFIGURED ADAPTER NOW, so a test that seeds rows into Postgres has
    # to select the Postgres adapter — previously they read `messages` directly and the store's
    # configuration was irrelevant. That indifference to the adapter is exactly what let the open
    # path 404 in production, where the store is Scylla and `messages` is empty.
    previous = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:message_service, :message_store_adapter, previous),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @app, "#{id}@vo.test"]
    )

    id
  end

  defp conversation! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, now(), now())",
      [id, @app, user!()]
    )

    id
  end

  defp message!(sender, opts) do
    id = Ecto.UUID.generate()
    media_id = Keyword.get(opts, :media_id, Ecto.UUID.generate())
    view_once = Keyword.get(opts, :view_once, true)
    age_days = Keyword.get(opts, :age_days, 0)
    conversation_id = Keyword.get(opts, :conversation_id, conversation!())

    Repo.query!(
      """
      INSERT INTO messages
        (message_id, conversation_id, app_id, sender_user_id, message_type, media_id, status,
         view_once, created_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, 'media',
              $5::text::uuid, 'active', $6, now() - ($7::text || ' days')::interval)
      """,
      [id, conversation_id, @app, sender, media_id, view_once, Integer.to_string(age_days)]
    )

    %{message_id: id, media_id: media_id, conversation_id: conversation_id}
  end

  @tag :postgres_integration
  test "the gate's five states, against real rows" do
    sender = user!()
    recipient = user!()
    m = message!(sender, [])

    # (a) recipient PRE-open
    assert ViewOnce.state(m.media_id, recipient) == :unopened
    # (c) the SENDER is never a viewer of their own view-once send
    assert ViewOnce.state(m.media_id, sender) == :sender

    assert {:ok, %{first_open?: true}} = ViewOnce.open(m.conversation_id, m.message_id, recipient)

    # (b) recipient POST-open
    assert ViewOnce.state(m.media_id, recipient) == :opened
    # ...and only for the user who opened it.
    assert ViewOnce.state(m.media_id, user!()) == :unopened
  end

  @tag :postgres_integration
  test "ordinary media is :not_view_once — the agreement property's precondition" do
    sender = user!()
    m = message!(sender, view_once: false)

    assert ViewOnce.state(m.media_id, user!()) == :not_view_once
    # An id no message references at all.
    assert ViewOnce.state(Ecto.UUID.generate(), user!()) == :not_view_once
  end

  @tag :postgres_integration
  test "OPEN IS IDEMPOTENT: a replay returns the ORIGINAL opened_at and is not a first open" do
    recipient = user!()
    m = message!(user!(), [])

    assert {:ok, %{opened_at: first, first_open?: true}} =
             ViewOnce.open(m.conversation_id, m.message_id, recipient)

    assert {:ok, %{opened_at: replay, first_open?: false}} =
             ViewOnce.open(m.conversation_id, m.message_id, recipient)

    # Identical timestamp: a client retrying a lost response cannot move it...
    assert replay == first
    # ...and first_open? false is what stops a second purge.
    assert {:ok, %{first_open?: false}} =
             ViewOnce.open(m.conversation_id, m.message_id, recipient)
  end

  @tag :postgres_integration
  test "the SENDER cannot open their own view-once message" do
    sender = user!()
    m = message!(sender, [])

    assert {:error, :sender_cannot_open} = ViewOnce.open(m.conversation_id, m.message_id, sender)
  end

  @tag :postgres_integration
  test "opening a NON-view-once message is not found (opaque, no existence reveal)" do
    m = message!(user!(), view_once: false)

    assert {:error, :not_found} = ViewOnce.open(m.conversation_id, m.message_id, user!())
    assert {:error, :not_found} = ViewOnce.open(m.conversation_id, Ecto.UUID.generate(), user!())
  end

  @tag :postgres_integration
  test "LAZY EXPIRY: unopened past the window is :expired, and appears in the purge sweep" do
    recipient = user!()
    stale = message!(user!(), age_days: ViewOnce.expiry_days() + 1)
    fresh = message!(user!(), age_days: ViewOnce.expiry_days() - 1)

    assert ViewOnce.state(stale.media_id, recipient) == :expired
    assert ViewOnce.state(fresh.media_id, recipient) == :unopened

    expired = ViewOnce.expired_unopened_media()
    assert stale.media_id in expired
    refute fresh.media_id in expired
  end

  @tag :postgres_integration
  test "an OPENED message never appears in the expiry sweep — its blob is already purged" do
    recipient = user!()
    m = message!(user!(), age_days: ViewOnce.expiry_days() + 1)

    {:ok, _} = ViewOnce.open(m.conversation_id, m.message_id, recipient)

    refute m.media_id in ViewOnce.expired_unopened_media()
  end

  @tag :postgres_integration
  test "the sweep is BOUNDED — a backlog cannot become an unbounded query on a user request" do
    sender = user!()

    for _ <- 1..60, do: message!(sender, age_days: ViewOnce.expiry_days() + 1)

    assert length(ViewOnce.expired_unopened_media()) <= 50
  end
end
