defmodule RealtimeGateway.Receipts do
  @moduledoc """
  Batched receipts — ONE push, ONE limiter charge, N receipts (2026-09-12).

  Shared by the two surfaces that accept a batch: `ConversationChannel` (`messages_read` /
  `messages_delivered` on an OPEN thread) and `UserChannel` (`messages_delivered` for a thread the
  user does NOT have open — the message arrived on their user topic). Both go through the same
  validation, the same per-row persist and the same wire frame, so a consumer sees one contract.

  The single-message events (`message_read` / `message_delivered`) and the REST endpoints are
  UNCHANGED: Android and the SDK use them. This is purely additive.
  """

  # 100 ids per push. Bounds three things at once: the frame stays ~4 KB (two orders of magnitude
  # under the 64 KB default max frame), one channel process does at most 100 sequential store writes
  # before yielding, and the worst realistic backfill — a 300-message thread — becomes 3 pushes
  # against a 300/min ephemeral budget instead of 300. The client chunks at the same number.
  @max_batch 100

  def max_batch, do: @max_batch

  @doc """
  THE SERVER-SIDE CAP. The client chunks at the same number, so a well-behaved client never sees
  this; it exists because a cap only a client enforces is not a cap. Refuses rather than truncating:
  silently dropping receipts would show the sender a tick state that never arrives.
  """
  def batch(%{"message_ids" => ids}) when is_list(ids) do
    ids =
      ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    cond do
      ids == [] -> {:error, "receipt.invalid_request"}
      length(ids) > @max_batch -> {:error, "receipt.batch_too_large"}
      true -> {:ok, ids}
    end
  end

  def batch(_payload), do: {:error, "receipt.invalid_request"}

  @doc """
  Persist one receipt per id through the SAME per-row store call the single-message event uses —
  the write path, its idempotency and its inbox bookkeeping are already correct per message.
  """
  def persist(status, conversation_id, message_ids, user_id) do
    Enum.each(message_ids, fn message_id ->
      attrs = %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => user_id
      }

      case status do
        :read -> SharedInfra.MessageClient.mark_read(attrs)
        :delivered -> SharedInfra.MessageClient.mark_delivered(attrs)
      end
    end)

    :ok
  end

  @doc """
  THE WIRE CONTRACT for a batched receipt — ONE `receipt_updated` frame covering N messages.

  The OUTER key-set is byte-identical to the single-message frame, so nothing that already consumes
  `receipt_updated` breaks at the envelope. Inside `payload`:

    * `message_ids` — the whole batch. New consumers MUST read this and apply the receipt to ALL of
      them; this is the field Android will consume.
    * `message_id`  — the FIRST id, repeated. A consumer written against the single-message frame
      therefore still advances one tick instead of ignoring the frame entirely. Degraded, never
      silent — and the durable counts on the next timeline fetch correct the rest.
  """
  def frame(event, conversation_id, user_id, message_ids, receipt_type) do
    %{
      event: event,
      conversation_id: conversation_id,
      user_id: user_id,
      payload: %{"message_ids" => message_ids, "message_id" => hd(message_ids)},
      status: "accepted",
      receipt_type: receipt_type
    }
  end
end
