defmodule SharedInfra.Health do
  @moduledoc """
  Defensive dependency probes for health checks. Every probe is timeout-bounded and exception-safe —
  a down/unreachable dependency returns `%{status: "down", latency_ms, error}`, it never hangs the
  caller or crashes. Returns plain maps so they serialize straight to JSON.

  shared_infra does NOT depend on the service Repos; `postgres/2` takes the repo MODULE as an argument
  and just calls `repo.query/3`, so each service passes its own Repo.
  """

  @default_timeout 2_000

  @doc "Pings Postgres via `SELECT 1` through the given Repo module."
  def postgres(repo, timeout \\ @default_timeout) do
    timed(fn ->
      case repo.query("SELECT 1", [], timeout: timeout) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  @doc "Reachability probe for Kafka — a TCP connect to the first broker (connection-level, not a full metadata fetch)."
  def kafka(brokers, timeout \\ @default_timeout) when is_binary(brokers) do
    {host, port} = first_broker(brokers)
    tcp(host, port, timeout)
  end

  @doc "TCP connect probe (host:port reachable within the timeout)."
  def tcp(host, port, timeout \\ @default_timeout) do
    timed(fn ->
      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :ok

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end)
  end

  @doc "HTTP GET probe — 2xx = up. Used for MinIO's health endpoint and any HTTP dependency."
  def http_ok(url, timeout \\ @default_timeout) do
    timed(fn ->
      case Req.get(url, receive_timeout: timeout, retry: false, connect_options: [timeout: timeout]) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, "http #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  # Measures latency and normalizes any outcome (incl. raised exceptions / exits) to a status map.
  defp timed(fun) do
    start = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      rescue
        error -> {:error, inspect(error)}
      catch
        kind, value -> {:error, inspect({kind, value})}
      end

    latency = System.monotonic_time(:millisecond) - start

    case result do
      :ok -> %{status: "up", latency_ms: latency, error: nil}
      {:error, reason} -> %{status: "down", latency_ms: latency, error: to_string(reason)}
    end
  end

  defp first_broker(brokers) do
    brokers
    |> String.split(",", trim: true)
    |> List.first("localhost:9092")
    |> String.split(":", parts: 2)
    |> case do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 9092}
    end
  end
end
