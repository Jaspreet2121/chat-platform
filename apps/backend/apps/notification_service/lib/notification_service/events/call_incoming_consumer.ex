defmodule NotificationService.Events.CallIncomingConsumer do
  @moduledoc """
  Best-effort `brod_group_subscriber_v2` consumer for `call.events.v1` (Phase-1 calling).

  Turns a `call.incoming` event (produced fire-and-forget by the realtime gateway when a caller rings a
  callee) into an incoming-call web-push via `NotificationService.PushSender.push_incoming_call/1` — for a
  BACKGROUNDED callee only (a foreground callee already got the in-app ring over their socket; the push
  sender suppresses those).

  This is a NOTIFICATION side channel, not a system of record: the ring itself is the socket broadcast. So
  we ALWAYS commit (push is fire-and-forget; there is nothing to retry — a redelivered "you have a call"
  seconds later is worse than a dropped one). A poison/undecodable event is logged and committed too, so it
  can never wedge the partition. Runs only under `NOTIFICATION_CALL_CONSUMER_ENABLED` (default off).
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias NotificationService.PushSender

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(_init_info, init_data), do: {:ok, init_data}

  @impl true
  def handle_message(message, state) do
    message |> kafka_message(:value) |> handle_value()
    # Always commit — best-effort push, nothing to retry (see moduledoc).
    {:ok, :commit, state}
  end

  defp handle_value(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => "call.incoming"} = event} ->
        SharedInfra.Correlation.put(event["correlation_id"])
        PushSender.push_incoming_call(event)

      {:ok, _other} ->
        # Unknown event type on the shared call topic — ignore (still committed by the caller).
        :ok

      {:error, reason} ->
        Logger.warning("notification: call event JSON decode failed, skipping: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("notification: call event handling raised, ignored: #{inspect(error)}")
  end
end
