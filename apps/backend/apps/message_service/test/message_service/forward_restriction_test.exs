defmodule MessageService.ForwardRestrictionTest do
  @moduledoc """
  RESTRICTED SHARING (120), the enforcement half — the only part of the feature that is not
  client-side friction.

  A forward declares its lineage; when the SOURCE conversation has sharing_disabled, the send is
  refused before anything is stored. Driven through the REAL create path against real SQL, because
  the thing under test is a Postgres read of a column another service owns — a hand-built map would
  prove nothing about whether this service can see that column at all.

  What this deliberately does NOT claim: it stops a DECLARED forward. A client that strips its
  lineage, or a user who retypes the message, is indistinguishable from an original send, and no
  server can tell those apart. The closed path is the one that silently carried a restricted message
  out of the chat while the UI said sharing was off.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)
    end)

    :ok
  end

  @tag :postgres_integration
  test "a forward FROM a restricted conversation is refused — nothing stored" do
    sender = user!()
    source = conversation!(sender)
    destination = conversation!(sender)
    restrict!(source, true)

    source_message = message!(source, sender, "the restricted message")

    assert {:error, :forward_restricted} =
             forward(destination, sender, source, source_message),
           "a message was forwarded out of a chat whose members turned sharing off"

    # Refused BEFORE the write: the destination timeline has nothing in it.
    assert count_messages(destination) == 0
  end

  @tag :postgres_integration
  test "the SAME forward from an UNRESTRICTED conversation succeeds" do
    sender = user!()
    source = conversation!(sender)
    destination = conversation!(sender)

    source_message = message!(source, sender, "an ordinary message")

    assert {:ok, _} = forward(destination, sender, source, source_message)
    assert count_messages(destination) == 1
  end

  @tag :postgres_integration
  test "explicitly UNRESTRICTING lets it through again — the flag is read live, not cached" do
    sender = user!()
    source = conversation!(sender)
    destination = conversation!(sender)
    restrict!(source, true)

    source_message = message!(source, sender, "hello")
    assert {:error, :forward_restricted} = forward(destination, sender, source, source_message)

    restrict!(source, false)
    assert {:ok, _} = forward(destination, sender, source, source_message)
  end

  @tag :postgres_integration
  test "an ORDINARY send from a restricted conversation is untouched — this gates forwards only" do
    sender = user!()
    restricted = conversation!(sender)
    restrict!(restricted, true)

    assert {:ok, _} =
             Messages.create_message(%{
               "conversation_id" => restricted,
               "sender_user_id" => sender,
               "message_type" => "text",
               "body" => "talking inside the chat is not sharing"
             })
  end

  @tag :postgres_integration
  test "restricting the DESTINATION does not block forwards INTO it" do
    sender = user!()
    source = conversation!(sender)
    destination = conversation!(sender)
    restrict!(destination, true)

    source_message = message!(source, sender, "incoming")

    assert {:ok, _} = forward(destination, sender, source, source_message),
           "the destination's own setting was read instead of the source's — restricting a chat " <>
             "must stop its messages leaving, not stop messages arriving"
  end

  # --- helpers --------------------------------------------------------------------------------------

  defp forward(destination, sender, source_conversation, source_message_id) do
    Messages.create_message(%{
      "conversation_id" => destination,
      "sender_user_id" => sender,
      "message_type" => "text",
      "body" => "forwarded copy",
      "forwarded_from_message_id" => source_message_id,
      "forwarded_from_conversation_id" => source_conversation
    })
  end

  defp message!(conversation_id, sender, body) do
    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => conversation_id,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body
      })

    Map.get(created, :message_id) || Map.get(created, "message_id")
  end

  defp restrict!(conversation_id, value) do
    Repo.query!(
      "INSERT INTO conversation_settings (conversation_id, sharing_disabled) " <>
        "VALUES ($1::text::uuid, $2) " <>
        "ON CONFLICT (conversation_id) DO UPDATE SET sharing_disabled = EXCLUDED.sharing_disabled",
      [conversation_id, value]
    )
  end

  defp count_messages(conversation_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM messages WHERE conversation_id = $1::text::uuid",
        [conversation_id]
      )

    count
  end

  defp conversation!(creator) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) VALUES ($1::text::uuid, 'direct', $2::text::uuid)",
      [id, creator]
    )

    id
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end
end
