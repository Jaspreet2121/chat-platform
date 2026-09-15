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

  @doc """
  THE SINGLE-MESSAGE FRAME — the socket's `conversation_reply/3` + `receipt_type`, byte for byte:
  `{event, conversation_id, user_id, payload: %{"message_id"}, status: "accepted", receipt_type}`.
  The message_id stays NESTED under `payload` (the SDK reads payload.payload.message_id); flattening
  it would fork the wire protocol between the socket and REST.
  """
  def single_frame(event, conversation_id, user_id, message_id, receipt_type) do
    %{
      event: event,
      conversation_id: conversation_id,
      user_id: user_id,
      payload: %{"message_id" => message_id},
      status: "accepted",
      receipt_type: receipt_type
    }
  end

  @doc """
  THE ONE EMITTER of `receipt_updated`, on the conversation topic, for every surface that records a
  receipt: the socket single events, the socket batches, and the REST read/delivered endpoints.
  SYNCHRONOUS on purpose — the contract is "never before the receipt row is committed", and a
  spawned task cannot promise that. `from: pid` excludes that channel process (the socket's
  `broadcast_from`); without it every subscriber gets the frame (REST has no socket to exclude).
  Never raises into the caller: a PubSub failure must not fail a receipt that is already stored.
  """
  def emit(endpoint, conversation_id, %{} = frame, opts \\ []) do
    topic = "conversation:" <> conversation_id

    case Keyword.get(opts, :from) do
      pid when is_pid(pid) -> endpoint.broadcast_from(pid, topic, "receipt_updated", frame)
      _ -> endpoint.broadcast(topic, "receipt_updated", frame)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  THE READ-RECEIPT GATE, shared by the socket (resolved once at join) and REST (resolved per
  request): a read tick is emitted only if the reader has read receipts on AND, in a DIRECT
  conversation, so does the peer (reciprocity). Groups need only the reader's own setting.
  Delivered ticks are never gated — they are about arrival, not content. Fail-open on any read
  glitch (a privacy lookup outage must not silently hide ticks forever).
  """
  def emit_read_receipts?(conversation_id, user_id)
      when is_binary(conversation_id) and conversation_id != "" and is_binary(user_id) and
             user_id != "" do
    if read_receipts_enabled?(user_id) do
      case dm_peer(conversation_id, user_id) do
        peer when is_binary(peer) -> read_receipts_enabled?(peer)
        _ -> true
      end
    else
      false
    end
  rescue
    _ -> true
  end

  def emit_read_receipts?(_conversation_id, _user_id), do: false

  # The OTHER active participant of a DIRECT conversation (nil for a group / unknown), via the same
  # get_conversation the peer-contact path uses.
  defp dm_peer(conversation_id, me) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => me
         }) do
      {:ok, conversation} ->
        if (Map.get(conversation, :type) || Map.get(conversation, "type")) == "direct" do
          (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
          |> Enum.map(&(Map.get(&1, :user_id) || Map.get(&1, "user_id")))
          |> Enum.find(&(is_binary(&1) and &1 != me))
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # A user's read_receipts_enabled (default TRUE for no row / persistence off / a read glitch — fail-open).
  defp read_receipts_enabled?(user_id) when is_binary(user_id) and user_id != "" do
    case SharedInfra.UserClient.get_privacy(%{"user_id" => user_id}) do
      {:ok, privacy} ->
        # Map.get with a default (NOT `||`) so `false` reads as false, not "absent". Enabled unless explicit false.
        SharedInfra.Attrs.get(privacy, :read_receipts_enabled) != false

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp read_receipts_enabled?(_user_id), do: true
end
