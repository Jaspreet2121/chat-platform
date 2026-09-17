defmodule MessageService.MessageRequestUnreadTest do
  @moduledoc """
  MESSAGE REQUESTS (128) — the counter and the status audience, the two surfaces a request could
  still have reached after the inbox list and the push were closed.

  MUT-7 guard: an unaccepted request raises the unread count → RED.

  The counter matters on its own, separately from the list: it is a THIRD write path (the Kafka inbox
  projection), and the app-icon badge sums exactly this column. Without the predicate a request would
  be absent from the list, silent on the lock screen, and still bump the number on the app icon —
  a notification with nothing behind it.
  """
  use MessageService.DataCase, async: false

  alias MessageService.InboxProjection
  alias MessageService.Statuses

  setup do
    previous = Application.get_env(:message_service, :message_persistence, false)
    Application.put_env(:message_service, :message_persistence, true)
    on_exit(fn -> Application.put_env(:message_service, :message_persistence, previous) end)
    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp direct!(sender, recipient, pending?) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) VALUES ($1::text::uuid, 'direct', $2::text::uuid)",
      [id, sender]
    )

    for u <- [sender, recipient] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now() - interval '1 day')",
        [id, u]
      )
    end

    if pending? do
      Repo.query!(
        "UPDATE conversation_participants SET request_pending_at = now() " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [id, recipient]
      )
    end

    id
  end

  defp unread(conversation_id, user_id) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        "SELECT unread_count FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    count
  end

  defp record!(conversation_id, sender) do
    InboxProjection.record_message(%{
      conversation_id: conversation_id,
      message_id: Ecto.UUID.generate(),
      sender_user_id: sender,
      message_type: "text",
      body: "hi",
      created_at: DateTime.utc_now()
    })
  end

  @tag :postgres_integration
  test "MUT-7 guard: messages into an unaccepted request do NOT raise the recipient's unread count" do
    sender = user!()
    recipient = user!()
    conversation = direct!(sender, recipient, true)

    for _ <- 1..3, do: record!(conversation, sender)

    assert unread(conversation, recipient) == 0
  end

  @tag :postgres_integration
  test "the same messages into an ACCEPTED conversation do raise it — the predicate is the only difference" do
    sender = user!()
    recipient = user!()
    conversation = direct!(sender, recipient, false)

    for _ <- 1..3, do: record!(conversation, sender)

    assert unread(conversation, recipient) == 3
  end

  @tag :postgres_integration
  test "after ACCEPT the counter resumes from the next message; earlier ones are not retro-counted" do
    sender = user!()
    recipient = user!()
    conversation = direct!(sender, recipient, true)

    for _ <- 1..3, do: record!(conversation, sender)
    assert unread(conversation, recipient) == 0

    Repo.query!(
      "UPDATE conversation_participants SET request_pending_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, recipient]
    )

    record!(conversation, sender)
    assert unread(conversation, recipient) == 1
  end

  @tag :postgres_integration
  test "a pending request does NOT admit the sender to the recipient's status audience" do
    owner = user!()
    stranger = user!()
    conversation = direct!(stranger, owner, true)

    {:ok, _post} =
      Statuses.post_status(%{"owner_user_id" => owner, "kind" => "text", "body" => "mine"})

    assert {:ok, %{threads: []}} = Statuses.feed(%{"viewer_user_id" => stranger})

    Repo.query!(
      "UPDATE conversation_participants SET request_pending_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid",
      [conversation]
    )

    assert {:ok, %{threads: [thread]}} = Statuses.feed(%{"viewer_user_id" => stranger})
    assert Map.get(thread, :owner_user_id) == owner
  end
end
