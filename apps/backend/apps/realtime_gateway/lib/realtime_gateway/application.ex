defmodule RealtimeGateway.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: RealtimeGateway.PubSub},
      RealtimeGateway.Presence
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RealtimeGateway.Supervisor)
  end
end
