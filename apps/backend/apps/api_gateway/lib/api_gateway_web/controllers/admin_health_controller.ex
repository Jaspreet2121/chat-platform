defmodule ApiGatewayWeb.AdminHealthController do
  @moduledoc """
  Aggregated system health (admin-only). Pings each reachable service's `/internal/health` over the
  internal API and assembles: the three platform dependencies (Postgres + Kafka from message-service,
  MinIO from media-service), per-service up/down, and an overall healthy/degraded/down. Always returns
  200 with the health payload — a down dependency is data, not an error (so the dashboard renders it).
  Detailed internals stay behind RequireAdmin; the public /health is a separate lightweight liveness.
  """
  use ApiGatewayWeb, :controller

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
        %{name: name, status: service_status(pinged[name])}
      end) ++
        [
          # realtime runs inside THIS gateway process — if we're answering, it's up.
          %{name: "realtime", status: "up"},
          # notification is a consumer with no gateway-reachable health endpoint yet.
          %{name: "notification", status: "unknown"}
        ]

    json(conn, %{
      status: overall(dependencies, services),
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
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

  defp base_url(cfg, env), do: Application.get_env(:shared_infra, cfg) || System.get_env(env)

  # Read a nested value with atom keys; default to an "unknown" status map when absent/unreachable.
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
