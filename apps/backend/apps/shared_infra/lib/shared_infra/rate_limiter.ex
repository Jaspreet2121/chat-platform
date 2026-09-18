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

  @typedoc """
  The same decision as `t:result/0`, but carrying the COUNT and keeping "the limiter could not be
  reached" distinct from "this key is over its limit".

  `check_rate/1` collapses those two into one `{:error, …}`, which is correct for a caller that only
  wants allow-or-deny — and was actively harmful for one that has to LOG which happened. A stranger's
  first message was refused in production for weeks because an unreachable Redis and a spent budget
  were the same value, the same HTTP status and the same absent log line.
  """
  @type detailed ::
          {:allow, non_neg_integer() | nil}
          | {:refuse, non_neg_integer() | nil, non_neg_integer()}
          | {:unavailable, term()}

  @callback check_rate(attrs()) :: result()

  @doc """
  OPTIONAL. An adapter that can report the counter implements this; one that cannot is projected from
  `check_rate/1` with a nil count, so every existing adapter and test stub keeps working untouched.
  """
  @callback check_rate_detailed(attrs()) :: detailed()
  @optional_callbacks check_rate_detailed: 1

  def check_rate(attrs) when is_map(attrs) do
    with {:ok, key} <- required_attr(attrs, "key"),
         {:ok, limit} <- positive_integer(attrs, "limit"),
         {:ok, window_seconds} <- positive_integer(attrs, "window_seconds") do
      adapter().check_rate(%{
        "key" => key,
        "limit" => limit,
        "window_seconds" => window_seconds,
        "now_seconds" => now_seconds(attrs),
        # Optional per-call override of the global fail-open policy. Endpoints where the limit is a
        # SECURITY control (e.g. contacts sync, the enumeration oracle) pass `false` so a limiter outage
        # rejects rather than silently opening the gate; omitting it keeps the global default.
        "fail_open" => fail_open_override(attrs)
      })
    end
  end

  def check_rate(_attrs), do: {:error, :rate_limit_invalid}

  @doc """
  `{:allow, used}` | `{:refuse, used, retry_after}` | `{:unavailable, reason}`.

  NOTE THE MISSING PARAMETER: this never applies fail-open or fail-closed. It reports what happened
  and the CALLER decides, which is the whole point — a policy applied inside here is a policy the
  caller cannot log, and an unloggable policy is how the stranger-budget outage stayed invisible.
  """
  def check_rate_detailed(attrs) when is_map(attrs) do
    with {:ok, key} <- required_attr(attrs, "key"),
         {:ok, limit} <- positive_integer(attrs, "limit"),
         {:ok, window_seconds} <- positive_integer(attrs, "window_seconds") do
      normalised = %{
        "key" => key,
        "limit" => limit,
        "window_seconds" => window_seconds,
        "now_seconds" => now_seconds(attrs),
        # Deliberately fail-CLOSED on the way in, whatever the caller's policy is: this function must
        # be TOLD the limiter was unreachable so it can say so. The caller then chooses.
        "fail_open" => false
      }

      detailed(adapter(), normalised)
    else
      other -> {:unavailable, other}
    end
  end

  def check_rate_detailed(_attrs), do: {:unavailable, {:error, :rate_limit_invalid}}

  defp detailed(adapter, attrs) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :check_rate_detailed, 1) do
      adapter.check_rate_detailed(attrs)
    else
      # Projection for an adapter that cannot count — a test stub, or a future adapter. The decision
      # is identical; only `used` is unknown, and nil says so rather than guessing zero.
      case adapter.check_rate(attrs) do
        :ok -> {:allow, nil}
        {:error, :rate_limited, retry} -> {:refuse, nil, retry}
        other -> {:unavailable, other}
      end
    end
  end

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

  # nil when not specified → the adapter uses the global default; a boolean overrides it for this call.
  # NOT `get_attr/2` (`false || x` drops the literal `false` that matters here — fail CLOSED); the
  # presence-based SharedInfra.Attrs.get keeps it.
  defp fail_open_override(attrs) do
    case SharedInfra.Attrs.get(attrs, :fail_open) do
      value when is_boolean(value) -> value
      _ -> nil
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
    case measure(attrs) do
      {:allow, _used} -> :ok
      {:refuse, _used, retry} -> {:error, :rate_limited, retry}
    end
  end

  defp measure_body(attrs) do
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
          {:allow, updated_bucket.count}
        else
          {:refuse, updated_bucket.count, retry_after_seconds}
        end

      {result, updated_state}
    end)
  end

  # Same counter, same decision, reported in the richer shape. Implemented here and not only on the
  # Redis adapter so a test proving a "used=N of 3" log line is proving the real number rather than
  # the nil a projection would hand it.
  @impl true
  def check_rate_detailed(attrs), do: measure(attrs)

  defp measure(attrs), do: measure_body(attrs)

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

  # UNLINKED on purpose. This lazy-start runs inside whatever process first calls the adapter — in
  # tests, a TEST PROCESS. `Agent.start_link` would tie the shared agent's life to that test: the agent
  # dies with it, and the next caller races the death (whereis says alive, the call says no process).
  # That race produced real CI flakes ("join crashed" in channels_test; sandbox checkout deaths). An
  # explicitly supervised start_link/1 remains available for supervision trees.
  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> %{} end, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end

