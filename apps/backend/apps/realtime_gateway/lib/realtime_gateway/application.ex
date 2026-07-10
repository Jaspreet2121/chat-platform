defmodule RealtimeGateway.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: RealtimeGateway.PubSub},
      RealtimeGateway.Presence,
      # Owns the ETS table backing the connection counter's :ets backend (single-node / dev / tests).
      RealtimeGateway.ConnectionCounter.Table
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RealtimeGateway.Supervisor)
  end
end
