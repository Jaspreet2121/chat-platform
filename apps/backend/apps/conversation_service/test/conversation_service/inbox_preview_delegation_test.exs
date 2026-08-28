defmodule ConversationService.InboxPreviewDelegationTest do
  @moduledoc """
  The row mapper's preview rules DELEGATE to SharedInfra.InboxPreview — they are not a second copy.

  This matters because the `conversation_updated` broadcast now composes the preview/kind from the
  triggering message using that shared module, while the inbox LIST still maps them from the denormalised
  columns here. If the two implementations ever diverge, a conversation shows one preview live and a
  different one after a refetch — the drift @inbox_sql's header warns about, now across a release boundary.

  Docker-free: these are pure functions, and this suite asserts only that both names resolve to the one
  definition. The SQL-backed row mapping stays proven by ConversationService.InboxRowsTest.
  """
  use ExUnit.Case, async: true

  alias ConversationService.Conversations
  alias SharedInfra.InboxPreview

  @cases [
    {"hello", "text", "image/png"},
    {"hello", nil, nil},
    {"Missed voice call", "call", nil},
    {"photo.png", "media", "image/png"},
    {"clip.mp4", "media", "video/mp4"},
    {"note.ogg", "media", "audio/ogg"},
    {"doc.pdf", "media", "application/pdf"},
    {"🔒 Message", "sealed", nil},
    {"secret content", "sealed", "image/png"},
    {nil, "system", nil}
  ]

  test "preview_text/2 answers identically to the shared definition" do
    for {body, type, _ct} <- @cases do
      assert Conversations.preview_text(body, type) == InboxPreview.preview_text(body, type),
             "preview_text drifted for body=#{inspect(body)} type=#{inspect(type)}"
    end
  end

  test "message_kind/2 answers identically to the shared definition" do
    for {_body, type, ct} <- @cases do
      assert Conversations.message_kind(type, ct) == InboxPreview.message_kind(type, ct),
             "message_kind drifted for type=#{inspect(type)} content_type=#{inspect(ct)}"
    end
  end

  test "108: a sealed message yields NO preview text through the mapper either" do
    for body <- ["🔒 Message", "the actual plaintext", nil] do
      assert Conversations.preview_text(body, "sealed") == nil
    end

    # …and the kind is what the client keys its own locally-decrypted preview off.
    assert Conversations.message_kind("sealed", nil) == "sealed"
  end
end
