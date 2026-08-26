defmodule NotificationService.PushPreviewSecretTest do
  @moduledoc """
  SECRET CHATS (108): the push preview for a sealed message is GENERIC — even if a body somehow
  reached the preview builder, "sealed" renders as "New message" with zero content. Shared by the
  web-push and FCM legs (one PushContext.preview).
  """
  use ExUnit.Case, async: true

  alias NotificationService.PushContext

  test "sealed previews are generic regardless of any body present" do
    assert PushContext.preview(nil, "sealed", nil) == "New message"
    assert PushContext.preview("should never show", "sealed", nil) == "New message"
    assert PushContext.preview("should never show", "sealed", "image/jpeg") == "New message"
  end
end
