defmodule MessageService.ViewerWindowTest do
  @moduledoc """
  THE HARD GUARANTEE for user-scoped "clear chat" / "auto-delete" (migration 060):

    * With `viewer_user_id` present (the USER path), the viewer's cleared_before /
      auto_delete_seconds narrow their list.
    * WITHOUT `viewer_user_id` (the ADMIN content-viewer path), the SAME list_messages call is
      NEVER narrowed — admin always sees everything.
    * Nothing is deleted: the messages table row count is unchanged throughout.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Repo

  @conversation_id "31111111-1111-4111-8111-111111111111"
  @sender_user_id "32222222-2222-4222-8222-222222222222"
  @viewer_user_id "33333333-3333-4333-8333-333333333333"

  setup do
    previous_persistence = Application.get_env(:message_service, :message_persistence, false)

    previous_adapter =
      Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, previous_persistence)
      Application.put_env(:message_service, :message_store_adapter, previous_adapter)
    end)

    :ok
  end

  # Seed the FK parents + the viewer's membership row (raw SQL — the message service reads, never
  # writes, conversation_participants; writes go through the conversation service in production).
  defp seed_membership! do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [@viewer_user_id, "+911234509876"]
    )

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) VALUES ($1::text::uuid, 'group', $2::text::uuid) " <>
        "ON CONFLICT DO NOTHING",
      [@conversation_id, @viewer_user_id]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conversation_id, @viewer_user_id]
    )
  end

  defp send_message!(body) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "text",
        "body" => body
      })

    message
  end

  # messages.message_id is uuid — Postgrex wants the 16-byte binary for a bare $N param.
  defp uuid!(id) do
    {:ok, binary} = Ecto.UUID.dump(id)
    binary
  end

  defp messages_row_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM messages WHERE conversation_id = $1::text::uuid", [
        @conversation_id
      ])

    count
  end

  defp user_list do
    {:ok, timeline} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "viewer_user_id" => @viewer_user_id
      })

    timeline.messages
  end

  defp admin_list do
    # EXACTLY the admin content-viewer shape (admin_content_controller): no viewer_user_id.
    {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    timeline.messages
  end

  @tag :postgres_integration
  test "clear chat narrows ONLY the viewer's list; admin stays unfiltered; nothing deleted" do
    seed_membership!()
    before1 = send_message!("before clear 1")
    before2 = send_message!("before clear 2")

    # Backdate the pre-clear messages: inside the test's sandbox transaction Postgres now() is pinned
    # to the transaction start, so a same-transaction "clear" wouldn't order after them otherwise.
    # (In production the clear naturally happens after the messages exist in real time.)
    Repo.query!(
      "UPDATE messages SET created_at = now() - interval '1 hour' WHERE message_id = ANY($1)",
      [[uuid!(before1.message_id), uuid!(before2.message_id)]]
    )

    assert length(user_list()) == 2
    assert length(admin_list()) == 2
    rows_before = messages_row_count()

    # "Clear chat" = stamp cleared_before on the viewer's own participant row (what the endpoint does).
    Repo.query!(
      "UPDATE conversation_participants SET cleared_before = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    # Viewer: history hidden. Admin: identical to before. DB: identical row count (nothing deleted).
    assert user_list() == []
    assert length(admin_list()) == 2
    assert messages_row_count() == rows_before

    # New messages after the clear are visible to the viewer again.
    send_message!("after clear")
    assert [visible] = user_list()
    assert visible.body == "after clear"
    assert length(admin_list()) == 3
  end

  @tag :postgres_integration
  test "auto-delete window narrows ONLY the viewer's list; admin stays unfiltered; nothing deleted" do
    seed_membership!()
    old = send_message!("old message")
    send_message!("fresh message")

    # Backdate one message beyond a 24h window (created_at is store-side; adjust directly).
    Repo.query!(
      "UPDATE messages SET created_at = now() - interval '2 days' WHERE message_id = $1",
      [uuid!(old.message_id)]
    )

    rows_before = messages_row_count()

    # Set the viewer's 24h rolling window (what the endpoint does).
    Repo.query!(
      "UPDATE conversation_participants SET auto_delete_seconds = 86400 " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    assert [visible] = user_list()
    assert visible.body == "fresh message"

    # Admin (no viewer_user_id): BOTH messages, unfiltered; row count unchanged.
    admin_bodies = admin_list() |> Enum.map(& &1.body) |> Enum.sort()
    assert admin_bodies == ["fresh message", "old message"]
    assert messages_row_count() == rows_before

    # Off restores the viewer's full (unclamped) view.
    Repo.query!(
      "UPDATE conversation_participants SET auto_delete_seconds = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    assert length(user_list()) == 2
  end

  @tag :postgres_integration
  test "after-viewing hides messages the VIEWER has READ; admin unfiltered; nothing deleted" do
    seed_membership!()
    read_msg = send_message!("read me")
    send_message!("still unread")

    # Mark the first message READ by the viewer (a receipt row with read_at — exactly what mark_read writes).
    Repo.query!(
      "INSERT INTO message_receipts (conversation_id, message_id, user_id, status, read_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'read', now(), now())",
      [@conversation_id, read_msg.message_id, @viewer_user_id]
    )

    rows_before = messages_row_count()

    # Enable "After viewing" on the viewer's own row (what the endpoint does for mode=after_viewing).
    Repo.query!(
      "UPDATE conversation_participants SET disappear_after_viewing = true " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    # Viewer: only the UNREAD message remains (the read one disappeared from their view).
    assert [visible] = user_list()
    assert visible.body == "still unread"

    # Admin (no viewer_user_id): BOTH messages, unfiltered; DB row count unchanged (nothing deleted).
    admin_bodies = admin_list() |> Enum.map(& &1.body) |> Enum.sort()
    assert admin_bodies == ["read me", "still unread"]
    assert messages_row_count() == rows_before

    # Off restores the viewer's full view.
    Repo.query!(
      "UPDATE conversation_participants SET disappear_after_viewing = false " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    assert length(user_list()) == 2
  end

  @tag :postgres_integration
  test "list_media returns only media messages, honors the viewer window, never deletes" do
    seed_membership!()
    send_message!("plain text")

    {:ok, media} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "media",
        "media_id" => "44444444-4444-4444-8444-444444444444",
        "metadata" => %{"object_key" => "media/x/photo.png", "content_type" => "image/png"}
      })

    {:ok, gallery} =
      MessageStore.list_media(%{
        "conversation_id" => @conversation_id,
        "viewer_user_id" => @viewer_user_id
      })

    assert [item] = gallery.items
    assert item.message_id == media.message_id
    assert item.message_type == "media"

    rows_before = messages_row_count()

    # Viewer clears → their gallery empties; the rows stay (and a viewer-less call still sees it).
    Repo.query!(
      "UPDATE conversation_participants SET cleared_before = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation_id, @viewer_user_id]
    )

    Repo.query!(
      "UPDATE messages SET created_at = now() - interval '1 hour' WHERE message_id = $1",
      [uuid!(media.message_id)]
    )

    {:ok, cleared_gallery} =
      MessageStore.list_media(%{
        "conversation_id" => @conversation_id,
        "viewer_user_id" => @viewer_user_id
      })

    assert cleared_gallery.items == []

    {:ok, unscoped} = MessageStore.list_media(%{"conversation_id" => @conversation_id})
    assert length(unscoped.items) == 1
    assert messages_row_count() == rows_before
  end

  @tag :postgres_integration
  test "viewer with NO prefs and absent membership row are never narrowed" do
    seed_membership!()
    send_message!("hello")

    # Membership row with NULL prefs → no narrowing.
    assert length(user_list()) == 1

    # A viewer with NO participant row at all (e.g. admin ids, other services) → no narrowing.
    {:ok, timeline} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "viewer_user_id" => "39999999-9999-4999-8999-999999999999"
      })

    assert length(timeline.messages) == 1
  end
end
