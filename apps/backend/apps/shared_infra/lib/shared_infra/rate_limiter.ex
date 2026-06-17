defmodule SharedInfra.RateLimiter do
  @moduledoc """
  Small key-based rate limiting boundary.

  Live Redis execution is intentionally outside this module until a concrete
  Redis client adapter is configured.
  """

  @type attrs :: map()
  @type result ::
          :ok
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, atom()}
          | {:error, atom(), term()}

  @callback check_rate(attrs()) :: result()

  def check_rate(attrs) when is_map(attrs) do
    with {:ok, key} <- required_attr(attrs, "key"),
         {:ok, limit} <- positive_integer(attrs, "limit"),
         {:ok, window_seconds} <- positive_integer(attrs, "window_seconds") do
      adapter().check_rate(%{
        "key" => key,
        "limit" => limit,
        "window_seconds" => window_seconds,
        "now_seconds" => now_seconds(attrs)
      })
    end
  end

  def check_rate(_attrs), do: {:error, :rate_limit_invalid}

  defp adapter do
    Application.get_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.RedisAdapter
    )
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :rate_limit_invalid}
    end
  end

  defp positive_integer(attrs, key) do
    case get_attr(attrs, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value)
      _ -> {:error, :rate_limit_invalid}
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :rate_limit_invalid}
    end
  end

  defp now_seconds(attrs) do
    case get_attr(attrs, "now_seconds") do
      value when is_integer(value) -> value
      _ -> System.system_time(:second)
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
end

defmodule SharedInfra.RateLimiter.InMemoryAdapter do
  @moduledoc """
  Test-safe in-memory rate limiter adapter.
  """

  @behaviour SharedInfra.RateLimiter

  use Agent

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: @name)
  end

  def reset do
    ensure_started()
    Agent.update(@name, fn _state -> %{} end)
  end

  @impl true
  def check_rate(attrs) do
    ensure_started()

    key = Map.fetch!(attrs, "key")
    limit = Map.fetch!(attrs, "limit")
    window_seconds = Map.fetch!(attrs, "window_seconds")
    now_seconds = Map.fetch!(attrs, "now_seconds")

    Agent.get_and_update(@name, fn state ->
      bucket = current_bucket(Map.get(state, key), now_seconds, window_seconds)
      updated_bucket = %{bucket | count: bucket.count + 1}
      retry_after_seconds = retry_after_seconds(updated_bucket, now_seconds, window_seconds)
      updated_state = Map.put(state, key, updated_bucket)

      result =
        if updated_bucket.count <= limit do
          :ok
        else
          {:error, :rate_limited, retry_after_seconds}
        end

      {result, updated_state}
    end)
  end

  defp current_bucket(nil, now_seconds, _window_seconds) do
    %{window_start: now_seconds, count: 0}
  end

  defp current_bucket(%{window_start: window_start} = bucket, now_seconds, window_seconds)
       when now_seconds - window_start < window_seconds do
    bucket
  end

  defp current_bucket(_bucket, now_seconds, _window_seconds) do
    %{window_start: now_seconds, count: 0}
  end

  defp retry_after_seconds(%{window_start: window_start}, now_seconds, window_seconds) do
    max(window_seconds - (now_seconds - window_start), 1)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = start_link()
        :ok

      _pid ->
        :ok
    end
  end
end

