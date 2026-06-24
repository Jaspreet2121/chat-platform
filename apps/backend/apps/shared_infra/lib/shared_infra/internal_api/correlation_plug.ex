defmodule SharedInfra.InternalApi.CorrelationPlug do
  @moduledoc """
  Reads the inbound `x-correlation-id` header into this process's Logger metadata, so a service's
  internal-API request logs share the originating request's correlation id.

  Added to every service's internal HTTP router (after `TokenPlug`, before `:dispatch`). Purely
  additive: if the header is absent or invalid, metadata is left untouched. Never rejects a request.
  """

  @behaviour Plug

  alias SharedInfra.Correlation

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn |> Plug.Conn.get_req_header(Correlation.header()) |> List.first() do
      id when is_binary(id) -> Correlation.put(id)
      _ -> :ok
    end

    conn
  end
end
