defmodule SharedInfra.InboxPreviewTest do
  @moduledoc """
  The inbox subtitle rules in their new home. These clauses were private to
  `ConversationService.Conversations` and had no direct test of their own — they were exercised only
  through the SQL-backed row mapper (ConversationService.InboxRowsTest, postgres-gated). Now that a second
  release composes frames with them, the rules are pinned HERE, Docker-free, so a change is caught at the
  definition rather than in one of the two callers.

  Behaviour is byte-for-byte what conversations.ex had; ConversationService.Conversations delegates, so
  those suites prove the delegation and these prove the rules.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.InboxPreview

  describe "preview_text/2" do
    test "a text body is surfaced verbatim" do
      assert InboxPreview.preview_text("hello", "text") == "hello"
    end

    test "a nil message_type is treated as text (legacy rows predate the column)" do
      assert InboxPreview.preview_text("hello", nil) == "hello"
    end

    test "a call's short human body is surfaced, so the list matches the in-thread entry" do
      assert InboxPreview.preview_text("Missed voice call", "call") == "Missed voice call"
    end

    test "media yields NO text — the client renders a kind label instead" do
      assert InboxPreview.preview_text("photo.png", "media") == nil
    end

    test "an empty or non-binary body yields nil for every type that would otherwise pass" do
      for type <- ["text", nil, "call"] do
        assert InboxPreview.preview_text("", type) == nil
        assert InboxPreview.preview_text(nil, type) == nil
        assert InboxPreview.preview_text(123, type) == nil
      end
    end

    # --- 108: THE SEALED CONTENT GATE ---

    test "SEALED yields nil no matter what the body is — the gate is the clause order, not a filter" do
      for body <- ["🔒 Message", "the actual plaintext", "", nil] do
        assert InboxPreview.preview_text(body, "sealed") == nil
      end
    end

    test "no unknown message_type can leak a body either" do
      for type <- ["sealed", "system", "media", "poll", "anything_new"] do
        assert InboxPreview.preview_text("secret content", type) == nil
      end
    end
  end

  describe "message_kind/2" do
    test "nil type stays nil" do
      assert InboxPreview.message_kind(nil, "image/png") == nil
    end

    test "text is text, whatever the content type says" do
      assert InboxPreview.message_kind("text", "image/png") == "text"
    end

    test "media resolves its sub-kind from the content type prefix" do
      assert InboxPreview.message_kind("media", "image/png") == "image"
      assert InboxPreview.message_kind("media", "video/mp4") == "video"
      assert InboxPreview.message_kind("media", "audio/ogg") == "audio"
    end

    test "an unrecognised, missing or non-binary media content type falls back to file" do
      assert InboxPreview.message_kind("media", "application/pdf") == "file"
      assert InboxPreview.message_kind("media", nil) == "file"
      assert InboxPreview.message_kind("media", 42) == "file"
    end

    test "any other type is passed through verbatim — this is what carries 'sealed' to the client" do
      assert InboxPreview.message_kind("sealed", nil) == "sealed"
      assert InboxPreview.message_kind("call", nil) == "call"
      assert InboxPreview.message_kind("system", nil) == "system"
    end
  end

  describe "content_type/1" do
    test "reads metadata.content_type in either key style" do
      assert InboxPreview.content_type(%{metadata: %{"content_type" => "image/png"}}) ==
               "image/png"

      assert InboxPreview.content_type(%{"metadata" => %{"content_type" => "video/mp4"}}) ==
               "video/mp4"

      assert InboxPreview.content_type(%{metadata: %{content_type: "audio/ogg"}}) == "audio/ogg"
    end

    test "absent, empty or non-map metadata yields nil rather than raising" do
      assert InboxPreview.content_type(%{metadata: %{}}) == nil
      assert InboxPreview.content_type(%{}) == nil
      assert InboxPreview.content_type(%{metadata: nil}) == nil
      assert InboxPreview.content_type(%{metadata: "not a map"}) == nil
      assert InboxPreview.content_type(nil) == nil
    end
  end
end
