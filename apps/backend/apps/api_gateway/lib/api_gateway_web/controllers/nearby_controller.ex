defmodule ApiGatewayWeb.NearbyController do
  @moduledoc """
  Session-owned Nearby People API. Exact coordinates are accepted only for the short-lived discovery
  write and never returned. Results and request lists are profile-enriched only after a fail-closed
  either-direction block check.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.ProfilePresenter

  # 6/min (was 30 — audit 2026-08-26): with per-pair bucket pinning this is belt-and-braces
  # against movement-based trilateration; a human refreshing a modal never approaches it.
  @discover_limit 6
  @request_limit 10
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
      people = mget(result, :people) || []

      json(conn, %{
        people: enrich_visible(people, session),
        expires_in_seconds: mget(result, :expires_in_seconds),
        radius_m: mget(result, :radius_m)
      })
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
