defmodule RealtimeGateway.UserPresence do
  @moduledoc """
  Channel-side presence coordinator: turns the user socket's lifecycle (join / heartbeat / terminate) into
  authorized `presence_updated` broadcasts, and manages a socket's presence SUBSCRIPTIONS.

  MODEL — subscribe-based, authorize-at-subscribe:
    * A viewer S declares whose presence it wants (`presence:subscribe`). Each target U is authorized ONCE
      here (`SharedInfra.PresenceAuthz.can_see?/2` — a shared conversation AND U's visibility permits). If
      allowed, S's channel process subscribes to the `presence:<U>` PubSub topic and gets an immediate
      snapshot. Unauthorized targets are dropped SILENTLY (no reveal that U even exists).
    * A transition for U (online / offline) broadcasts ONCE to `presence:<U>`; every subscribed viewer gets
      it. No per-transition contact query — that cost was paid at subscribe.
    * The broadcast is additionally gated on U's visibility != "nobody" AT BROADCAST TIME, so a viewer who
      subscribed while U was visible stops receiving the instant U flips to "nobody".

  Cross-node: the `presence:<U>` topics live on the socket endpoint's clustered PubSub (the same one
  message/conversation fan-out uses), so a viewer on any node receives U's transition from any other node.

  Redis I/O runs OFF the channel process (Task.start) so presence never blocks realtime; the online store
  (`SharedInfra.Presence`) is fail-CLOSED on read (never a phantom "online").

  """

  require Logger

  # Cap the targets a single subscribe frame may request — bounds the per-frame resolve/authz work.
  @max_targets 200

  import Phoenix.Socket, only: [assign: 3]

  alias SharedInfra.Presence, as: Store
  alias SharedInfra.PresenceAuthz

  @doc "Mark this socket's user online; on a genuine offline→online transition, broadcast online:true."
  def mark_online_and_broadcast(socket) do
    user_id = current_user(socket)
    endpoint = socket.endpoint
    app_id = app_id(socket)

    if is_binary(user_id) do
      Task.start(fn ->
        case Store.mark_online(user_id) do
          {:transition, :online} ->
            broadcast_presence(endpoint, app_id, user_id, true, nil)

          :already_online ->
            :ok

          :error ->
            # Fail-closed: a store error does NOT broadcast a maybe-online. The next heartbeat retries.
            Logger.error("presence: mark_online store error for #{user_id} (no broadcast)")
            :ok
        end
      end)
    end

    :ok
  end

  @doc "Mark this socket's user offline (+ stamp last_seen) and broadcast online:false to subscribers."
  def clear_online_and_broadcast(socket) do
    user_id = current_user(socket)
    endpoint = socket.endpoint
    app_id = app_id(socket)

    if is_binary(user_id) do
      now = System.system_time(:second)

      Task.start(fn ->
        Store.clear_online(user_id, now)
        broadcast_presence(endpoint, app_id, user_id, false, now)
      end)
    end

    :ok
  end

  @doc "Authorize + subscribe this socket to each requested target; push an initial snapshot for each."
  def subscribe(socket, user_ids) do
    me = current_user(socket)
    app_id = app_id(socket)

    requested =
      user_ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq() |> Enum.take(@max_targets)

    {socket, authorized} =
      Enum.reduce(requested, {socket, []}, fn external, {sock, acc} ->
        cond do
          # presence_subs maps the EXTERNAL id the client speaks → the INTERNAL id the core is keyed on.
          Map.has_key?(sock.assigns.presence_subs, external) ->
            {sock, [external | acc]}

          true ->
            # THE FIX: the SDK sends an EXTERNAL id, but topic/authz/store are all INTERNAL-keyed. Resolve
            # external → internal (within the socket's app) FIRST — this is why subscribe returned []: an
            # internal-vs-external pair never matched in shares_conversation?. An id that doesn't resolve, or
            # that the viewer may not see, is dropped silently (no existence/visibility reveal).
            with {:ok, internal} when is_binary(internal) <- resolve_internal(external, app_id),
                 true <- PresenceAuthz.can_see?(me, internal) do
              # endpoint.subscribe runs in the CHANNEL process (called from handle_in), so the channel
              # receives presence:<internal> broadcasts and forwards them (user_channel handle_info).
              sock.endpoint.subscribe(topic(internal))
              sock = assign(sock, :presence_subs, Map.put(sock.assigns.presence_subs, external, internal))
              # Snapshot is authorized on the INTERNAL id but returned to the SDK under the EXTERNAL id.
              snapshot(internal, external)
              {sock, [external | acc]}
            else
              _ -> {sock, acc}
            end
        end
      end)

    {socket, Enum.reverse(authorized)}
  end

  @doc "Unsubscribe this socket from each target's presence (by the EXTERNAL id the client subscribed with)."
  def unsubscribe(socket, user_ids) do
    Enum.reduce(user_ids, socket, fn external, sock ->
      case is_binary(external) and Map.get(sock.assigns.presence_subs, external) do
        internal when is_binary(internal) ->
          sock.endpoint.unsubscribe(topic(internal))
          assign(sock, :presence_subs, Map.delete(sock.assigns.presence_subs, external))

        _ ->
          sock
      end
    end)
  end

  @doc """
  Re-authorize a presence delivery and forward it to the client ONLY if the viewer may still see the target.

  This is the "authorize every delivery" gate: a subscription is authorized once at subscribe time, but the
  viewer may have since lost the shared conversation, or the target may have flipped to "nobody" — either of
  which `PresenceAuthz.can_see?/2` catches. Runs OFF the channel process (the authz does client calls); on
  pass it sends `{:presence_forward, …}` back to the channel to push, on fail it drops silently. So the live
  path can never leak to an ex-contact — matching the read path (`PresenceRead`), which re-checks every call.
  """
  def forward_if_authorized(socket, event, payload) do
    me = current_user(socket)
    # The re-auth runs on the INTERNAL id (the payload carries it alongside the external one); the id the SDK
    # ultimately sees is the EXTERNAL `user_id`, with `internal_id` STRIPPED so no internal uuid ever leaks.
    target_internal = Map.get(payload, "internal_id") || Map.get(payload, :internal_id)
    channel_pid = self()

    Task.start(fn ->
      if is_binary(me) and is_binary(target_internal) and PresenceAuthz.can_see?(me, target_internal) do
        send(channel_pid, {:presence_forward, event, client_payload(payload)})
      end
    end)

    :ok
  end

  # The wire frame for the SDK: the external id only, internal_id dropped.
  defp client_payload(payload), do: Map.drop(payload, ["internal_id", :internal_id])

  @doc "The presence PubSub topic for a user (exposed for tests)."
  def topic(user_id), do: "presence:" <> user_id

  # --- internals ---

  # Broadcast a transition. The topic + authz are keyed on the INTERNAL id, but the frame the SDK ultimately
  # sees must carry the EXTERNAL id — so resolve internal → external ONCE here and put BOTH in the payload
  # (`internal_id` for the receiver's re-auth, `user_id` external for the client). If the user has no external
  # id (a first-party phone/email user), there is no /v1 subscriber who could be watching them, so we skip —
  # never broadcasting an internal uuid the SDK couldn't use anyway.
  #
  # GATED on visibility != nobody (one check gating the whole broadcast — subscribers already passed the
  # shared-conversation check at subscribe, and every delivery is re-authorized at the receiver).
  defp broadcast_presence(endpoint, app_id, user_id, online, last_seen) do
    case resolve_external(user_id, app_id) do
      external when is_binary(external) ->
        if visible?(user_id) do
          endpoint.broadcast(topic(user_id), "presence_updated", %{
            "user_id" => external,
            "internal_id" => user_id,
            "online" => online,
            "last_seen_at" => iso8601(last_seen)
          })
        else
          # Visibility is "nobody" → not broadcast (a normal outcome, not a failure).
          :ok
        end

      _ ->
        # No external id → no /v1 audience; nothing to broadcast (and never leak the internal id).
        :ok
    end
  end

  # Read the target's current state OFF the channel process, then hand the snapshot back to the channel
  # process (self()) to push — so a slow Redis never blocks the channel on subscribe. Authorized on the
  # INTERNAL id; returned to the SDK under the EXTERNAL id it subscribed with.
  defp snapshot(internal, external) do
    channel_pid = self()

    Task.start(fn ->
      online = Store.online?(internal)
      last_seen = if online, do: nil, else: Store.last_seen(internal)

      send(
        channel_pid,
        {:presence_snapshot,
         %{"user_id" => external, "online" => online, "last_seen_at" => iso8601(last_seen)}}
      )
    end)

    :ok
  end

  # external → internal within the socket's app (the SDK speaks external; topic/authz/store are internal).
  # Resolve-ONLY (the "cleaner future primitive" the old note here wished for): a subscribe is a REFERENCE,
  # so a bogus external id is simply dropped — no orphan user row is ever created.
  defp resolve_internal(external, app_id) when is_binary(app_id) and app_id != "" do
    case SharedInfra.AuthClient.lookup_external_user(%{"app_id" => app_id, "external_id" => external}) do
      {:ok, res} -> {:ok, Map.get(res, :user_id) || Map.get(res, "user_id")}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp resolve_internal(_external, _app_id), do: :error

  # internal → external within the app (never creates). nil for a first-party user with no external id.
  defp resolve_external(internal, app_id) when is_binary(app_id) and app_id != "" do
    case SharedInfra.AuthClient.resolve_user_external_id(%{"app_id" => app_id, "user_id" => internal}) do
      {:ok, res} -> Map.get(res, :external_id) || Map.get(res, "external_id")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_external(_internal, _app_id), do: nil

  defp app_id(socket), do: Map.get(socket.assigns, :app_id)

  defp visible?(user_id) do
    case SharedInfra.UserClient.last_seen_visibility(%{"user_id" => user_id}) do
      {:ok, result} ->
        case Map.get(result, :last_seen_visibility) || Map.get(result, "last_seen_visibility") do
          # FAIL-CLOSED: only a confirmed non-"nobody" string is visible. A nil / missing / unknown value
          # (a degraded response, a schema skew) must NOT broadcast — `nil != "nobody"` would leak.
          "nobody" -> false
          v when is_binary(v) and v != "" -> true
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp current_user(socket),
    do: Map.get(socket.assigns, :current_user_id) || Map.get(socket.assigns, :topic_user_id)

  defp iso8601(nil), do: nil
  defp iso8601(unix) when is_integer(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

end
