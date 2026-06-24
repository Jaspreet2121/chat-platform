defmodule ApiGatewayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :api_gateway

  socket "/socket", RealtimeGateway.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug ApiGatewayWeb.Plugs.CorrelationId

  # CORS must run before the router so the browser's OPTIONS preflight is answered with the
  # Access-Control-Allow-* headers (cors_plug short-circuits OPTIONS automatically). The origin
  # is read at RUNTIME via cors_origins/0 (passed as a function capture, called per-request) so a
  # release respects the container's CORS_ORIGIN env instead of a value baked at compile time.
  plug CORSPlug, origin: &__MODULE__.cors_origins/0

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug ApiGatewayWeb.Router

  # Allowed CORS origins, read at runtime from CORS_ORIGIN (comma-separated). Defaults to the
  # local frontend dev server so local browser testing works out of the box.
  def cors_origins do
    case System.get_env("CORS_ORIGIN") do
      origin when is_binary(origin) and origin != "" -> String.split(origin, ",", trim: true)
      _ -> ["http://localhost:3000"]
    end
  end
end
