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
      {0, ""} -> :ok
      {db, ""} when db > 0 -> if command(conn, ["SELECT", db]) == {:ok, "OK"}, do: :ok, else: {:error, :invalid_redis_database}
      _ -> {:error, :invalid_redis_database}
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
    body = Enum.map(args, fn part ->
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
  defp parse(<<"-", rest::binary>>), do: with_line(rest, fn line, tail -> {:redis_error, line, tail} end)

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
              <<data::binary-size(len), "\r\n", rest::binary>> -> {:ok, data, rest}
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
