defmodule NotificationService.PushContextTest do
  @moduledoc """
  `preview/3` is the one function BOTH transports call, so it is what guarantees a browser
  notification and an Android notification describe the same message the same way. It was extracted
  verbatim from `PushSender` when the FCM leg arrived; these cases pin the behaviour that extraction
  had to preserve.

  Pure — no database, no network.
  """
  use ExUnit.Case, async: true

  alias NotificationService.PushContext

  test "a text message previews as its body" do
    assert PushContext.preview("hello", "text", nil) == "hello"
  end

  test "media previews by content type, not by body" do
    assert PushContext.preview(nil, "media", "image/jpeg") == "📷 Photo"
    assert PushContext.preview(nil, "media", "audio/webm") == "🎤 Voice message"
    assert PushContext.preview(nil, "media", "video/mp4") == "🎬 Video"
    assert PushContext.preview(nil, "media", "application/pdf") == "📎 Attachment"
    # An unknown/absent content type is still an attachment, never a crash.
    assert PushContext.preview(nil, "media", nil) == "📎 Attachment"
  end

  test "location kinds have their own labels" do
    assert PushContext.preview(nil, "location", nil) == "📍 Location"
    assert PushContext.preview(nil, "live_location", nil) == "📍 Live location"
  end

  test "an empty or missing body falls back rather than pushing a blank notification" do
    assert PushContext.preview("", "text", nil) == "New message"
    assert PushContext.preview(nil, "text", nil) == "New message"
    assert PushContext.preview(nil, nil, nil) == "New message"
  end

  test "an unknown message type still shows its body when there is one" do
    assert PushContext.preview("something", "some_future_type", nil) == "something"
  end

  test "dump_uuid converts a uuid and passes anything else through" do
    uuid = "75555555-5555-4555-8555-555555555555"
    assert PushContext.dump_uuid(uuid) == elem(Ecto.UUID.dump(uuid), 1)
    assert PushContext.dump_uuid("not-a-uuid") == "not-a-uuid"
  end
end
