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

  alias NotificationService.FcmSender
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
        dispatch(event)

      # The terminal chase (2026-08-17): the gateway produces call.cancelled on caller-cancel and on the
      # server ring-timeout so a BACKGROUNDED callee's handset stops ringing (the socket broadcast can't
      # reach a dead socket; observed on MIUI ringing a dead call for a minute). FCM data-only.
      {:ok, %{"type" => "call.cancelled"} = event} ->
        dispatch_cancel(event)

      {:ok, inner} when is_binary(inner) ->
        # A JSON *string* on this topic means a DOUBLE-ENCODED event — the exact shape the gateway shipped
        # before its producer passed the map (that bug hid here for weeks because this clause used to
        # ignore silently). ONE defensive re-decode so any in-flight legacy events still push — and any
        # producer regressing the same way shows up in the logs instead of a black hole.
        case Jason.decode(inner) do
          {:ok, %{"type" => "call.incoming"} = event} ->
            Logger.warning(
              "notification: DOUBLE-ENCODED call event (legacy/regressed producer) — dispatched after re-decode"
            )

            dispatch(event)

          _ ->
            log_unrecognised(inner)
        end

      {:ok, other} ->
        log_unrecognised(other)

      {:error, reason} ->
        Logger.warning(
          "notification: call event JSON decode failed, skipping: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning("notification: call event handling raised, ignored: #{inspect(error)}")
  end

  defp dispatch(event) do
    SharedInfra.Correlation.put(event["correlation_id"])
    PushSender.push_incoming_call(event)
    # Android leg, side by side — same suppression, its own token set.
    FcmSender.push_incoming_call(event)
  end

  # Android-only for now: vc8 parses {"type":"call_cancelled"} and stops idempotently. A web-push
  # cancel leg (PushSender) is a noted follow-up — the web client's ring dies with its socket anyway.
  defp dispatch_cancel(event) do
    SharedInfra.Correlation.put(event["correlation_id"])
    FcmSender.push_call_cancelled(event)
  end

  # An unrecognised event on this topic must NEVER be invisible again (still committed by the caller —
  # best-effort semantics unchanged). Truncated: enough to identify the producer, never a payload dump.
  defp log_unrecognised(value) do
    Logger.warning(
      "notification: unrecognised event on call.events.v1 ignored: " <>
        inspect(value, limit: 5, printable_limit: 120)
    )
  end
end
