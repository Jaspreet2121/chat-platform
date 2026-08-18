defmodule AuthService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Runtime env read at boot (never config.exs-baked — the release trap). Count logged, values never.
    AuthService.ReviewerLogins.load()
    Supervisor.start_link(children(), strategy: :one_for_one, name: AuthService.Supervisor)
  end

  # The Repo is supervised at boot in dev/prod so the server can serve DB-backed requests.
  # In :test it is NOT started here (config sets `start_repo: false`); DataCase starts it
  # per-test, keeping plain `mix test` Docker-free.
  defp children do
    repo_children() ++ worker_children() ++ http_children()
  end

  defp repo_children do
    if Application.get_env(:auth_service, :start_repo, true), do: [AuthService.Repo], else: []
  end

  # The webhook delivery worker — started only when the Repo is up (so plain `mix test`, which doesn't
  # start the Repo, starts no worker) and not explicitly disabled. Default ON in deployment.
  defp worker_children do
    if Application.get_env(:auth_service, :start_repo, true) and webhook_worker_enabled?() do
      [AuthService.WebhookWorker]
    else
      []
    end
  end

  defp webhook_worker_enabled? do
    Application.get_env(:auth_service, :webhook_worker_enabled, true) and
      System.get_env("WEBHOOK_WORKER_ENABLED") != "false"
  end

  # The internal HTTP API listener starts ONLY under AUTH_HTTP_API_ENABLED (default off), so the
  # umbrella boot + plain `mix test` start no listener. Bind on a private network in deployment.
  defp http_children do
    if http_api_enabled?() do
      [{Plug.Cowboy, scheme: :http, plug: AuthService.HTTP.Router, options: [port: http_port()]}]
    else
      []
    end
  end

  defp http_api_enabled? do
    Application.get_env(:auth_service, :http_api_enabled, false) ||
      System.get_env("AUTH_HTTP_API_ENABLED") in ["true", "1", "yes"]
  end

  defp http_port do
    Application.get_env(:auth_service, :http_port) ||
      String.to_integer(System.get_env("AUTH_HTTP_PORT") || "4101")
  end
end