defmodule SharedInfra.RateLimiter.RedisAdapter do
  @moduledoc """
  Redis-backed rate limiter adapter.

  Uses a small direct Redis TCP command client for the simple counter pattern:

  - `INCR rate_limit:<key>`
  - `EXPIRE rate_limit:<key> <window_seconds>` when the counter is created
  - `TTL rate_limit:<key>` when calculating retry-after
  """

  @behaviour SharedInfra.RateLimiter

  @impl true
  def check_rate(attrs) do
    key = redis_key(attrs)
    limit = Map.fetch!(attrs, "limit")
    window_seconds = Map.fetch!(attrs, "window_seconds")

    with_connection(fn conn ->
      check_rate_with_connection(conn, key, limit, window_seconds)
    end)
  end

  defp check_rate_with_connection(conn, key, limit, window_seconds) do
    with {:ok, count} <- redis_command(conn, ["INCR", key]),
         :ok <- maybe_expire(conn, key, count, window_seconds) do
      rate_result(conn, key, count, limit, window_seconds)
    else
      {:error, reason} ->
        handle_unavailable(reason)
    end
  end

  defp maybe_expire(conn, key, 1, window_seconds) do
    case redis_command(conn, ["EXPIRE", key, window_seconds]) do
      {:ok, _expired} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_expire(_conn, _key, _count, _window_seconds), do: :ok

  defp rate_result(_conn, _key, count, limit, _window_seconds) when count <= limit, do: :ok

  defp rate_result(conn, key, _count, _limit, window_seconds) do
    retry_after_seconds =
      case redis_command(conn, ["TTL", key]) do
        {:ok, ttl} when is_integer(ttl) and ttl > 0 -> ttl
        _ -> window_seconds
      end

    {:error, :rate_limited, retry_after_seconds}
  end

  defp with_connection(fun) do
    redis_url()
    |> connect()
    |> case do
      {:ok, conn} ->
        result = fun.(conn)
        :gen_tcp.close(conn)
        result

      {:error, reason} ->
        handle_unavailable(reason)
    end
  end

  defp connect(url) do
    uri = URI.parse(url)
    host = uri.host || "localhost"
    port = uri.port || 6379

    with {:ok, conn} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, active: false, packet: :line],
             redis_timeout()
           ),
         :ok <- maybe_auth(conn, uri.userinfo),
         :ok <- maybe_select_database(conn, uri.path) do
      {:ok, conn}
    end
  end

  defp maybe_auth(_conn, nil), do: :ok
  defp maybe_auth(_conn, ""), do: :ok

  defp maybe_auth(conn, userinfo) do
    userinfo
    |> String.split(":", parts: 2)
    |> case do
      [password] -> redis_ok(conn, ["AUTH", URI.decode(password)])
      [username, password] -> redis_ok(conn, ["AUTH", URI.decode(username), URI.decode(password)])
    end
  end

  defp maybe_select_database(_conn, nil), do: :ok
  defp maybe_select_database(_conn, "/"), do: :ok
  defp maybe_select_database(_conn, "/0"), do: :ok

  defp maybe_select_database(conn, "/" <> database) do
    case Integer.parse(database) do
      {0, ""} -> :ok
      {db, ""} when db > 0 -> redis_ok(conn, ["SELECT", db])
      _ -> {:error, :invalid_redis_database}
    end
  end

  defp redis_ok(conn, command) do
    case redis_command(conn, command) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp redis_command(conn, command) do
    with :ok <- :gen_tcp.send(conn, encode_command(command)),
         {:ok, response} <- :gen_tcp.recv(conn, 0, redis_timeout()) do
      parse_response(response)
    end
  end

  defp encode_command(command) do
    [
      "*",
      Integer.to_string(length(command)),
      "\r\n",
      Enum.map(command, fn part ->
        part = to_string(part)
        ["$", Integer.to_string(byte_size(part)), "\r\n", part, "\r\n"]
      end)
    ]
  end

  defp parse_response(":" <> value), do: parse_integer_response(value)
  defp parse_response("+" <> value), do: {:ok, String.trim(value)}
  defp parse_response("-" <> value), do: {:error, String.trim(value)}
  defp parse_response(_response), do: {:error, :unexpected_redis_response}

  defp parse_integer_response(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :unexpected_redis_response}
    end
  end

  defp handle_unavailable(reason) do
    if fail_open?() do
      :ok
    else
      {:error, :rate_limiter_unavailable, reason}
    end
  end

  defp redis_key(attrs), do: "rate_limit:#{attrs["key"]}"

  defp redis_url do
    :shared_infra
    |> SharedInfra.Config.Redis.from_app()
    |> Keyword.fetch!(:url)
  end

  defp redis_timeout do
    :shared_infra
    |> SharedInfra.Config.Redis.from_app()
    |> Keyword.get(:timeout, 1_000)
  end

  defp fail_open? do
    Application.get_env(:shared_infra, :rate_limiter_fail_open, true)
  end
end

defmodule SharedInfra.RateLimiter.RedisQueryPlanAdapter do
  @moduledoc """
  Redis rate limiter query-plan adapter.

  This keeps the intended Redis command shape visible in Docker-free tests
  without requiring a live Redis process.
  """

  @behaviour SharedInfra.RateLimiter

  @impl true
  def check_rate(attrs) do
    {:error, :rate_limiter_unavailable, query_plan(attrs)}
  end

  def query_plan(attrs) do
    key = "rate_limit:#{attrs["key"]}"
    window_seconds = attrs["window_seconds"]

    [
      ["INCR", key],
      ["EXPIRE", key, window_seconds]
    ]
  end
end
