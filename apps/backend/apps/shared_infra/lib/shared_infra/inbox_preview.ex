defmodule SharedInfra.InboxPreview do
  @moduledoc """
  THE inbox row's subtitle rules: what text a conversation-list row shows, and what kind label goes with it.

  Moved here from `ConversationService.Conversations` (where they were private) because TWO callers in
  DIFFERENT releases need them and a second copy would drift — the exact hazard `@inbox_sql`'s header
  warns about, and the reason the previous slice left the broadcast's preview stale rather than duplicating
  these clauses:

    * `ConversationService.Conversations.query_inbox_rows/3` — mapping the DENORMALISED
      `conversations.last_message_*` columns for the inbox list and for the per-user broadcast rows;
    * `SharedInfra.ConversationBroadcast` — composing the `conversation_updated` frame from the message
      that TRIGGERED it, because under the Scylla store those columns are written later by the Kafka
      projection and still hold the previous message when the frame goes out.

  Both must answer identically for the same (body, type, content_type), or the same conversation shows one
  preview live and a different one after a refetch. There is exactly one implementation, here;
  conversation_service delegates.

  SEALED CONTENT NEVER PASSES THROUGH (108). `preview_text/2` matches only "text", nil and "call" — a
  "sealed" message_type falls to the catch-all and yields nil NO MATTER WHAT THE BODY IS, so neither a
  stored marker nor a body that somehow got attached to a sealed row can reach a client. That is a
  structural property of the clause order, not a filter someone has to remember to apply: the only way to
  leak sealed content from here is to make the catch-all return `body`, which is what the gate tests
  mutate. Clients render their own locally-decrypted preview off `last_message_kind: "sealed"`.
  """

  @doc """
  The row subtitle text: a text message's body; nil for media (the client renders a kind label). A
  "call" (missed-call) message carries a short human body ("Missed voice call") — surface it verbatim so
  the list preview matches the in-thread entry (client has no separate call-kind label).

  Everything else — sealed above all — yields nil.
  """
  def preview_text(body, "text") when is_binary(body) and body != "", do: body
  def preview_text(body, nil) when is_binary(body) and body != "", do: body
  def preview_text(body, "call") when is_binary(body) and body != "", do: body
  def preview_text(_body, _type), do: nil

  @doc """
  The kind label beside the preview: "text", the media sub-kind resolved from the content type, or the
  message_type verbatim (which is what carries "sealed" to the client).
  """
  def message_kind(nil, _content_type), do: nil
  def message_kind("text", _content_type), do: "text"

  def message_kind("media", content_type) do
    ct = to_string(content_type)

    cond do
      String.starts_with?(ct, "image/") -> "image"
      String.starts_with?(ct, "video/") -> "video"
      String.starts_with?(ct, "audio/") -> "audio"
      true -> "file"
    end
  end

  def message_kind(other, _content_type), do: other

  @doc """
  The content type a message's preview kind is resolved from — `metadata.content_type`, the same place
  `MessageService.InboxProjection.content_type/1` reads it when it writes the denormalised column. Kept
  beside the rules it feeds so the broadcast and the projection cannot disagree about where it lives.
  """
  def content_type(%{} = message) do
    case metadata(message) do
      %{} = metadata -> metadata["content_type"] || metadata[:content_type]
      _ -> nil
    end
  end

  def content_type(_message), do: nil

  defp metadata(message), do: Map.get(message, :metadata) || Map.get(message, "metadata")
end
