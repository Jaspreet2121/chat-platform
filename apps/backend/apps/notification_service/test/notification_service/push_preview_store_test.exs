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
