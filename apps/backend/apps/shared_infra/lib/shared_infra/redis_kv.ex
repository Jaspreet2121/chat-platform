defmodule SharedInfra.RedisKV do
  @moduledoc """
  Tiny Redis key/value helper for the `/v1` idempotency store (`SET key value EX ttl` + `GET key`).

  `SharedInfra.RateLimiter` is a COUNTER only (INCR/EXPIRE/TTL — integer/simple-string RESP), so it can't
  STORE and return a value. Idempotency needs exactly that, so this adds bulk-string GET on the SAME
  raw-TCP pattern (no new dependency; mirrors the RateLimiter's connect/AUTH/SELECT/encode). One
  short-lived connection per call, same as the RateLimiter — a pool is a later perf optimization.

  Best-effort by contract: callers treat any error as a cache miss / no-op (fail-open). Reuses the
  RateLimiter's Redis URL config (`:shared_infra, :redis` ← `RATE_LIMITER_REDIS_URL`/`REDIS_URL`).
  """

  @doc "SET key value with an expiry in seconds. :ok | {:error, reason}."
  def put(key, value, ttl_seconds)
      when is_binary(key) and key != "" and is_binary(value) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    with_connection(fn conn ->
      case command(conn, ["SET", key, value, "EX", Integer.to_string(ttl_seconds)]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def put(_key, _value, _ttl), do: {:error, :invalid_args}

  @doc """
  SET key value with a TTL AND return the PREVIOUS value atomically (`SET ... EX ttl GET`, Redis 6.2+).

  `{:ok, :was_absent}` when the key did not exist (an offline→online TRANSITION), `{:ok, {:was_present, old}}`
  when it did (a heartbeat refresh — the TTL is still refreshed either way), `{:error, reason}` on failure.
  Lets the caller broadcast a presence change ONLY on the transition, in one round-trip, with no read-modify-
  write race.
  """
  def put_get(key, value, ttl_seconds)
      when is_binary(key) and key != "" and is_binary(value) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    with_connection(fn conn ->
      case command(conn, ["SET", key, value, "EX", Integer.to_string(ttl_seconds), "GET"]) do
        {:ok, :null} -> {:ok, :was_absent}
        {:ok, old} when is_binary(old) -> {:ok, {:was_present, old}}
        {:ok, _other} -> {:ok, :was_absent}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def put_get(_key, _value, _ttl), do: {:error, :invalid_args}

  @doc "GET key. {:ok, value} for a hit, :miss for a nil/absent key, {:error, reason} on failure."
  def get(key) when is_binary(key) and key != "" do
    with_connection(fn conn ->
      case command(conn, ["GET", key]) do
        {:ok, :null} -> :miss
        {:ok, value} when is_binary(value) -> {:ok, value}
        {:ok, _other} -> :miss
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def get(_key), do: {:error, :invalid_args}

  @doc "DEL key. :ok (whether or not it existed) | {:error, reason}."
  def del(key) when is_binary(key) and key != "" do
    with_connection(fn conn ->
      case command(conn, ["DEL", key]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def del(_key), do: {:error, :invalid_args}

  # --- sorted-set primitives (used by the realtime connection counter) -------------------------
  # A sorted set scored by a unix timestamp gives PER-MEMBER expiry: prune members whose score is older
  # than a stale cutoff, so a crashed/leaked socket entry ages out on its own (a plain SET's members share
  # one key TTL and would leak; INCR/DECR can under/over-count on a missed decrement). All ZSET replies are
  # integers, which the existing RESP parser already handles.

  @doc "ZADD key score member, then EXPIRE key ttl (add or refresh a member scored by `score`). :ok | {:error}."
  def zset_touch(key, member, score, ttl_seconds)
      when is_binary(key) and key != "" and is_binary(member) and member != "" and
             is_integer(score) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    with_connection(fn conn ->
      with {:ok, _} <- command(conn, ["ZADD", key, Integer.to_string(score), member]),
           {:ok, _} <- command(conn, ["EXPIRE", key, Integer.to_string(ttl_seconds)]) do
        :ok
      end
    end)
  end

  def zset_touch(_key, _member, _score, _ttl), do: {:error, :invalid_args}

  @doc "Prune members scored below `min_keep` (stale), then ZCARD the survivors. {:ok, count} | {:error}."
  def zset_count(key, min_keep) when is_binary(key) and key != "" and is_integer(min_keep) do
    with_connection(fn conn ->
      with {:ok, _} <-
             command(conn, ["ZREMRANGEBYSCORE", key, "-inf", "(" <> Integer.to_string(min_keep)]),
           {:ok, count} when is_integer(count) <- command(conn, ["ZCARD", key]) do
        {:ok, count}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :unexpected_redis_response}
      end
    end)
  end

  def zset_count(_key, _min_keep), do: {:error, :invalid_args}

  @doc "ZREM key member (drop a member — the immediate decrement on a clean disconnect). :ok | {:error}."
  def zset_remove(key, member)
      when is_binary(key) and key != "" and is_binary(member) and member != "" do
    with_connection(fn conn ->
      case command(conn, ["ZREM", key, member]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def zset_remove(_key, _member), do: {:error, :invalid_args}

  # --- connection ------------------------------------------------------------------------------

  defp with_connection(fun) do
    case connect(redis_url()) do
      {:ok, conn} ->
        result = fun.(conn)
        :gen_tcp.close(conn)
        result

      {:error, reason} ->
        {:error, reason}
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
             [:binary, active: false, packet: :raw],
             timeout()
           ),
         :ok <- maybe_auth(conn, uri.userinfo),
         :ok <- maybe_select_database(conn, uri.path) do
      {:ok, conn}
    end
  end

  defp maybe_auth(_conn, nil), do: :ok
  defp maybe_auth(_conn, ""), do: :ok

  defp maybe_auth(conn, userinfo) do
    creds = userinfo |> String.split(":", parts: 2) |> Enum.map(&URI.decode/1)

    case command(conn, ["AUTH" | creds]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_select_database(_conn, path) when path in [nil, "", "/", "/0"], do: :ok

  defp maybe_select_database(conn, "/" <> database) do
    case Integer.parse(database) do
      {0, ""} ->
        :ok

      {db, ""} when db > 0 ->
        if command(conn, ["SELECT", db]) == {:ok, "OK"},
          do: :ok,
          else: {:error, :invalid_redis_database}

      _ ->
        {:error, :invalid_redis_database}
    end
  end

  # --- RESP ------------------------------------------------------------------------------------

  defp command(conn, args) do
    case :gen_tcp.send(conn, encode(args)) do
      :ok -> read_reply(conn, "")
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode(args) do
    body =
      Enum.map(args, fn part ->
        part = to_string(part)
        ["$", Integer.to_string(byte_size(part)), "\r\n", part, "\r\n"]
      end)

    ["*", Integer.to_string(length(args)), "\r\n", body]
  end

  # Accumulate bytes until a full RESP value parses, then return it. Handles +simple, -error, :int,
  # and $bulk (incl. $-1 nil).
  defp read_reply(conn, buffer) do
    case parse(buffer) do
      {:ok, value, _rest} ->
        {:ok, value}

      {:redis_error, message, _rest} ->
        {:error, message}

      :incomplete ->
        case :gen_tcp.recv(conn, 0, timeout()) do
          {:ok, data} -> read_reply(conn, buffer <> data)
          {:error, reason} -> {:error, reason}
        end

      :unexpected ->
        {:error, :unexpected_redis_response}
    end
  end

  defp parse(<<"+", rest::binary>>), do: with_line(rest, fn line, tail -> {:ok, line, tail} end)

  defp parse(<<"-", rest::binary>>),
    do: with_line(rest, fn line, tail -> {:redis_error, line, tail} end)

  defp parse(<<":", rest::binary>>),
    do: with_line(rest, fn line, tail -> {:ok, String.to_integer(line), tail} end)

  defp parse(<<"$", rest::binary>>), do: parse_bulk(rest)
  defp parse(<<>>), do: :incomplete
  defp parse(_other), do: :unexpected

  defp with_line(bin, fun) do
    case :binary.split(bin, "\r\n") do
      [line, tail] -> fun.(line, tail)
      [_incomplete] -> :incomplete
    end
  end

  defp parse_bulk(bin) do
    case :binary.split(bin, "\r\n") do
      [len_str, tail] ->
        case Integer.parse(len_str) do
          {-1, ""} ->
            {:ok, :null, tail}

          {len, ""} when len >= 0 ->
            case tail do
              # `len` is bound OUTSIDE this match, so it must be pinned — unpinned it reads as a new
              # binding and Elixir 1.18 rejects it under --warnings-as-errors.
              <<data::binary-size(^len), "\r\n", rest::binary>> -> {:ok, data, rest}
              _ -> :incomplete
            end

          _ ->
            :unexpected
        end

      [_incomplete] ->
        :incomplete
    end
  end

  # --- config (same source as SharedInfra.RateLimiter) -----------------------------------------

  defp redis_url do
    :shared_infra |> SharedInfra.Config.Redis.from_app() |> Keyword.fetch!(:url)
  end

  defp timeout do
    :shared_infra |> SharedInfra.Config.Redis.from_app() |> Keyword.get(:timeout, 1_000)
  end
end
