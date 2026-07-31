defmodule MessageService.PostgresMessageStoreTest do
  @moduledoc """
  Postgres-backed message store integration tests (real Repo, single repo →
  no cross-repo sandbox concern). Exercises the public MessageService boundary so
  authz/response building above the store are unchanged; only the storage backend
  differs (MESSAGE_STORE_ADAPTER=postgres).
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender_user_id "22222222-2222-4222-8222-222222222222"

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

    seed_conversation!()
    :ok
  end

  # REQUIRED since messages became tenant-anchored: put_message/1 resolves the conversation's
  # AUTHORITATIVE app_id and stamps it on the row, so a message whose conversation does not exist is
  # rejected with :message_invalid rather than landing under the tenant-zero default. These suites
  # predate that change and seeded no conversation, which is why they could never pass against a real
  # database — nothing ran them.
  defp seed_conversation! do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [@sender_user_id, "+911234500001"]
    )

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) " <>
        "VALUES ($1::text::uuid, 'group', $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conversation_id, @sender_user_id]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conversation_id, @sender_user_id]
    )
  end

  @tag :postgres_integration
  test "create then list round-trips a text message through Postgres" do
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Hello Postgres"
             })

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.message_id == created.message_id
    assert listed.sender_user_id == @sender_user_id
    assert listed.body == "Hello Postgres"
    assert listed.status == "active"
    assert is_binary(listed.created_at)
  end

  @tag :postgres_integration
  test "edit updates body/status and delete soft-deletes through Postgres" do
    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "text",
        "body" => "Original"
      })

    assert {:ok, edited} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id,
               "body" => "Edited Postgres"
             })

    assert edited.status == "edited"
    assert edited.body == "Edited Postgres"
    assert is_binary(edited.edited_at)

    assert {:ok, deleted} =
             Messages.delete_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id
             })

    assert deleted.deleted == true
    assert deleted.status == "deleted"

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.status == "deleted"
    assert is_binary(listed.deleted_at)
  end

  @tag :postgres_integration
  test "non-author cannot edit a message persisted in Postgres" do
    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "text",
        "body" => "Owned"
      })

    assert {:error, :message_forbidden} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => "33333333-3333-4333-8333-333333333333",
               "body" => "Hijack"
             })
  end

  @tag :postgres_integration
  test "media metadata round-trips through Postgres store -> load" do
    object_key = "media/#{@sender_user_id}/66666666-6666-4666-8666-666666666666/deck.pdf"

    {:ok, _created} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "media",
        "media_id" => "66666666-6666-4666-8666-666666666666",
        "caption" => "Quarterly deck",
        "metadata" => %{
          "object_key" => object_key,
          "filename" => "deck.pdf",
          "content_type" => "application/pdf",
          "size_bytes" => 123_456
        }
      })

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.message_type == "media"
    assert listed.media_id == "66666666-6666-4666-8666-666666666666"
    assert listed.caption == "Quarterly deck"

    assert listed.metadata["object_key"] == object_key
    assert listed.metadata["filename"] == "deck.pdf"
    assert listed.metadata["content_type"] == "application/pdf"
    assert listed.metadata["size_bytes"] == "123456"
    assert listed.metadata["media_id"] == "66666666-6666-4666-8666-666666666666"
  end
end
