defmodule MessageService.ForwardDepthTest do
  @moduledoc """
  FORWARD DEPTH — misinformation friction, not a statistic.

  The load-bearing test is that the value is SERVER-COMPUTED. A friction signal a client can reset to
  zero is worthless, and the client most motivated to reset it is the one spreading the message — so
  any `forward_depth` arriving in client metadata must be discarded, not trusted.

  The second thing worth pinning is that depth rides the MESSAGE, not the media: Android re-uploads
  media on forward, producing a new media_id and a new message, and the chain must survive that.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages

  @tenant "00000000-0000-0000-0000-000000000001"
  @cap 5

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
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, now(), now())",
      [id, @tenant, user!()]
    )

    id
  end

  defp send!(conversation_id, attrs \\ %{}) do
    {:ok, message} =
      Messages.create_message(
        Map.merge(
          %{
            "conversation_id" => conversation_id,
            "sender_user_id" => user!(),
            "message_type" => "text",
            "body" => "hello"
          },
          attrs
        )
      )

    message
  end

  defp depth(message) do
    metadata = Map.get(message, :metadata) || Map.get(message, "metadata") || %{}
    Map.get(metadata, "forward_depth")
  end

  defp forward!(source, target_conversation, extra \\ %{}) do
    send!(
      target_conversation,
      Map.merge(
        %{
          "forwarded_from_message_id" => Map.get(source, :message_id),
          "forwarded_from_conversation_id" => Map.get(source, :conversation_id)
        },
        extra
      )
    )
  end

  @tag :postgres_integration
  test "an ORIGINAL message carries no forward_depth at all" do
    # Absent, not 0 — an original is not "forwarded zero times", it is simply not a forward, and the
    # client should not have to distinguish those.
    assert depth(send!(conversation!())) == nil
  end

  @tag :postgres_integration
  test "a first forward is depth 1, and a chain increments" do
    a = conversation!()
    b = conversation!()
    c = conversation!()

    original = send!(a)
    first = forward!(original, b)
    second = forward!(first, c)

    assert depth(first) == 1
    assert depth(second) == 2
  end

  @tag :postgres_integration
  test "depth CAPS — the badge is a signal, not a tracking number" do
    conversation = conversation!()
    message = send!(conversation)

    final =
      Enum.reduce(1..(@cap + 3), message, fn _, current ->
        forward!(current, conversation!())
      end)

    assert depth(final) == @cap
  end

  @tag :postgres_integration
  test "A FORWARD RECOMPUTES from the source row, ignoring the depth the client claims" do
    a = conversation!()
    b = conversation!()

    original = send!(a)
    deep = forward!(original, b)
    deep = forward!(deep, conversation!())
    assert depth(deep) == 2

    # A spreader forwarding a well-travelled message, asserting it is fresh. The server must recompute
    # from the SOURCE ROW and ignore what arrived in metadata.
    laundered =
      forward!(deep, conversation!(), %{"metadata" => %{"forward_depth" => 0}})

    assert depth(laundered) == 3,
           "depth must be recomputed from the source, not taken from metadata"
  end

  @tag :postgres_integration
  test "a NON-FORWARD cannot carry an invented depth — the strip is what covers this case" do
    # Two DIFFERENT protections, worth separating because they fail independently:
    #   * a FORWARD is safe because the depth is recomputed and overwritten (test above);
    #   * a NON-FORWARD is safe only because the client's value is STRIPPED first — there is no
    #     recompute on this path to overwrite it.
    # An earlier version of these tests claimed the strip covered both; removing the strip proved it
    # did not, and only this case went red.
    message = send!(conversation!(), %{"metadata" => %{"forward_depth" => 4}})

    assert depth(message) == nil
  end

  @tag :postgres_integration
  test "MEDIA: depth survives the re-upload (a new media_id, a new message)" do
    a = conversation!()
    b = conversation!()

    original = send!(a, %{"message_type" => "media", "media_id" => uuid(), "caption" => "look"})
    assert depth(original) == nil

    # Android re-uploads on forward, so the copy is a NEW message with a DIFFERENT media_id. The
    # lineage cannot ride the media id, and does not — it rides the message.
    forwarded =
      forward!(original, b, %{
        "message_type" => "media",
        "media_id" => uuid(),
        "caption" => "look"
      })

    assert depth(forwarded) == 1
    refute Map.get(forwarded, :media_id) == Map.get(original, :media_id)
  end

  @tag :postgres_integration
  test "an UNTRACEABLE source is depth 1, not an error — a forward we cannot trace is still a forward" do
    forwarded =
      send!(conversation!(), %{
        "forwarded_from_message_id" => uuid(),
        "forwarded_from_conversation_id" => uuid()
      })

    assert depth(forwarded) == 1
  end
end
