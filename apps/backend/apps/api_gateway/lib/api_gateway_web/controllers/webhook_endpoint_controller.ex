defmodule ApiGatewayWeb.WebhookEndpointController do
  @moduledoc """
  App-owner management of webhook endpoints via the first-party session (dashboard path). The endpoint's
  app is resolved from an OPTIONAL `app_id` param the caller must OWN (authorized against app_owners,
  exactly like ApiKeyController) — so an owner registers webhooks AS their registered app, not tenant-zero.
  With no `app_id` (or the default app), it falls back to the session's app_id (backward-compat). The
  signing secret is returned ONCE on create; list/update/delete never expose it.

  Integrators' SERVERS should use the key-authenticated `/v1/webhooks/endpoints`
  (`ApiGatewayWeb.V1.WebhookEndpointController`) instead — same context, secret-key auth, app_id from the key.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/webhooks/endpoints — register a URL for an owned app; returns the signing secret ONCE.
  def create(conn, params) do
    with {:ok, url} <- require_url(params),
         {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.create_webhook_endpoint(%{
             "app_id" => app_id,
             "url" => url,
             "event_types" => Map.get(params, "event_types")
           }) do
      conn
      |> put_status(:created)
      |> json(endpoint)
    else
      {:error, :missing_url} -> ErrorResponse.invalid_request(conn, "webhook.url_required")
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # GET /api/v1/webhooks/endpoints — list an owned app's endpoints (never the signing secret).
  def index(conn, params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, result} <- SharedInfra.AuthClient.list_webhook_endpoints(%{"app_id" => app_id}) do
      json(conn, result)
    else
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  @doc """
  GET /api/v1/webhooks/deliveries?app_id=&status=&endpoint_id=&limit=&cursor= — the OWNER-facing delivery
  log for one owned app (every status, not just failed). Same ownership gate as the endpoint routes.

  Scoped `WHERE app_id = <owned app>` in SQL, so another app's rows can never appear. Metadata only — the
  outbox `payload` (which carries the event body, incl. message content) is never selected, and no
  `signing_secret` is joined in. Keyset cursor (created_at,id), default limit 30, cap 100.
  """
  def deliveries(conn, params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {cursor_ts, cursor_id} <- decode_cursor(Map.get(params, "cursor")),
         {:ok, result} <-
           SharedInfra.AuthClient.list_webhook_deliveries(%{
             "app_id" => app_id,
             "status" => Map.get(params, "status"),
             "endpoint_id" => Map.get(params, "endpoint_id"),
             "limit" => Map.get(params, "limit"),
             "cursor_ts" => cursor_ts,
             "cursor_id" => cursor_id
           }) do
      json(conn, %{
        deliveries: cget(result, :items) || [],
        next_cursor: encode_cursor(cget(result, :next_cursor))
      })
    else
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # Opaque base64 keyset cursor over "created_at|id" — the SAME encoding AdminWebhookController uses.
  defp encode_cursor(nil), do: nil

  defp encode_cursor(next) when is_map(next) do
    ts = cget(next, :created_at)
    id = cget(next, :id)
    if is_binary(ts) and is_binary(id), do: Base.url_encode64("#{ts}|#{id}", padding: false), else: nil
  end

  defp encode_cursor(_), do: nil

  defp decode_cursor(value) when is_binary(value) and value != "" do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         [ts, id] <- String.split(raw, "|", parts: 2) do
      {ts, id}
    else
      _ -> {nil, nil}
    end
  end

  defp decode_cursor(_), do: {nil, nil}

  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil

  # PATCH /api/v1/webhooks/endpoints/:id — enable/disable or change event_types.
  def update(conn, %{"id" => id} = params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.update_webhook_endpoint(%{
             "app_id" => app_id,
             "id" => id,
             "enabled" => Map.get(params, "enabled"),
             "event_types" => Map.get(params, "event_types")
           }) do
      json(conn, endpoint)
    else
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> not_found(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # DELETE /api/v1/webhooks/endpoints/:id
  def delete(conn, %{"id" => id} = params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, result} <-
           SharedInfra.AuthClient.delete_webhook_endpoint(%{
             "app_id" => app_id,
             "id" => id
           }) do
      json(conn, result)
    else
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> not_found(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # Resolve the app_id to act AS: the optional `app_id` param, which the caller must OWN (or the default
  # app, open for backward-compat); no param → the session's app_id. Same rule + app_owners gate as
  # ApiKeyController — a caller can NEVER manage webhooks for an app they don't own → {:error, :not_owner}.
  # THE ownership rule lives in ApiGatewayWeb.AppOwnerAuth (one copy, shared with the usage +
  # deliveries endpoints). Behaviour is unchanged: not-owned app_id → {:error, :not_owner} → 403.
  defp resolve_target_app(session, params),
    do: ApiGatewayWeb.AppOwnerAuth.resolve_target_app(session, params)

  defp app_session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp require_url(params) do
    case Map.get(params, "url") do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_url}
    end
  end

  defp forbidden_app(conn),
    do: ErrorResponse.forbidden(conn, "webhook.forbidden_app", "You do not own this app")

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "webhook.unavailable")

  defp not_found(conn),
    do: ErrorResponse.not_found(conn, "webhook.not_found", "Webhook endpoint not found")
end
