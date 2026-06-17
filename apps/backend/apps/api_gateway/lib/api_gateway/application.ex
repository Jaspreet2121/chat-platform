defmodule ApiGateway.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ApiGateway.PubSub},
      ApiGatewayWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ApiGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ApiGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
