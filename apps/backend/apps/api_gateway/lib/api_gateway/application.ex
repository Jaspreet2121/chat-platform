defmodule ApiGateway.Application do
  @moduledoc false

  use Application

  # Named raw-Postgrex connection for OBSERVABILITY writes/reads only (error capture + per-app metrics).
  # The gateway is otherwise Repo-less (domain data goes over HTTP clients); this is a cross-cutting
  # telemetry connection, kept separate + fail-open. Absent DATABASE_URL (dev/test) → not started →
  # SharedInfra.Observability no-ops.
  @observability_db ApiGateway.ObservabilityDB

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: ApiGateway.PubSub},
        # Owns the /v1 ETS tables (rate-limit + idempotency) — must start before the Endpoint.
        ApiGatewayWeb.V1Runtime
      ] ++ observability_children() ++ [ApiGatewayWeb.Endpoint]

    opts = [strategy: :one_for_one, name: ApiGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc "The observability Postgrex connection name (used by SharedInfra.Observability)."
  def observability_db, do: @observability_db

  defp observability_children do
    case observability_db_opts() do
      {:ok, opts} -> [{Postgrex, opts}]
      :none -> []
    end
  end

  defp observability_db_opts do
    case System.get_env("DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        uri = URI.parse(url)

        if is_binary(uri.host) do
          {user, pass} = split_userinfo(uri.userinfo)

          {:ok,
           [
             name: @observability_db,
             hostname: uri.host,
             port: uri.port || 5432,
             username: user,
             password: pass,
             database: String.trim_leading(uri.path || "/postgres", "/"),
             pool_size: 2
           ]}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp split_userinfo(info) when is_binary(info) do
    case String.split(info, ":", parts: 2) do
      [u, p] -> {u, p}
      [u] -> {u, nil}
    end
  end

  defp split_userinfo(_), do: {nil, nil}

  @impl true
  def config_change(changed, _new, removed) do
    ApiGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
