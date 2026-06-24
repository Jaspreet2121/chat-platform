defmodule ApiGatewayWeb.Plugs.CorrelationId do
  @moduledoc """
  Per-request correlation-id origin for the gateway.

  Honors an inbound `x-correlation-id` (when it's a sane non-empty string) so a caller can stitch
  a trace across the edge; otherwise mints a fresh id. Stashes it in Logger metadata (so every log
  line on this request carries it), in `conn.assigns[:correlation_id]` (so `ErrorResponse` can put
  the real id in the public error envelope), and echoes it back on the response `x-correlation-id`
  header. Runs right after `Plug.RequestId` in the endpoint.
  """

  @behaviour Plug

  alias SharedInfra.Correlation

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    id =
      case conn |> Plug.Conn.get_req_header(Correlation.header()) |> List.first() do
        inbound when is_binary(inbound) ->
          if Correlation.valid?(inbound), do: inbound, else: Correlation.generate()

        _ ->
          Correlation.generate()
      end

    Correlation.put(id)

    conn
    |> Plug.Conn.assign(:correlation_id, id)
    |> Plug.Conn.put_resp_header(Correlation.header(), id)
  end
end
