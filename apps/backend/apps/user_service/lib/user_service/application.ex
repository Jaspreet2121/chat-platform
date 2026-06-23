defmodule UserService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: UserService.Supervisor)
  end

  # The Repo is supervised at boot in dev/prod so the server can serve DB-backed requests.
  # In :test it is NOT started here (config sets `start_repo: false`); DataCase starts it
  # per-test, keeping plain `mix test` Docker-free.
  defp children do
    repo_children() ++ http_children()
  end

  defp repo_children do
    if Application.get_env(:user_service, :start_repo, true), do: [UserService.Repo], else: []
  end

  # Internal HTTP API listener starts ONLY under USER_HTTP_API_ENABLED (default off), so the
  # umbrella boot + plain `mix test` start no listener. Bind on a private network in deployment.
  defp http_children do
    if http_api_enabled?() do
      [{Plug.Cowboy, scheme: :http, plug: UserService.HTTP.Router, options: [port: http_port()]}]
    else
      []
    end
  end

  defp http_api_enabled? do
    Application.get_env(:user_service, :http_api_enabled, false) ||
      System.get_env("USER_HTTP_API_ENABLED") in ["true", "1", "yes"]
  end

  defp http_port do
    Application.get_env(:user_service, :http_port) ||
      String.to_integer(System.get_env("USER_HTTP_PORT") || "4103")
  end
end
