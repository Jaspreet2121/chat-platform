defmodule ApiGatewayWeb.AdminHealthController do
  @moduledoc """
  Aggregated system health (admin-only). Pings each reachable service's `/internal/health` over the
  internal API and assembles: the three platform dependencies (Postgres + Kafka from message-service,
  MinIO from media-service), per-service up/down, CONSUMER LAG for every Kafka group on the platform,
  and an overall healthy/degraded/down. Always returns
  200 with the health payload — a down dependency is data, not an error (so the dashboard renders it).
  Detailed internals stay behind RequireAdmin; the public /health is a separate lightweight liveness.
  """
  use ApiGatewayWeb, :controller

  plug ApiGatewayWeb.Plugs.RequirePermission, "platform.view"

  # name, shared_infra config key, env fallback — the services the gateway can reach over HTTP.
  @services [
    {"auth", :auth_service_url, "AUTH_SERVICE_URL"},
    {"user", :user_service_url, "USER_SERVICE_URL"},
    {"conversation", :conversation_service_url, "CONVERSATION_SERVICE_URL"},
    {"message", :message_service_url, "MESSAGE_SERVICE_URL"},
    {"media", :media_service_url, "MEDIA_SERVICE_URL"}
  ]

  def show(conn, _params) do
    pinged =
      Map.new(@services, fn {name, cfg, env} -> {name, ping(base_url(cfg, env))} end)

    message = reachable_map(pinged["message"])
    media = reachable_map(pinged["media"])

    dependencies = %{
      postgres: dig(message, [:deps, :postgres]),
      kafka: dig(message, [:deps, :kafka]),
      minio: dig(media, [:deps, :minio])
    }

    services =
      Enum.map(@services, fn {name, _, _} ->
        %{
          name: name,
          status: service_status(pinged[name]),
          # THAT service's build, from its own /internal/health; "unknown" when it is down or its
          # body has no git_sha (an image from before the field existed). A mixed fleet mid-deploy
          # shows up here as differing SHAs, which is the whole point.
          git_sha: service_git_sha(pinged[name])
        }
      end) ++
        [
          # realtime runs inside THIS gateway process — if we're answering, it's up, at our build.
          %{name: "realtime", status: "up", git_sha: SharedInfra.BuildInfo.git_sha()},
          # notification is a consumer with no gateway-reachable health endpoint yet.
          %{name: "notification", status: "unknown", git_sha: "unknown"}
        ]

    # CONSUMER LAG, straight from message-service's own health body. It monitors every registered
    # group including notification-service's, because lag is read from the cluster rather than from
    # the consuming process — so one curl here answers "is anything behind?" for the whole platform.
    consumer_lag = consumer_lag(message)

    json(conn, %{
      status: overall(dependencies, services),
      consumer_lag: consumer_lag,
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      # THIS GATEWAY's build. Each service reports its own on its /internal/health; a mixed fleet
      # mid-deploy is exactly what this is for.
      git_sha: SharedInfra.BuildInfo.git_sha(),
      dependencies: dependencies,
      services: services
    })
  end

  defp ping(nil), do: {:unreachable, %{}}

  defp ping(base) do
    case SharedInfra.HttpClient.get_result(base, "/internal/health", unavailable: :unreachable) do
      {:ok, map} when is_map(map) -> {:reachable, map}
      _ -> {:unreachable, %{}}
    end
  end

  defp reachable_map({:reachable, map}), do: map
  defp reachable_map(_), do: %{}

  defp service_status({:reachable, _}), do: "up"
  defp service_status(_), do: "down"

  # Never a crash on a body without the field: an older image answers {service, status, deps} only.
  defp service_git_sha({:reachable, map}) when is_map(map) do
    case Map.get(map, :git_sha) || Map.get(map, "git_sha") do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> "unknown"
    end
  end

  defp service_git_sha(_), do: "unknown"

  defp base_url(cfg, env), do: Application.get_env(:shared_infra, cfg) || System.get_env(env)

  # Read a nested value with atom keys; default to an "unknown" status map when absent/unreachable.
  # READ BOTH KEY SHAPES, deliberately. `SharedInfra.InternalApi.decode_result/2` rehydrates map keys
  # with `String.to_existing_atom` and falls back to the STRING when the atom does not exist in THIS
  # release — and the lag snapshot is built in message-service, whose module is not in the gateway's.
  # So these keys arrive as strings on the HTTP path and as atoms in-process, and reading only atoms
  # would have produced an empty panel on the real deployment while every test passed.
  #
  # It also removes a deploy-order constraint rather than adding one: this works whichever of the two
  # containers is restarted first.
  defp consumer_lag(message) do
    case Map.get(message, :consumer_lag) || Map.get(message, "consumer_lag") do
      %{} = snapshot -> snapshot
      _ -> %{status: "unknown", stale: true, groups: []}
    end
  end

  defp dig(map, path) do
    case get_in(map, path) do
      %{} = found -> found
      _ -> %{status: "unknown", latency_ms: nil, error: nil}
    end
  end

  defp overall(dependencies, services) do
    statuses =
      (dependencies |> Map.values() |> Enum.map(&Map.get(&1, :status))) ++
        Enum.map(services, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 in ["down", "unknown"])) -> "down"
      Enum.any?(statuses, &(&1 == "down")) -> "degraded"
      true -> "healthy"
    end
  end
end
