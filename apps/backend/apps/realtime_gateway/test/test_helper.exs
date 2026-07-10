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

# RealtimeGateway.Limits reads the /socket rate + connection caps from RT_* env at the call site. Keep them
# effectively unlimited for the general channel suite so existing tests never trip a limit; the dedicated
# RealtimeGateway.LimitsTest sets explicit small values per-test and restores them.
for {var, value} <- [
      {"RT_JOIN_LIMIT", "1000000"},
      {"RT_WRITE_LIMIT", "1000000"},
      {"RT_EPHEMERAL_LIMIT", "1000000"},
      {"RT_MAX_SOCKETS_PER_USER", "1000000"},
      {"RT_MAX_SOCKETS_PER_APP", "1000000"}
    ] do
  System.put_env(var, value)
end

ExUnit.start()
ExUnit.configure(exclude: [postgres_integration: true])
