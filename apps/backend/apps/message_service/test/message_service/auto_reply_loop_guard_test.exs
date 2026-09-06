defmodule MessageService.AutoReplyLoopGuardTest do
  @moduledoc """
  THE LOOP GUARD, ROUND-TRIPPED — the test the old one only looked like.

  `RealtimeGateway.AutoReplyConsumer` sends its replies with `metadata: %{"auto" => true}` and skips
  any inbound message carrying that flag, so an auto-reply can never trigger an auto-reply. The
  consumer suite asserted that SEND shape against a hand-built fixture and passed — while the guard
  was dead in production for every real message, because nothing in it ever crossed the store.

  `MessageService.Messages.stringify_value/1` coerces EVERY metadata value to a string at create
  time (messages.ex:1123), so the boolean becomes the string `"true"` on the way in and comes back
  that way. Production on 2026-09-06 held exactly that: `{"auto": "true", "auto_kind": "away"}`.

  So this test refuses to hand-build anything. It creates through the REAL create path, reads back
  through the SAME client call the consumer makes (`SharedInfra.MessageClient.get_message/1`), and
  feeds that message to the REAL guard. The coercion is asserted on the way through, so if the
  create path ever stops stringifying, this test says so rather than silently passing.

  Lives in message-service because the store does; the guard is reached by runtime dispatch —
  realtime_gateway is not a dep of this app and must not become one.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    prev_client = Application.get_env(:shared_infra, :message_client_adapter)

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    # The consumer reads through this seam; pin the in-process adapter so the test exercises the
    # real store rather than whatever the environment happens to select.
    Application.put_env(
      :shared_infra,
      :message_client_adapter,
      MessageService.MessageClientInProcess
    )

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)

      if prev_client,
        do: Application.put_env(:shared_infra, :message_client_adapter, prev_client),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  defp uuid, do: Ecto.UUID.generate()

  defp user! do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation! do
    id = uuid()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, now(), now())",
      [id, @tenant, user!()]
    )

    id
  end

  # Exactly what AutoReplyConsumer.send_reply/3 hands the message client.
  defp send_with_metadata!(metadata) do
    conversation_id = conversation!()

    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => conversation_id,
        "sender_user_id" => user!(),
        "message_type" => "text",
        "body" => "Auto-reply body",
        "metadata" => metadata
      })

    {conversation_id, created}
  end

  # The consumer's own read: SharedInfra.MessageClient.get_message/1, same arguments.
  defp read_back!(conversation_id, created) do
    {:ok, message} =
      SharedInfra.MessageClient.get_message(%{
        "conversation_id" => conversation_id,
        "message_id" => Map.get(created, :message_id) || Map.get(created, "message_id")
      })

    message
  end

  defp guard(message),
    do: apply(Module.concat([:RealtimeGateway, :AutoReplyConsumer]), :auto_message?, [message])

  defp stored_metadata(message),
    do: Map.get(message, :metadata) || Map.get(message, "metadata") || %{}

  @tag :postgres_integration
  test "a stored auto-reply IS recognised as automated — boolean in, string out, guard still true" do
    {conversation_id, created} = send_with_metadata!(%{"auto" => true, "auto_kind" => "away"})
    message = read_back!(conversation_id, created)

    # THE COERCION, asserted where it happens rather than assumed: the boolean did not survive.
    # If this ever fails, the create path changed and the guard's string clause can be revisited.
    assert stored_metadata(message)["auto"] == "true",
           "expected the create path to stringify the flag; got " <>
             inspect(stored_metadata(message))

    refute stored_metadata(message)["auto"] == true

    # ...and the guard, reading that stored message, still says "this is ours".
    assert guard(message),
           "the loop guard does not recognise a STORED auto-reply — an auto-reply can trigger " <>
             "another auto-reply (one extra per side per claim window)"
  end

  @tag :postgres_integration
  test "auto: false round-trips to \"false\" and is NOT automated — only the flag is truthy" do
    {conversation_id, created} = send_with_metadata!(%{"auto" => false, "auto_kind" => "away"})
    message = read_back!(conversation_id, created)

    assert stored_metadata(message)["auto"] == "false"

    refute guard(message),
           "a message flagged auto:false was treated as automated — the guard is matching any " <>
             "present value rather than the flag"
  end

  @tag :postgres_integration
  test "an ORDINARY message carries no flag and is not automated" do
    {conversation_id, created} = send_with_metadata!(%{"caption" => "just a message"})
    message = read_back!(conversation_id, created)

    assert stored_metadata(message)["auto"] == nil
    refute guard(message)
  end
end
