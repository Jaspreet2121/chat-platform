defmodule ApiGatewayWeb.NearbyController do
  @moduledoc """
  Session-owned Nearby People API. Exact coordinates are accepted only for the short-lived discovery
  write and never returned. Results and request lists are profile-enriched only after a fail-closed
  either-direction block check.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.NearbyBleStore
  alias ApiGatewayWeb.ProfilePresenter

  # 6/min (was 30 — audit 2026-08-26): with per-pair bucket pinning this is belt-and-braces
  # against movement-based trilateration; a human refreshing a modal never approaches it.
  @discover_limit 6

  # A background worker publishes far more often than a human opens the screen — but not unboundedly.
  # 30/hour is a fix every two minutes, comfortably above any sane cadence and low enough that a
  # runaway loop is capped rather than free to write.
  @publish_limit 30
  @request_limit 10
  # BLE (104): a handset re-requests its broadcast token at most every ~75s in practice; sightings
  # batch. Both fail CLOSED like discover — the BLE path is an enumeration/abuse surface.
  @ble_token_limit 4
  @ble_sightings_limit 12
  @ble_token_ttl 300
  @ble_marker_ttl 120
  @window_seconds 60
  @limiter_outage_retry 30

  def discover(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("nearby_discover", session.user_id, @discover_limit),
         {:ok, result} <-
           SharedInfra.UserClient.discover_nearby(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "latitude" => Map.get(params, "latitude"),
             "longitude" => Map.get(params, "longitude"),
             "accuracy_m" => Map.get(params, "accuracy_m"),
             "radius_m" => Map.get(params, "radius_m", 200)
           }) do
      people = result |> mget(:people) |> Kernel.||([]) |> overlay_ble(session)

      json(conn, %{
        people: enrich_visible(people, session),
        expires_in_seconds: mget(result, :expires_in_seconds),
        radius_m: mget(result, :radius_m)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  POST /api/v1/nearby/presence — publish a fix without running discovery (114).

  This is the background path: it exists so a phone can keep its owner visible while Nearby is
  closed. It deliberately returns NO people — a background worker has no business receiving a list of
  who is nearby, and keeping the surfaces separate means a compromised worker cannot enumerate.
  """
  def publish(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("nearby_publish", session.user_id, @publish_limit),
         {:ok, result} <-
           SharedInfra.UserClient.publish_nearby(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "latitude" => Map.get(params, "latitude"),
             "longitude" => Map.get(params, "longitude"),
             "accuracy_m" => Map.get(params, "accuracy_m")
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def stop(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <- SharedInfra.UserClient.stop_nearby(%{"user_id" => session.user_id}) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def requests(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.UserClient.list_nearby_requests(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session)
           }) do
      json(conn, %{
        incoming: enrich_visible(mget(result, :incoming) || [], session),
        outgoing: enrich_visible(mget(result, :outgoing) || [], session),
        connections: enrich_visible(mget(result, :connections) || [], session)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  # GET /api/v1/nearby/settings — the caller's discoverability settings (absent row = defaults).
  def settings(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, settings} <-
           SharedInfra.UserClient.get_nearby_settings(%{"user_id" => session.user_id}) do
      json(conn, settings_view(settings))
    else
      error -> handle_error(conn, error)
    end
  end

  # PATCH /api/v1/nearby/settings — partial update; enabled=false revokes any live presence
  # immediately (store-side, same transaction). Broadcasts nearby_settings_changed to own devices.
  def update_settings(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, settings} <-
           SharedInfra.UserClient.update_nearby_settings(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "enabled" => Map.get(params, "enabled"),
             "ble_assist" => Map.get(params, "ble_assist"),
             "audience" => Map.get(params, "audience")
           }) do
      ApiGatewayWeb.Endpoint.broadcast("user:" <> session.user_id, "nearby_settings_changed", %{
        "type" => "nearby_settings_changed"
      })

      json(conn, settings_view(settings))
    else
      error -> handle_error(conn, error)
    end
  end

  # POST /api/v1/nearby/ble/token — a fresh broadcast token (16 CSPRNG bytes, base64url), TTL 300s.
  # Re-request ROTATES: the per-user current-token key answers with the previous token in the same
  # atomic write, and that token's resolution entry is deleted — at most one live token per user.
  def ble_token(conn, _params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("nearby_ble_token", session.user_id, @ble_token_limit),
         :ok <- require_ble(session) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      with {:ok, previous} <-
             NearbyBleStore.put_get(cur_key(session.user_id), token, @ble_token_ttl),
           :ok <- rotate_out(previous),
           :ok <-
             NearbyBleStore.put(
               tok_key(token),
               session.user_id <> "|" <> session_app(session),
               @ble_token_ttl
             ) do
        json(conn, %{token: token, expires_in: @ble_token_ttl})
      else
        # A token that cannot be resolved later is worse than no token — 503, client retries.
        _ -> ErrorResponse.service_unavailable(conn, "nearby.unavailable")
      end
    else
      error -> handle_error(conn, error)
    end
  end

  # POST /api/v1/nearby/ble/sightings — the caller reports tokens it HEARD. The server resolves
  # them (same app only, never self, unknown/expired silently dropped), the STORE decides admission
  # (viewer presence live + audience both ways + blocks — UserService.Nearby.admit_ble_targets),
  # and each admitted pair gets a 120s proximity marker. The response is a COUNT only: which tokens
  # resolved (or to whom) is never disclosed — no oracle.
  def ble_sightings(conn, %{"tokens" => tokens}) when is_list(tokens) and length(tokens) <= 20 do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("nearby_ble_sightings", session.user_id, @ble_sightings_limit),
         :ok <- require_ble(session),
         {:ok, result} <-
           SharedInfra.UserClient.admit_ble_targets(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "targets" => resolve_tokens(tokens, session)
           }) do
      admitted = mget(result, :admitted) || []

      for target <- admitted do
        NearbyBleStore.put(prox_key(session.user_id, target), "1", @ble_marker_ttl)
      end

      json(conn, %{matched: length(admitted)})
    else
      error -> handle_error(conn, error)
    end
  end

  def ble_sightings(conn, _params), do: ErrorResponse.invalid_request(conn, "nearby.invalid")

  def send_request(conn, %{"user_id" => target}) when is_binary(target) and target != "" do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("nearby_request", session.user_id, @request_limit),
         :ok <- not_blocked(session.user_id, target),
         {:ok, result} <-
           SharedInfra.UserClient.send_nearby_request(%{
             "requester_user_id" => session.user_id,
             "recipient_user_id" => target,
             "app_id" => session_app(session)
           }) do
      # Realtime (recorded follow-up): the TARGET learns of the request live on their user topic —
      # the same helper convention as quick_replies_changed. Declines stay silent by design.
      ApiGatewayWeb.Endpoint.broadcast("user:" <> target, "nearby_request_received", %{
        "type" => "nearby_request_received",
        "request_id" => mget(result, :request_id),
        "from_user_id" => session.user_id
      })

      conn |> put_status(:created) |> json(result)
    else
      error -> handle_error(conn, error)
    end
  end

  def send_request(conn, _params), do: ErrorResponse.invalid_request(conn, "nearby.invalid")

  def respond(conn, %{"request_id" => request_id, "decision" => decision})
      when decision in ["accept", "decline"] do
    with {:ok, session} <- session(conn),
         :ok <- request_peer_not_blocked(session, request_id, decision),
         {:ok, result} <-
           SharedInfra.UserClient.respond_nearby_request(%{
             "user_id" => session.user_id,
             "request_id" => request_id,
             "decision" => decision
           }) do
      response = maybe_open_conversation(result, session)
      broadcast_accepted(response, session)
      json(conn, response)
    else
      error -> handle_error(conn, error)
    end
  end

  def respond(conn, _params), do: ErrorResponse.invalid_request(conn, "nearby.invalid")

  # ACCEPT OPENS THE CHAT (audit fix 1): create-or-get the 1:1 through the SAME conversation path
  # every DM uses (create_conversation find-or-creates direct pairs — idempotent by design; never a
  # second creation route), broadcast the inbox update, and hand the client the conversation_id.
  # Best-effort: the accept is already committed — a conversation-service hiccup returns the accept
  # without an id (the pair can open the chat later; find-or-create makes that safe), never a 500.
  defp maybe_open_conversation(result, session) do
    with "accepted" <- mget(result, :status),
         requester when is_binary(requester) <- mget(result, :user_id),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "type" => "direct",
             "created_by" => session.user_id,
             "participant_user_ids" => [requester],
             "app_id" => session_app(session)
           }) do
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(conversation)

      Map.put(
        Map.new(result, fn {k, v} -> {k, v} end),
        :conversation_id,
        mget(conversation, :conversation_id) || mget(conversation, :id)
      )
    else
      _ -> result
    end
  end

  # Realtime (recorded follow-up): on ACCEPT the REQUESTER learns live — who accepted and which
  # conversation opened (after maybe_open_conversation, so the id rides along when the create
  # succeeded). A decline broadcasts NOTHING: silent by design, the requester just never hears back.
  defp broadcast_accepted(response, session) do
    with "accepted" <- mget(response, :status),
         requester when is_binary(requester) <- mget(response, :user_id) do
      ApiGatewayWeb.Endpoint.broadcast("user:" <> requester, "nearby_request_accepted", %{
        "type" => "nearby_request_accepted",
        "request_id" => mget(response, :request_id),
        "user_id" => session.user_id,
        "conversation_id" => mget(response, :conversation_id)
      })
    else
      _ -> :ok
    end
  end

  defp enrich_visible(rows, session) do
    rows
    |> Enum.filter(fn row -> not_blocked(session.user_id, mget(row, :user_id)) == :ok end)
    |> Enum.map(fn row ->
      user_id = mget(row, :user_id)

      card =
        case SharedInfra.UserClient.get_public_profile(%{
               "user_id" => user_id,
               "app_id" => session_app(session)
             }) do
          {:ok, profile} -> ProfilePresenter.present(session.user_id, user_id, profile)
          _ -> %{user_id: user_id, display_name: nil, avatar_url: nil}
        end

      row
      |> Map.new(fn {key, value} -> {key, value} end)
      |> Map.merge(%{
        user_id: user_id,
        display_name: mget(card, :display_name),
        avatar_url: mget(card, :avatar_url)
      })
    end)
  end

  # BLE OVERLAY (104): a live proximity marker shows the pair as bucket "ble", ordered first. The
  # marker's TTL is the revert — when it dies, the row falls back to the GPS bucket, which is still
  # the PINNED one (the pin row in Postgres is never touched by any BLE path; a sighting cannot let
  # a viewer refine the GPS bucket). Redis trouble degrades to plain GPS — assist only.
  defp overlay_ble(people, session) do
    people
    |> Enum.map(fn row ->
      target = mget(row, :user_id)

      if is_binary(target) and ble_marker?(session.user_id, target) do
        row |> Map.new() |> Map.put(:distance_bucket_m, "ble")
      else
        row
      end
    end)
    |> Enum.sort_by(fn row -> if mget(row, :distance_bucket_m) == "ble", do: 0, else: 1 end)
  end

  defp ble_marker?(viewer, target) do
    match?({:ok, _}, NearbyBleStore.get(prox_key(viewer, target)))
  end

  # settings/enabled/ble_assist are BOOLEANS — matched explicitly, never through mget (the
  # falsy-mget trap: `false || fallback` reads a stored false as absent).
  defp setting_bool(settings, key, default) do
    case {Map.get(settings, key), Map.get(settings, Atom.to_string(key))} do
      {value, _} when is_boolean(value) -> value
      {_, value} when is_boolean(value) -> value
      _ -> default
    end
  end

  defp settings_view(settings) do
    %{
      enabled: setting_bool(settings, :enabled, true),
      ble_assist: setting_bool(settings, :ble_assist, false),
      audience: mget(settings, :audience) || "everyone"
    }
  end

  defp require_ble(session) do
    case SharedInfra.UserClient.get_nearby_settings(%{"user_id" => session.user_id}) do
      {:ok, settings} ->
        if setting_bool(settings, :enabled, true) and setting_bool(settings, :ble_assist, false),
          do: :ok,
          else: {:error, :nearby_disabled}

      _ ->
        {:error, :user_unavailable}
    end
  end

  # Token → target user id, applying the RESOLUTION-TIME drops (unknown/expired: Redis miss;
  # cross-app: stored app differs; self). Store-level admission (audience/blocks/presence) follows
  # in admit_ble_targets — none of the drops here are observable in the response (count only).
  defp resolve_tokens(tokens, session) do
    app = session_app(session)
    viewer = session.user_id

    tokens
    |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 64))
    |> Enum.uniq()
    |> Enum.flat_map(fn token ->
      with {:ok, value} <- NearbyBleStore.get(tok_key(token)),
           [user_id, token_app] <- String.split(value, "|", parts: 2),
           true <- token_app == app and user_id != viewer do
        [user_id]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp rotate_out({:was_present, old_token}), do: NearbyBleStore.del(tok_key(old_token))
  defp rotate_out(:was_absent), do: :ok

  defp tok_key(token), do: "nearby:ble:tok:" <> token
  defp cur_key(user_id), do: "nearby:ble:cur:" <> user_id
  defp prox_key(viewer, target), do: "nearby:ble:prox:" <> viewer <> ":" <> target

  # If block state cannot be checked, Nearby fails closed: proximity must never become a bypass.
  defp not_blocked(_viewer, nil), do: {:error, :nearby_blocked}

  defp not_blocked(viewer, target) do
    case SharedInfra.ConversationClient.either_blocked?(%{"user_a" => viewer, "user_b" => target}) do
      {:ok, result} -> if mget(result, :blocked) == true, do: {:error, :nearby_blocked}, else: :ok
      _ -> {:error, :nearby_blocked}
    end
  end

  defp request_peer_not_blocked(_session, _request_id, "decline"), do: :ok

  defp request_peer_not_blocked(session, request_id, "accept") do
    with {:ok, result} <-
           SharedInfra.UserClient.list_nearby_requests(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session)
           }),
         row when is_map(row) <-
           Enum.find(mget(result, :incoming) || [], &(mget(&1, :request_id) == request_id)) do
      not_blocked(session.user_id, mget(row, :user_id))
    else
      _ -> {:error, :nearby_request_not_found}
    end
  end

  defp session(conn) do
    with ["Bearer " <> token] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp rate_limit(kind, user_id, limit) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => kind <> ":" <> user_id,
           "limit" => limit,
           "window_seconds" => @window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :rate_limited, retry}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry))
    |> ErrorResponse.rate_limited("nearby.rate_limited")
  end

  defp handle_error(conn, {:error, :rate_limiter_unavailable}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
    |> ErrorResponse.service_unavailable("nearby.unavailable")
  end

  defp handle_error(conn, {:error, :user_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "nearby.unavailable")

  defp handle_error(conn, {:error, :nearby_accuracy_too_low}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "nearby.accuracy_too_low",
        "Location accuracy must be within 100 metres",
        %{}
      )

  defp handle_error(conn, {:error, :nearby_request_cooldown}),
    do:
      ErrorResponse.conflict(
        conn,
        "nearby.request_cooldown",
        "They declined recently — you can ask again after 24 hours"
      )

  defp handle_error(conn, {:error, :nearby_request_exists}),
    do: ErrorResponse.conflict(conn, "nearby.request_exists", "A request is already pending")

  defp handle_error(conn, {:error, :nearby_already_connected}),
    do: ErrorResponse.conflict(conn, "nearby.already_connected", "You are already connected")

  defp handle_error(conn, {:error, :nearby_presence_required}),
    do:
      ErrorResponse.conflict(
        conn,
        "nearby.presence_required",
        "Start sharing your location before reporting sightings"
      )

  defp handle_error(conn, {:error, :nearby_disabled}),
    do: ErrorResponse.forbidden(conn, "nearby.disabled", "Nearby is turned off in your settings")

  # DISTINCT from nearby.disabled on purpose. "You turned Nearby off" and "you never turned on
  # background publishing" need different words in the client, and the second must not read as a
  # fault — the user simply has not opted in.
  defp handle_error(conn, {:error, :nearby_publish_disabled}),
    do:
      ErrorResponse.forbidden(
        conn,
        "nearby.publish_disabled",
        "Background location sharing is off — turn it on in Nearby settings"
      )

  defp handle_error(conn, {:error, :nearby_not_discoverable}),
    do: ErrorResponse.not_found(conn, "nearby.not_available", "This person is no longer nearby")

  defp handle_error(conn, {:error, :nearby_request_not_found}),
    do: ErrorResponse.not_found(conn, "nearby.request_not_found", "Request not found")

  defp handle_error(conn, {:error, :nearby_blocked}),
    do: ErrorResponse.not_found(conn, "nearby.not_available", "This person is not available")

  defp handle_error(conn, _), do: ErrorResponse.invalid_request(conn, "nearby.invalid")

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")
  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp mget(_, _), do: nil
end
