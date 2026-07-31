defmodule ApiGatewayWeb.V1Runtime do
  @moduledoc """
  Runtime for the public `/v1` layer: per-app rate limiting and Idempotency-Key → message memory.

  Backend is selected by `V1_RUNTIME_BACKEND` (default **redis** in prod; `ets` for local/dev without
  Redis, and for the test suite):

    * `:redis` — MULTI-REPLICA-SAFE. Rate limiting reuses `SharedInfra.RateLimiter` (the SAME shared
      counter the OTP path uses: INCR/EXPIRE/TTL on one Redis, so N gateway replicas share ONE limit).
      Idempotency uses `SharedInfra.RedisKV` (SET…EX / GET), so a replayed key returns the same message
      even if the retry lands on a different replica.
    * `:ets` — the previous single-node behaviour (this GenServer's ETS tables); a per-node fallback.

  FALLBACK on a Redis error is **fail-open** (availability over strict enforcement): rate limiting
  ALLOWS the request (never 500s a `/v1` call because Redis blipped — `SharedInfra.RateLimiter` is
  fail-open by default), and idempotency treats it as a miss + best-effort write (a retry during a Redis
  outage may, rarely, not dedupe — never worse than a hard failure). The call sites (`check_rate/1`,
  `idem_get/3`, `idem_put/4`) are unchanged.
  """

  use GenServer

  @rate_table :v1_rate_limit
  @idem_table :v1_idempotency
  @window_seconds 60
  @default_limit 60
  # Idempotency dedupe window — how long a stored message is replayable for a given key.
  @idem_ttl_seconds 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # ETS tables back the :ets fallback backend; harmless to keep even when :redis is active.
    :ets.new(@rate_table, [:named_table, :public, :set, write_concurrency: true])

    # Broadcast-send single-flight locks (one in-flight fan-out per user; see BroadcastController).
    # Owned HERE so the table survives a request process dying mid-fan-out (entries are stale-swept).
    :ets.new(:broadcast_send_locks, [:named_table, :public, :set])

    :ets.new(@idem_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc "Per-app rate limit. :ok | {:error, :rate_limited, retry_after_seconds}."
  def check_rate(app_id) do
    case backend() do
      :redis -> check_rate_redis(app_id)
      :ets -> check_rate_ets(app_id)
    end
  end

  @doc "Return the message stored for a (app_id, conversation_id, idempotency_key), or :miss."
  def idem_get(app_id, conversation_id, idempotency_key) do
    case backend() do
      :redis -> idem_get_redis(app_id, conversation_id, idempotency_key)
      :ets -> idem_get_ets(app_id, conversation_id, idempotency_key)
    end
  end

  @doc "Remember the message produced for an idempotency key (so a retry returns the SAME message)."
  def idem_put(app_id, conversation_id, idempotency_key, message) do
    case backend() do
      :redis -> idem_put_redis(app_id, conversation_id, idempotency_key, message)
      :ets -> idem_put_ets(app_id, conversation_id, idempotency_key, message)
    end
  end

  # --- Redis backend (multi-replica-safe) ------------------------------------------------------

  defp check_rate_redis(app_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => rate_key(app_id),
           "limit" => limit(),
           "window_seconds" => @window_seconds
         }) do
      :ok ->
        :ok

      {:error, :rate_limited, retry_after_seconds} ->
        {:error, :rate_limited, retry_after_seconds}

      # Redis unreachable / any other error → FAIL-OPEN (allow the request; don't 500 /v1).
      _other ->
        :ok
    end
  end

  defp idem_get_redis(app_id, conversation_id, idempotency_key) do
    case SharedInfra.RedisKV.get(idem_key(app_id, conversation_id, idempotency_key)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, message} -> {:ok, message}
          # Corrupt value → treat as a miss (re-send); never crash the request.
          _ -> :miss
        end

      # :miss OR any Redis error → miss (fail-open: proceed to send).
      _ ->
        :miss
    end
  end

  defp idem_put_redis(app_id, conversation_id, idempotency_key, message) do
    # Best-effort: a failed write just means a future retry won't dedupe. Never fails the request.
    SharedInfra.RedisKV.put(
      idem_key(app_id, conversation_id, idempotency_key),
      Jason.encode!(message),
      @idem_ttl_seconds
    )

    :ok
  end

  # --- ETS backend (single-node fallback) ------------------------------------------------------

  defp check_rate_ets(app_id) do
    now = System.system_time(:second)
    bucket = div(now, @window_seconds)
    key = {app_id, bucket}
    count = :ets.update_counter(@rate_table, key, {2, 1}, {key, 0})

    if count > limit() do
      {:error, :rate_limited, (bucket + 1) * @window_seconds - now}
    else
      :ok
    end
  end

  defp idem_get_ets(app_id, conversation_id, idempotency_key) do
    case :ets.lookup(@idem_table, {app_id, conversation_id, idempotency_key}) do
      [{_key, message}] -> {:ok, message}
      _ -> :miss
    end
  end

  defp idem_put_ets(app_id, conversation_id, idempotency_key, message) do
    :ets.insert(@idem_table, {{app_id, conversation_id, idempotency_key}, message})
    :ok
  end

  # --- keys / config ---------------------------------------------------------------------------

  defp rate_key(app_id), do: "v1:rate:#{app_id}"
  defp idem_key(app_id, conversation_id, key), do: "v1:idem:#{app_id}:#{conversation_id}:#{key}"

  defp backend do
    case System.get_env("V1_RUNTIME_BACKEND") do
      "ets" -> :ets
      "redis" -> :redis
      _ -> :redis
    end
  end

  # Runtime-configurable so a deployment (or a test) can tune the /v1 ceiling without a recompile.
  defp limit do
    case System.get_env("V1_RATE_LIMIT") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> @default_limit
        end

      _ ->
        @default_limit
    end
  end
end
