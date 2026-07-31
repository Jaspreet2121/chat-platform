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
    audience = presence_audience(socket)

    requested =
      user_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.take(@max_targets)

    {socket, authorized} =
      Enum.reduce(requested, {socket, []}, fn requested_id, {sock, acc} ->
        cond do
          # presence_subs maps the id the CLIENT speaks → the INTERNAL id the core is keyed on. For /v1 that
          # client id is an EXTERNAL id; for a FIRST-PARTY client (no external id) it IS the internal id.
          Map.has_key?(sock.assigns.presence_subs, requested_id) ->
            {sock, [requested_id | acc]}

          true ->
            # AUDIENCE-AWARE: /v1 sends an EXTERNAL id → resolve to internal (topic/authz/store are all
            # internal-keyed); a first-party client already sends the internal id → use it directly (resolving
            # it as an external id is exactly why first-party subscribe returned []). An id that doesn't
            # resolve, or that the viewer may not see, is dropped silently (no existence/visibility reveal).
            with {:ok, internal} when is_binary(internal) <-
                   resolve_target(requested_id, app_id, audience),
                 true <- PresenceAuthz.can_see?(me, internal) do
              # endpoint.subscribe runs in the CHANNEL process (called from handle_in), so the channel
              # receives presence:<internal> broadcasts and forwards them (user_channel handle_info).
              sock.endpoint.subscribe(topic(internal))

              sock =
                assign(
                  sock,
                  :presence_subs,
                  Map.put(sock.assigns.presence_subs, requested_id, internal)
                )

              snapshot(internal, requested_id, audience)
              {sock, [requested_id | acc]}
            else
              _ -> {sock, acc}
            end
        end
      end)

    {socket, Enum.reverse(authorized)}
  end

  # /v1 client id is EXTERNAL (resolve → internal within the app); a first-party id IS already internal.
  defp resolve_target(requested_id, app_id, :v1), do: resolve_internal(requested_id, app_id)
  defp resolve_target(requested_id, _app_id, _first_party), do: {:ok, requested_id}

  defp presence_audience(socket), do: Map.get(socket.assigns, :presence_audience, :first_party)

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
    audience = presence_audience(socket)

    # The re-auth runs on the INTERNAL id (the payload carries it alongside any external one). What the client
    # ultimately sees depends on its AUDIENCE — see client_payload/2.
    target_internal = Map.get(payload, "internal_id") || Map.get(payload, :internal_id)
    channel_pid = self()

    Task.start(fn ->
      if is_binary(me) and is_binary(target_internal) and
           PresenceAuthz.can_see?(me, target_internal) do
        send(channel_pid, {:presence_forward, event, client_payload(payload, audience)})
      end
    end)

    :ok
  end

  # PER-SUBSCRIBER (this runs on each subscriber's channel, so a /v1 and a first-party subscriber on the SAME
  # topic each get the right frame): /v1 → strip internal_id (never leak an internal uuid to an integrator; the
  # frame keeps the external `user_id`). first-party → keep internal_id (the id they key off; `user_id` may be
  # null when the target has no external id).
  defp client_payload(payload, :v1), do: Map.drop(payload, ["internal_id", :internal_id])
  defp client_payload(payload, _first_party), do: payload

  @doc "The presence PubSub topic for a user (exposed for tests)."
  def topic(user_id), do: "presence:" <> user_id

  # --- internals ---

  # Broadcast a transition. The topic + authz are keyed on the INTERNAL id; the frame carries BOTH ids —
  # `internal_id` (for the receiver's re-auth AND for first-party clients, who key off it) and `user_id` (the
  # EXTERNAL id, or NULL for a first-party-only user with no external id). We ALWAYS broadcast a visible
  # transition — first-party targets included (THE BUG FIX: this used to skip when there was no external id, so
  # first-party subscribers never got live frames). No internal uuid leaks to /v1 because delivery
  # (client_payload/2) strips it per-subscriber for the /v1 audience, and a /v1 subscriber can never be on a
  # first-party-only target's topic anyway (it couldn't resolve the id to subscribe).
  #
  # GATED on visibility != nobody (one check gating the whole broadcast — subscribers already passed the
  # shared-conversation check at subscribe, and every delivery is re-authorized at the receiver).
  defp broadcast_presence(endpoint, app_id, user_id, online, last_seen) do
    if visible?(user_id) do
      endpoint.broadcast(topic(user_id), "presence_updated", %{
        "user_id" => resolve_external(user_id, app_id),
        "internal_id" => user_id,
        "online" => online,
        "last_seen_at" => iso8601(last_seen)
      })
    else
      # Visibility is "nobody" → not broadcast (a normal outcome, not a failure).
      :ok
    end
  end

  # Read the target's current state OFF the channel process, then hand the snapshot back to the channel
  # process (self()) to push — so a slow Redis never blocks the channel on subscribe. Authorized on the
  # INTERNAL id; the frame's shape matches the live broadcast per audience (see snapshot_frame/5).
  defp snapshot(internal, requested_id, audience) do
    channel_pid = self()

    Task.start(fn ->
      online = Store.online?(internal)
      last_seen = if online, do: nil, else: Store.last_seen(internal)

      send(
        channel_pid,
        {:presence_snapshot, snapshot_frame(internal, requested_id, audience, online, last_seen)}
      )
    end)

    :ok
  end

  # /v1: keyed by the EXTERNAL id it subscribed with (`requested_id`); no internal_id. first-party: carries
  # `internal_id` (what it keys off) with a null external `user_id` — mirroring the live frame after delivery.
  defp snapshot_frame(_internal, requested_id, :v1, online, last_seen) do
    %{"user_id" => requested_id, "online" => online, "last_seen_at" => iso8601(last_seen)}
  end

  defp snapshot_frame(internal, _requested_id, _first_party, online, last_seen) do
    %{
      "user_id" => nil,
      "internal_id" => internal,
      "online" => online,
      "last_seen_at" => iso8601(last_seen)
    }
  end

  # external → internal within the socket's app (the SDK speaks external; topic/authz/store are internal).
  # Resolve-ONLY (the "cleaner future primitive" the old note here wished for): a subscribe is a REFERENCE,
  # so a bogus external id is simply dropped — no orphan user row is ever created.
  defp resolve_internal(external, app_id) when is_binary(app_id) and app_id != "" do
    case SharedInfra.AuthClient.lookup_external_user(%{
           "app_id" => app_id,
           "external_id" => external
         }) do
      {:ok, res} -> {:ok, Map.get(res, :user_id) || Map.get(res, "user_id")}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp resolve_internal(_external, _app_id), do: :error

  # internal → external within the app (never creates). nil for a first-party user with no external id.
  defp resolve_external(internal, app_id) when is_binary(app_id) and app_id != "" do
    case SharedInfra.AuthClient.resolve_user_external_id(%{
           "app_id" => app_id,
           "user_id" => internal
         }) do
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

  defp iso8601(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
end
