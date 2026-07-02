defmodule ApiGatewayWeb.Plugs.Observability do
  @moduledoc """
  LAYER 1 (structured logging) + hooks for LAYER 2 (error capture) & LAYER 3 (per-app metrics) for `/v1`.

  Placed FIRST on the `:v1` pipeline and works via `register_before_send`, so it observes EVERY response —
  including 401/429/404 produced when V1Auth / V1RateLimit halt before later plugs run. Reuses the request's
  existing `correlation_id` (from `ApiGatewayWeb.Plugs.CorrelationId`) so the log line, error row, and error
  envelope all share one id.

  On each response it emits ONE structured (Jason) log line — `correlation_id, app_id, actor, method, path,
  route, status, latency_ms` (+ `error_type` on error) — then best-effort, FIRE-AND-FORGET (a spawned task,
  never blocking the response) increments the per-app request metric and, on an error status, records an
  error row. Strictly additive + fail-open: any observability failure can NEVER break the actual request.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      observe(conn, start)
      conn
    end)
  end

  defp observe(conn, start) do
    latency_ms = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
    status = conn.status || 0
    app_id = conn.assigns[:v1_app_id]
    actor = conn.assigns[:v1_actor]
    method = conn.method
    path = conn.request_path
    route = route_label(conn)
    correlation_id = conn.assigns[:correlation_id] || SharedInfra.Correlation.get()
    error? = status >= 400
    {error_class, error_message} = if error?, do: error_details(conn), else: {nil, nil}

    log(%{
      event: "v1.request",
      correlation_id: correlation_id,
      app_id: app_id,
      actor: actor && to_string(actor),
      method: method,
      path: path,
      route: route,
      status: status,
      latency_ms: latency_ms,
      error_type: error_class
    })

    # Persist metrics/errors OFF the request path (fire-and-forget). SharedInfra.Observability is itself
    # fail-open, and Task.start never propagates a failure back to this process.
    conn_db = ApiGateway.Application.observability_db()

    Task.start(fn ->
      SharedInfra.Observability.incr_request(conn_db, app_id, route)

      if error? do
        SharedInfra.Observability.record_error(conn_db, %{
          correlation_id: correlation_id,
          app_id: app_id,
          actor: actor && to_string(actor),
          method: method,
          route: route,
          status: status,
          error_class: error_class,
          message: error_message
        })
      end
    end)

    :ok
  rescue
    # The observability path must never break the response.
    _error -> :ok
  end

  # One structured, machine-parseable JSON line per request (drops nil fields). warning for >=400.
  defp log(fields) do
    line = fields |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new() |> Jason.encode!()

    if fields.status >= 400, do: Logger.warning(line), else: Logger.info(line)
  end

  # Bounded route label from the matched Phoenix controller/action; falls back to method+path.
  defp route_label(conn) do
    case {conn.private[:phoenix_controller], conn.private[:phoenix_action]} do
      {controller, action} when is_atom(controller) and is_atom(action) and not is_nil(controller) ->
        "#{inspect(controller)}##{action}"

      _ ->
        "#{conn.method} #{conn.request_path}"
    end
  end

  # Best-effort: the /v1 error envelope is {"error":{"code":..,"message":..}}. Extract the real code so
  # the errors table answers "what broke". Falls back to an HTTP class if the body isn't the envelope.
  defp error_details(conn) do
    case decode_error(conn.resp_body) do
      {:ok, code, message} -> {code, message}
      :error -> {http_class(conn.status), nil}
    end
  end

  defp decode_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code} = err}} -> {:ok, code, Map.get(err, "message")}
      _ -> :error
    end
  end

  defp decode_error(_), do: :error

  defp http_class(status) when status >= 500, do: "server_error"
  defp http_class(status) when status >= 400, do: "client_error"
  defp http_class(_), do: nil
end
