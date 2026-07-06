defmodule RealtimeGateway.CallSignaling do
  @moduledoc """
  Phase-1 call RING signaling over the `user:<id>` channel — the "WhatsApp ring" control plane. LiveKit
  handles the media; here we only invite/accept/reject/cancel/hangup and fan the events to the other
  party's `user:<id>` topic (mirroring the conversation channel's `notify_user_topics`).

  Flow: caller pushes `call:invite` on their OWN `user:<id>` → we persist a ringing call (CallStore) and
  broadcast `call:incoming` to the callee → callee `call:accept`/`call:reject` → we transition + broadcast
  back. Cancel (caller, pre-answer) / hangup (either) / a server-side ring timeout all transition + notify.

  AUTH: invite is implicitly self (the channel is identity-pinned to current_user_id). accept/reject are
  callee-only, cancel is caller-only, hangup is either party — validated against the persisted call row.

  A best-effort incoming-call web-push is emitted for a backgrounded callee (see `emit_incoming_push/4`).
  """

  alias SharedInfra.ConversationClient

  @ring_timeout_ms 35_000
  @call_events_topic "call.events.v1"

  @doc "Dispatch a `call:*` event from the user channel. Returns a `{:reply, reply, socket}` tuple."
  def handle_event("call:invite", payload, socket), do: invite(payload, socket)
  def handle_event("call:accept", payload, socket), do: accept(payload, socket)
  def handle_event("call:reject", payload, socket), do: reject(payload, socket)
  def handle_event("call:cancel", payload, socket), do: cancel(payload, socket)
  def handle_event("call:hangup", payload, socket), do: hangup(payload, socket)
  def handle_event(_event, _payload, socket), do: reply_error(socket, "call.invalid_event")

  # --- invite: caller → create ringing call → ring the callee ------------------------------------
  def invite(%{"callee_id" => callee_id, "type" => type} = payload, socket)
      when is_binary(callee_id) and callee_id != "" and type in ["voice", "video"] do
    caller_id = current_user(socket)

    cond do
      callee_id == caller_id ->
        reply_error(socket, "call.invalid_callee")

      true ->
        case ConversationClient.create_call(%{
               "caller_id" => caller_id,
               "callee_id" => callee_id,
               "type" => type,
               "conversation_id" => payload["conversation_id"]
             }) do
          {:ok, call} ->
            call_id = cget(call, :id)
            room = cget(call, :room_name)
            caller_name = resolve_name(caller_id)

            broadcast(socket, callee_id, "call:incoming", %{
              call_id: call_id,
              room: room,
              caller_id: caller_id,
              caller_name: caller_name,
              type: type,
              conversation_id: cget(call, :conversation_id)
            })

            emit_incoming_push(callee_id, caller_name, type, call_id)

            # Server-side ring timeout (this = the caller's channel process). On fire we re-check status,
            # so accept/reject/cancel/hangup transitioning first makes it a no-op — no cross-process cancel.
            Process.send_after(self(), {:call_ring_timeout, call_id}, @ring_timeout_ms)

            {:reply, {:ok, %{call_id: call_id, room: room}}, socket}

          {:error, _reason} ->
            reply_error(socket, "call.unavailable")
        end
    end
  end

  def invite(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- accept / reject (callee only) -------------------------------------------------------------
  defp accept(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:callee], fn call, _role ->
      case ConversationClient.mark_call_answered(%{"call_id" => call_id}) do
        {:ok, _} ->
          broadcast(socket, cget(call, :caller_id), "call:accepted", %{
            call_id: call_id,
            room: cget(call, :room_name)
          })

          {:reply, {:ok, %{call_id: call_id, room: cget(call, :room_name)}}, socket}

        {:error, _} ->
          reply_error(socket, "call.unavailable")
      end
    end)
  end

  defp accept(_payload, socket), do: reply_error(socket, "call.invalid_request")

  defp reject(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:callee], fn call, _role ->
      _ = ConversationClient.mark_call_declined(%{"call_id" => call_id})
      broadcast(socket, cget(call, :caller_id), "call:rejected", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp reject(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- cancel (caller only, pre-answer) ----------------------------------------------------------
  defp cancel(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:caller], fn call, _role ->
      _ = ConversationClient.mark_call_missed(%{"call_id" => call_id})
      broadcast(socket, cget(call, :callee_id), "call:cancelled", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp cancel(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- hangup (either party) → notify the OTHER party --------------------------------------------
  defp hangup(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:caller, :callee], fn call, role ->
      _ = ConversationClient.mark_call_ended(%{"call_id" => call_id})
      other = if role == :caller, do: cget(call, :callee_id), else: cget(call, :caller_id)
      broadcast(socket, other, "call:ended", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp hangup(_payload, socket), do: reply_error(socket, "call.invalid_request")

  @doc """
  Ring timeout (fired from the caller's channel via `handle_info`). Only marks missed if the call is STILL
  ringing (accept/reject/cancel/hangup already moved it → no-op), then broadcasts `call:missed` to both.
  """
  def ring_timeout(call_id, socket) when is_binary(call_id) do
    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        if cget(call, :status) == "ringing" do
          _ = ConversationClient.mark_call_missed(%{"call_id" => call_id})
          broadcast(socket, cget(call, :caller_id), "call:missed", %{call_id: call_id})
          broadcast(socket, cget(call, :callee_id), "call:missed", %{call_id: call_id})
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # --- helpers -----------------------------------------------------------------------------------

  # Fetch the call, resolve the caller's role, run `fun` only if the role is allowed.
  defp with_call(call_id, socket, allowed_roles, fun) when is_binary(call_id) and call_id != "" do
    me = current_user(socket)

    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        role =
          cond do
            me == cget(call, :caller_id) -> :caller
            me == cget(call, :callee_id) -> :callee
            true -> :none
          end

        if role in allowed_roles do
          fun.(call, role)
        else
          reply_error(socket, "call.forbidden")
        end

      _ ->
        reply_error(socket, "call.not_found")
    end
  end

  defp with_call(_call_id, socket, _roles, _fun), do: reply_error(socket, "call.invalid_request")

  defp broadcast(socket, user_id, event, payload) when is_binary(user_id) and user_id != "" do
    socket.endpoint.broadcast("user:" <> user_id, event, payload)
    :ok
  end

  defp broadcast(_socket, _user_id, _event, _payload), do: :ok

  # Caller display name for the ring/push — best-effort (falls back to a short id).
  defp resolve_name(user_id) do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id}) do
      {:ok, profile} ->
        name = Map.get(profile, :display_name) || Map.get(profile, "display_name")
        if is_binary(name) and name != "", do: name, else: short(user_id)

      _ ->
        short(user_id)
    end
  rescue
    _ -> short(user_id)
  end

  defp short(user_id) when is_binary(user_id), do: "#" <> String.slice(user_id, 0, 8)
  defp short(_), do: "Someone"

  # Best-effort incoming-call push for a backgrounded callee. Reuses the message-push path: fire-and-forget
  # produce onto the Kafka bus (gated by CALL_PUSH_ENABLED); notification_service's CallIncomingConsumer
  # turns it into a web-push via PushSender. A no-op when the flag/Kafka path is off (same ceiling as
  # message pushes) — the reliable ring is the socket broadcast above; this is only the backgrounded case.
  defp emit_incoming_push(callee_id, caller_name, type, call_id) do
    if call_push_enabled?() do
      correlation = SharedInfra.Correlation.get_or_generate()

      Task.start(fn ->
        SharedInfra.Correlation.put(correlation)

        value =
          Jason.encode!(%{
            "type" => "call.incoming",
            "call_id" => call_id,
            "callee_id" => callee_id,
            "caller_name" => caller_name,
            "call_type" => type,
            "correlation_id" => correlation
          })

        SharedInfra.Kafka.Producer.produce(@call_events_topic, callee_id, value)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp call_push_enabled? do
    Application.get_env(:realtime_gateway, :call_push_enabled, false) ||
      System.get_env("CALL_PUSH_ENABLED") in ["true", "1", "yes"]
  end

  defp current_user(socket), do: socket.assigns.current_user_id

  # Call maps come atom-keyed (in-process CallStore) or string-keyed (HTTP adapter) — read either.
  defp cget(call, key), do: Map.get(call, key) || Map.get(call, to_string(key))

  defp reply_error(socket, code), do: {:reply, {:error, %{code: code}}, socket}
end
