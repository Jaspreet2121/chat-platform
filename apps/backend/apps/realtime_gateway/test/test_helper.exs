Application.put_env(:realtime_gateway, RealtimeGateway.TestEndpoint,
  secret_key_base: "test-placeholder-change-before-production-test-placeholder-value",
  pubsub_server: RealtimeGateway.PubSub,
  server: false
)

defmodule RealtimeGateway.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :realtime_gateway

  socket "/socket", RealtimeGateway.UserSocket,
    websocket: true,
    longpoll: false
end

{:ok, _pid} = RealtimeGateway.TestEndpoint.start_link()

ExUnit.start()
ExUnit.configure(exclude: [postgres_integration: true])
