defmodule RealtimeGateway.ConnectionCounter do
  @moduledoc """
  Counts CONCURRENT sockets per user and per app for the `/socket` connection cap.

  A concurrent count needs increment-on-connect + decrement-on-disconnect. Phoenix has no socket-level
  terminate, so a decrement can be MISSED (crash, network drop, node restart) — a counter that only goes up
  would lock a user out permanently. So instead each socket is a MEMBER of a sorted set scored by its
  last-seen unix second: a socket refreshes its score on a heartbeat, and `count/2` prunes members older
  than the stale window before counting. A missed decrement therefore self-heals: the entry ages out of the
  window on its own. A clean disconnect still `remove/2`s immediately (the fast path); the aging is the
  safety net. NO permanent leak, at the cost of freeing a truly-dead slot up to `ttl` seconds late.

  Backend is `:ets` (single node / dev / tests — in-process, deterministic) or `:redis` (multi-node — a
  shared sorted set), chosen exactly like V1Runtime's :redis|:ets: `RT_RUNTIME_BACKEND` env, default redis.
  Redis is FAIL-OPEN: any Redis error → count 0 / touch no-op → the connection is ALLOWED (a rate limiter
  must never take down the service it guards).
  """

  @table :rt_connection_counter

  @doc "Live members of `scope_key` (those seen within the stale window ending at `now`). Fail-open → 0."
  @spec count(String.t(), integer()) :: non_neg_integer()
  def count(scope_key, now) do
    min_keep = now - ttl_seconds()

    case backend() do
      :ets -> ets_count(scope_key, min_keep)
      :redis -> redis_count(scope_key, min_keep)
    end
  end

  @doc "Add/refresh `member` in `scope_key` scored at `now`. Best-effort (fail-open)."
  @spec touch(String.t(), String.t(), integer()) :: :ok
  def touch(scope_key, member, now) do
    case backend() do
      :ets -> ets_touch(scope_key, member, now)
      :redis -> redis_touch(scope_key, member, now)
    end

    :ok
  end

  @doc "Drop `member` from `scope_key` — the immediate decrement on a clean disconnect. Best-effort."
  @spec remove(String.t(), String.t()) :: :ok
  def remove(scope_key, member) do
    case backend() do
      :ets -> ets_remove(scope_key, member)
      :redis -> SharedInfra.RedisKV.zset_remove(scope_key, member)
    end

    :ok
  end

  @doc "The stale window / TTL in seconds (also the Redis key EXPIRE). RT_CONN_TTL_SECONDS, default 120."
  def ttl_seconds do
    parse_pos(System.get_env("RT_CONN_TTL_SECONDS"), 120)
  end

  # --- ETS backend (in-process; the owner is RealtimeGateway.ConnectionCounter.Table) --------------

  defp ets_touch(scope_key, member, now) do
    ensure_table()
    :ets.insert(@table, {{scope_key, member}, now})
  end

  defp ets_remove(scope_key, member) do
    ensure_table()
    :ets.delete(@table, {scope_key, member})
  end

  defp ets_count(scope_key, min_keep) do
    ensure_table()
    # Prune this key's stale members, then count the fresh survivors.
    :ets.select_delete(@table, [{{{scope_key, :_}, :"$1"}, [{:<, :"$1", min_keep}], [true]}])
    :ets.select_count(@table, [{{{scope_key, :_}, :"$1"}, [{:>=, :"$1", min_keep}], [true]}])
  end

  # The supervised Table owns the ETS table; ensure it exists even if a test calls before boot.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def __table__, do: @table

  # --- Redis backend (multi-node; fail-open) -------------------------------------------------------

  defp redis_count(scope_key, min_keep) do
    case SharedInfra.RedisKV.zset_count(scope_key, min_keep) do
      {:ok, count} when is_integer(count) -> count
      # Fail-open: Redis unreachable → count 0 → ALLOW (same posture as /v1).
      _ -> 0
    end
  end

  defp redis_touch(scope_key, member, now) do
    SharedInfra.RedisKV.zset_touch(scope_key, member, now, ttl_seconds())
  end

  defp backend do
    case System.get_env("RT_RUNTIME_BACKEND") do
      "ets" -> :ets
      "redis" -> :redis
      _ -> Application.get_env(:realtime_gateway, :connection_counter_backend, :redis)
    end
  end

  defp parse_pos(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos(_value, default), do: default
end
