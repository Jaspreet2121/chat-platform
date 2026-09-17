defmodule NotificationService.PushPreviewStoreTest do
  @moduledoc """
  `PushContext.message_preview_fields/2` against the REAL message store.

  Nothing here is a double: a real `messages` row, read by the real
  `MessageService.MessageStore.PostgresAdapter`, served by the real `MessageService.HTTP.Router` over
  a real localhost listener, fetched by the real `SharedInfra.MessageClientHttp` through the real
  `SharedInfra.MessageClient` dispatcher — the adapter the notification container uses in production
  once `MESSAGE_CLIENT_ADAPTER=http` is set. See `NotificationService.MessageStoreFixture`.

  WHAT THIS GUARDS. The preview used to be a raw-SQL read against the shared Postgres. After the
  Scylla cutover that read returns nothing, `preview/3` falls through to its catch-all, and every
  notification says "New message" — a push that looks like it worked while carrying no content. The
  three outcomes below are the whole contract: a real message previews, a gone message sends nothing,
  and neither is ever confused with the third case (a broken read) which
  `NotificationService.PushPreviewFailureTest` covers.
  """
  use NotificationService.DataCase, async: false

  import ExUnit.CaptureLog

  alias NotificationService.MessageStoreFixture
  alias NotificationService.PushContext

  setup do
    MessageStoreFixture.start!()
    :ok
  end

  defp ids, do: {Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()}

  @tag :postgres_integration
  test "a FOUND message previews as its own body, read from the store" do
    {conversation, message, sender} = ids()
    MessageStoreFixture.insert_message!(conversation, message, sender, body: "the real body")

    assert {:ok, fields} = PushContext.message_preview_fields(conversation, message)
    assert fields.body == "the real body"
    assert fields.message_type == "text"

    # And the whole context, so the preview text itself is proven — not just the fields feeding it.
    assert {:ok, context} =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })

    assert context.preview == "the real body"
  end

  @tag :postgres_integration
  test "content_type comes out of the message's metadata (the media preview path)" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      message_type: "media",
      body: nil,
      metadata: %{"content_type" => "audio/webm"}
    )

    assert {:ok, fields} = PushContext.message_preview_fields(conversation, message)
    assert fields.content_type == "audio/webm"

    assert {:ok, context} =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })

    assert context.preview == "🎤 Voice message"
  end

  @tag :postgres_integration
  test "MUT-8 guard (126): a CHECKLIST pushes its TITLE only — no item text, no done_by, no counts" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      message_type: "checklist",
      body: "Weekend shop",
      metadata: %{
        "checklist" => %{
          "items" => [
            %{"id" => "i1", "text" => "divorce lawyer"},
            %{"id" => "i2", "text" => "eggs"}
          ],
          "others_can_check" => true,
          "others_can_add" => false
        }
      }
    )

    attrs = %{conversation_id: conversation, message_id: message, sender_user_id: sender}
    assert {:ok, context} = PushContext.message_context(attrs)

    # A checklist is a TEXT message to push — its body is the title, and that is all it sends.
    assert context.preview == "Weekend shop"
    assert Map.keys(context) |> Enum.sort() == [:group_name, :preview, :sender]

    data = NotificationService.FcmSender.message_data(context, attrs, 1)

    assert Map.keys(data) |> Enum.sort() ==
             [
               "conversation_id",
               "message_id",
               "preview",
               "sender_id",
               "sender_name",
               "type",
               "unread_count"
             ]

    encoded = Jason.encode!(data)
    refute encoded =~ "divorce lawyer"
    refute encoded =~ "eggs"
    refute encoded =~ "checklist"
    refute encoded =~ "done_by"
    refute encoded =~ sender_but_as_done_by(sender)
    # No count of any kind: "1/2", "done", "total" are all absent.
    refute encoded =~ "done_count"
    refute encoded =~ "total"
  end

  # The sender id legitimately appears as sender_id; this guards against it ALSO appearing as a
  # done_by value, which is what a leak of item state would look like.
  defp sender_but_as_done_by(sender), do: "\"done_by\":\"#{sender}\""

  @tag :postgres_integration
  test "MUT-3 guard: SPOILER text is masked out of the preview before it can reach a lock screen" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      body: "the answer is 42",
      metadata: %{
        "entities" => [%{"type" => "spoiler", "offset" => 14, "length" => 2}]
      }
    )

    assert {:ok, context} =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })

    assert context.preview == "the answer is ▒▒"
    refute context.preview =~ "42"
  end

  @tag :postgres_integration
  test "spoiler offsets are UTF-16: an emoji before the span shifts it by two, and the mask lands right" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      body: "😀secret",
      metadata: %{"entities" => [%{"type" => "spoiler", "offset" => 2, "length" => 6}]}
    )

    assert {:ok, context} =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })

    assert context.preview == "😀▒▒▒▒▒▒"
    refute context.preview =~ "secret"
  end

  @tag :postgres_integration
  test "a NON-spoiler entity masks nothing, and a media label is never masked by offsets that do not index it" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      body: "the answer is 42",
      metadata: %{"entities" => [%{"type" => "bold", "offset" => 14, "length" => 2}]}
    )

    assert {:ok, plain} =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })

    assert plain.preview == "the answer is 42"

    {conv2, msg2, sender2} = ids()

    MessageStoreFixture.insert_message!(conv2, msg2, sender2,
      message_type: "media",
      body: nil,
      metadata: %{
        "content_type" => "image/jpeg",
        "entities" => [%{"type" => "spoiler", "offset" => 0, "length" => 5}]
      }
    )

    assert {:ok, media} =
             PushContext.message_context(%{
               conversation_id: conv2,
               message_id: msg2,
               sender_user_id: sender2
             })

    # The label is not the body, so its characters are never replaced.
    assert media.preview == "📷 Photo"
  end

  @tag :postgres_integration
  test "MUT-4 guard: ENTITIES never reach the push payload — the data key-set is exactly what it was" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      body: "hello world",
      metadata: %{
        "font" => "handwritten",
        "entities" => [
          %{"type" => "bold", "offset" => 0, "length" => 5},
          %{"type" => "link", "offset" => 6, "length" => 5, "url" => "https://example.com"}
        ]
      }
    )

    attrs = %{conversation_id: conversation, message_id: message, sender_user_id: sender}
    assert {:ok, context} = PushContext.message_context(attrs)
    assert Map.keys(context) |> Enum.sort() == [:group_name, :preview, :sender]

    data = NotificationService.FcmSender.message_data(context, attrs, 1)

    assert Map.keys(data) |> Enum.sort() ==
             [
               "conversation_id",
               "message_id",
               "preview",
               "sender_id",
               "sender_name",
               "type",
               "unread_count"
             ]

    encoded = Jason.encode!(data)
    refute encoded =~ "entities"
    refute encoded =~ "handwritten"
    refute encoded =~ "example.com"
  end

  @tag :postgres_integration
  test "MUT-4 guard: a message's metadata.preview (inline thumb) NEVER reaches the push payload" do
    {conversation, message, sender} = ids()
    thumb = Base.encode64(:crypto.strong_rand_bytes(600))

    MessageStoreFixture.insert_message!(conversation, message, sender,
      message_type: "media",
      body: nil,
      metadata: %{
        "content_type" => "image/jpeg",
        "media_id" => Ecto.UUID.generate(),
        "preview" => %{"inline_b64" => thumb, "w" => 48, "h" => 32}
      }
    )

    attrs = %{conversation_id: conversation, message_id: message, sender_user_id: sender}
    assert {:ok, context} = PushContext.message_context(attrs)
    # The context carries the TEXT preview only — never the thumb map.
    assert Map.keys(context) |> Enum.sort() == [:group_name, :preview, :sender]
    assert context.preview == "📷 Photo"

    data = NotificationService.FcmSender.message_data(context, attrs, 1)

    assert Map.keys(data) |> Enum.sort() ==
             [
               "conversation_id",
               "message_id",
               "preview",
               "sender_id",
               "sender_name",
               "type",
               "unread_count"
             ]

    refute Jason.encode!(data) =~ thumb
    refute Jason.encode!(context) =~ thumb
  end

  @tag :postgres_integration
  test "an ABSENT message suppresses the push and does NOT log at :error" do
    {conversation, _message, _sender} = ids()
    missing = Ecto.UUID.generate()

    # Capture at :error ONLY. An absent message is a normal outcome; if it logged at :error an
    # operator could not tell a deleted message from a broken message-service, which is the entire
    # reason these two paths log differently.
    errors =
      capture_log([level: :error], fn ->
        assert :no_preview = PushContext.message_preview_fields(conversation, missing)
      end)

    refute errors =~ "push preview"

    # It IS logged, just not as a failure.
    info = capture_log(fn -> PushContext.message_preview_fields(conversation, missing) end)
    assert info =~ "message ABSENT"
  end

  @tag :postgres_integration
  test "a DELETED message suppresses the push — the store read does NOT filter deleted_at for us" do
    {conversation, message, sender} = ids()

    MessageStoreFixture.insert_message!(conversation, message, sender,
      body: "deleted secret",
      deleted_at: DateTime.utc_now()
    )

    # PostgresAdapter.get_message is `Repo.get/2` by id — it happily returns a soft-deleted row, so
    # the deleted_at check in message_preview_fields/2 is load-bearing, not decorative.
    assert :no_preview = PushContext.message_preview_fields(conversation, message)

    assert :no_preview =
             PushContext.message_context(%{
               conversation_id: conversation,
               message_id: message,
               sender_user_id: sender
             })
  end
end
