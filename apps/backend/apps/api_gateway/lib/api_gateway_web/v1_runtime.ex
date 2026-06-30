defmodule ApiGatewayWeb.V1Runtime do
  @moduledoc """
  In-process runtime for the public `/v1` layer: per-app rate limiting (fixed-window token bucket) and
  Idempotency-Key → message memory. Backed by ETS owned by this supervised process.

  NOTE (prod-grade swap point): these are in-memory + single-node. A production deployment replaces
  them with a SHARED store so limits + dedupe hold across gateway replicas and restarts — a Redis token
  bucket for rate limiting, and a unique (app_id, idempotency_key) row (or Redis SETNX) for idempotency.
  The call sites (`check_rate/1`, `idem_get/3`, `idem_put/4`) stay identical.
  """

  use GenServer

  @rate_table :v1_rate_limit
  @idem_table :v1_idempotency
  @window_seconds 60
  @default_limit 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@rate_table, [:named_table, :public, :set, write_concurrency: true])

    :ets.new(@idem_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc "Fixed-window token bucket keyed by app_id. :ok | {:error, :rate_limited, retry_after_seconds}."
  def check_rate(app_id) do
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

  @doc "Return the message stored for a (app_id, conversation_id, idempotency_key), or :miss."
  def idem_get(app_id, conversation_id, idempotency_key) do
    case :ets.lookup(@idem_table, {app_id, conversation_id, idempotency_key}) do
      [{_key, message}] -> {:ok, message}
      _ -> :miss
    end
  end

  @doc "Remember the message produced for an idempotency key (so a retry returns the SAME message)."
  def idem_put(app_id, conversation_id, idempotency_key, message) do
    :ets.insert(@idem_table, {{app_id, conversation_id, idempotency_key}, message})
    :ok
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
