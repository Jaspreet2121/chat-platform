defmodule RealtimeGateway.UserSocket do
  use Phoenix.Socket

  channel "conversation:*", RealtimeGateway.ConversationChannel
  channel "user:*", RealtimeGateway.UserChannel
  channel "call:*", RealtimeGateway.CallChannel

  @impl true
  def connect(params, socket, _connect_info) do
    if socket_auth_persistence_enabled?() do
      authenticated_connect(params, socket)
    else
      placeholder_connect(params, socket)
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"

  defp authenticated_connect(params, socket) do
    with :ok <- require_db_backed_sessions(),
         {:ok, authorization} <- authorization_param(params) do
      # Try a normal logged-in session FIRST (existing app — behaviour unchanged). If that's not a
      # session token, try an integrator END-USER (app_user) token — SAME verify crypto + authority as
      # the /v1 REST plug. Anything malformed/expired/wrong-typ falls through to :error (no oracle).
      case SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
        {:ok, session} ->
          # A normal app session is the default (live) tenant.
          {:ok,
           assign_session(
             socket,
             session.user_id,
             session.device_id,
             Map.get(session, :app_id),
             "live"
           )}

        _ ->
          case SharedInfra.AuthClient.verify_app_user_token(%{
                 "token" => strip_bearer(authorization)
               }) do
            {:ok, %{app_id: app_id, user_id: user_id} = res} ->
              {:ok, assign_session(socket, user_id, "end_user", app_id, Map.get(res, :mode))}

            _ ->
              :error
          end
      end
    else
      _ -> :error
    end
  end

  defp strip_bearer("Bearer " <> token), do: token
  defp strip_bearer(token), do: token

  # Fail closed: when socket auth is enabled but the Auth session layer is NOT
  # genuinely DB-backed, `SharedInfra.AuthClient.current_session/1` returns an
  # unverified placeholder identity. Reject rather than accept it, so enabling
  # REALTIME_AUTH_DB_BACKED without AUTH_SESSION_DB_BACKED cannot silently grant
  # a shared placeholder identity to every socket.
  defp require_db_backed_sessions do
    if SharedInfra.AuthClient.persistence_enabled?() do
      :ok
    else
      {:error, :session_layer_not_db_backed}
    end
  end

  defp placeholder_connect(params, socket) do
    {:ok,
     assign_session(
       socket,
       Map.get(params, "user_id", "user_placeholder"),
       Map.get(params, "device_id", "device_placeholder"),
       nil,
       "live"
     )}
  end

  defp assign_session(socket, user_id, device_id, app_id, mode) do
    socket
    |> assign(:current_user_id, user_id)
    |> assign(:user_id, user_id)
    |> assign(:device_id, device_id || "device_placeholder")
    # The app (tenant) this socket belongs to — defaults to tenant zero for the existing app. A test
    # credential's app_id is its DISTINCT twin, so join authz (which keys on app_id) isolates test↔live.
    |> assign(:app_id, SharedInfra.Tenancy.app_id_or_default(app_id))
    # Surfaced for observability alongside app_id; not an isolation predicate.
    |> assign(:app_mode, mode_atom(mode))
  end

  defp mode_atom("test"), do: :test
  defp mode_atom(_), do: :live

  defp authorization_param(params) do
    case Map.get(params, "authorization") || Map.get(params, "Authorization") ||
           Map.get(params, "access_token") || Map.get(params, "token") do
      "Bearer " <> token when token != "" -> {:ok, "Bearer " <> token}
      token when is_binary(token) and token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp socket_auth_persistence_enabled? do
    Application.get_env(:realtime_gateway, :socket_auth_persistence, false) ||
      System.get_env("REALTIME_AUTH_DB_BACKED") in ["true", "1", "yes"]
  end
end
