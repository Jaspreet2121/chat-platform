defmodule SharedInfra.InboxPreviewChecklistTest do
  @moduledoc """
  FOUND ON DEVICE: a checklist's conversation-list row had NO subtitle. `preview_text/2` matched
  only "text", nil and "call", so a checklist fell to the catch-all and answered nil — and the
  client had to fill the title in from its own copy of the message. Polls had the identical gap
  since they shipped: a poll's body is its question, and the row showed nothing.

  Both bodies are plain text the author typed, which is exactly what a row subtitle is for. The
  sealed gate is unaffected and is re-asserted here, because these clauses sit directly above the
  catch-all that enforces it.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.InboxPreview

  test "a CHECKLIST's title is its preview" do
    assert InboxPreview.preview_text("Weekend shop", "checklist") == "Weekend shop"
    assert InboxPreview.message_kind("checklist", nil) == "checklist"
  end

  test "a POLL's question is its preview — the same gap, fixed with it" do
    assert InboxPreview.preview_text("Pizza or curry?", "poll") == "Pizza or curry?"
    assert InboxPreview.message_kind("poll", nil) == "poll"
  end

  test "the existing kinds are unchanged" do
    assert InboxPreview.preview_text("hello", "text") == "hello"
    assert InboxPreview.preview_text("hello", nil) == "hello"
    assert InboxPreview.preview_text("Missed voice call", "call") == "Missed voice call"
    assert InboxPreview.preview_text(nil, "media") == nil
    assert InboxPreview.preview_text("caption", "media") == nil
  end

  test "SEALED still never passes through, whatever its body says" do
    assert InboxPreview.preview_text("this should never appear", "sealed") == nil
    assert InboxPreview.message_kind("sealed", nil) == "sealed"
  end

  test "an empty or non-binary body yields nil for the new kinds too" do
    assert InboxPreview.preview_text("", "checklist") == nil
    assert InboxPreview.preview_text(nil, "checklist") == nil
    assert InboxPreview.preview_text("", "poll") == nil
    assert InboxPreview.preview_text(nil, "poll") == nil
  end
end