defmodule SharedInfra.RateLimiter.RedisAdapter do
  @moduledoc """
  Redis-backed rate limiter adapter.

  Runs on `SharedInfra.Redis.Pool` when a service has started it (the gateway does), falling back
  to a one-shot TCP connection per call where it has not. The counter pattern is the same on both:

  - `INCR rate_limit:<key>`
  - `EXPIRE rate_limit:<key> <window_seconds>` when the counter is created
  - `TTL rate_limit:<key>` when calculating retry-after
  """

  @behaviour SharedInfra.RateLimiter

  @impl true
  def check_rate(attrs) do
    attrs
    |> check_rate_detailed()
    |> project(fail_open?(attrs))
  end

  # ONE PLACE decides fail-open, and it is here, at the very edge — not scattered through the
  # connect path and the command path as it was. The detailed result below never applies a policy;
  # it reports.
  defp project({:allow, _used}, _fail_open), do: :ok
  defp project({:refuse, _used, retry}, _fail_open), do: {:error, :rate_limited, retry}
  defp project({:unavailable, _reason}, true), do: :ok
  defp project({:unavailable, reason}, false), do: {:error, :rate_limiter_unavailable, reason}

  @impl true
  def check_rate_detailed(attrs) do
    key = redis_key(attrs)
    limit = Map.fetch!(attrs, "limit")
    window_seconds = Map.fetch!(attrs, "window_seconds")

    # THE POOL, not a connection per check: every check used to connect, AUTH, SELECT, INCR,
    # EXPIRE and close (≈0.8 ms of pure TCP setup per call, locally). On the pool the same three
    # commands ride a persistent socket. A node that has not started the pool (a service that
    # never listed it) still works — one-shot, as before.
    if SharedInfra.Redis.Pool.started?() do
      measure(:pool, key, limit, window_seconds)
    else
      case connect(redis_url()) do
        {:ok, conn} ->
          result = measure(conn, key, limit, window_seconds)
          :gen_tcp.close(conn)
          result

        {:error, reason} ->
          {:unavailable, reason}
      end
    end
  end

  defp measure(conn, key, limit, window_seconds) do
    with {:ok, count} <- redis_command(conn, ["INCR", key]),
         :ok <- maybe_expire(conn, key, count, window_seconds) do
      rate_result(conn, key, count, limit, window_seconds)
    else
      {:error, reason} -> {:unavailable, reason}
    end
  end

  defp maybe_expire(conn, key, 1, window_seconds) do
    case redis_command(conn, ["EXPIRE", key, window_seconds]) do
      {:ok, _expired} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_expire(_conn, _key, _count, _window_seconds), do: :ok

  # THE COUNT IS THE VALUE INCR JUST RETURNED, so `used` is exactly how many this key has spent
  # INCLUDING this call — the number a "used=N of 3" log line has to show. `count <= limit` is the
  # allow test, so the first call on a fresh key is count=1 against limit=3 and is allowed. There is
  # no off-by-one here and never was; the production refusal came from the connect path above.
  defp rate_result(_conn, _key, count, limit, _window_seconds) when count <= limit,
    do: {:allow, count}

  defp rate_result(conn, key, count, _limit, window_seconds) do
    retry_after_seconds =
      case redis_command(conn, ["TTL", key]) do
        {:ok, ttl} when is_integer(ttl) and ttl > 0 -> ttl
        _ -> window_seconds
      end

    {:refuse, count, retry_after_seconds}
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

  defp redis_command(:pool, command), do: SharedInfra.Redis.Pool.command(command)

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

  # Per-call override (a boolean in attrs) wins; otherwise the global default (true unless configured).
  defp fail_open?(attrs) do
    case Map.get(attrs, "fail_open") do
      value when is_boolean(value) -> value
      _ -> Application.get_env(:shared_infra, :rate_limiter_fail_open, true)
    end
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
