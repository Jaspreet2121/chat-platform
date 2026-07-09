defmodule MediaService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: MediaService.Supervisor)
  end

  # MediaService.Repo persists media_assets (tenant + ownership) for the write path. Started
  # unconditionally like the other services' repos — Ecto's pool boots even if Postgres is momentarily
  # unreachable, and plain `mix test` (no DB) is unaffected (DB-backed tests are :postgres_integration).
  # The internal HTTP API listener starts ONLY under MEDIA_HTTP_API_ENABLED (default off); bind private.
  defp children do
    [MediaService.Repo] ++ http_children()
  end

  defp http_children do
    if http_api_enabled?() do
      [{Plug.Cowboy, scheme: :http, plug: MediaService.HTTP.Router, options: [port: http_port()]}]
    else
      []
    end
  end

  defp http_api_enabled? do
    Application.get_env(:media_service, :http_api_enabled, false) ||
      System.get_env("MEDIA_HTTP_API_ENABLED") in ["true", "1", "yes"]
  end

  defp http_port do
    Application.get_env(:media_service, :http_port) ||
      String.to_integer(System.get_env("MEDIA_HTTP_PORT") || "4105")
  end
end
