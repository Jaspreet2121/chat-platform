defmodule SharedInfra.Redis.Pool do
  @moduledoc """
  A small pool of PERSISTENT Redis connections (no new dependency): N supervised workers, each
  owning one `:gen_tcp` socket that is opened lazily on first use and kept open across calls.
  Callers pick a worker round-robin and run one RESP command on it.

  THE GAP THIS CLOSES: every rate-limit check used to open a fresh TCP connection (connect, AUTH,
  SELECT, INCR, EXPIRE, close) — `SharedInfra.RateLimiter.RedisAdapter.with_connection/2` — and
  `SharedInfra.RedisKV` did the same; there was no pool anywhere (`SharedInfra.Redis.Client` is an
  interface only). BOTH now run on this pool — the limiter since f420539, RedisKV since 2026-09-18.

  RedisKV is why the worker speaks FULL RESP rather than the limiter's integers and simple strings:
  its GET returns a BULK string, whose payload may legally contain \r\n. The socket is therefore
  `packet: :raw` and the reader counts bytes; line framing would cut such a value in half.

  Lifecycle: started by a service's application (`{SharedInfra.Redis.Pool, size: 4}`); a second
  start under the same node (two apps of one release both listing it) is `:ignore`d rather than
  crashing the second supervisor. A worker that hits a socket error closes it, answers the error
  and reconnects on the next command — never a crash loop against a down Redis. Any caller that
  runs where the pool is NOT started gets `{:error, :pool_not_started}` and may fall back.
  """

  use Supervisor

  @default_size 4

  def start_link(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      _pid -> :ignore
    end
  end

  @impl true
  def init(opts) do
    size = Keyword.get(opts, :size) || configured_size()

    children =
      for i <- 1..size do
        Supervisor.child_spec({__MODULE__.Worker, name: worker_name(i)}, id: {:redis_worker, i})
      end

    :persistent_term.put({__MODULE__, :size}, size)
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Whether the pool is running on this node."
  def started?, do: Process.whereis(__MODULE__) != nil

  @doc "The number of workers (0 when not started)."
  def size do
    if started?(), do: :persistent_term.get({__MODULE__, :size}, 0), else: 0
  end

  @doc """
  Run ONE command on a pooled connection → `{:ok, reply} | {:error, reason}`. The full RESP value
  set the two callers need: integers (the limiter's INCR/EXPIRE/TTL), simple strings (+OK), errors,
  and BULK strings including the `$-1` miss, which answers `{:ok, :null}` rather than an error —
  RedisKV's GET reports "not found" that way.
  """
  def command(command, timeout \\ nil) when is_list(command) do
    case size() do
      0 ->
        {:error, :pool_not_started}

      n ->
        index = rem(System.unique_integer([:positive, :monotonic]), n) + 1
        GenServer.call(worker_name(index), {:command, command}, timeout || call_timeout())
    end
  catch
    :exit, reason -> {:error, {:pool_exit, reason}}
  end

  @doc """
  Close every worker's socket (they reopen lazily on the next command). For a Redis URL change at
  runtime, and for tests that point the pool at a different server.
  """
  def disconnect_all do
    for i <- 1..size()//1, do: GenServer.call(worker_name(i), :disconnect)
    :ok
  end

  defp worker_name(i), do: Module.concat(__MODULE__, "Worker#{i}")

  defp configured_size do
    Application.get_env(:shared_infra, :redis_pool_size, @default_size)
  end

  defp call_timeout do
    :shared_infra
    |> SharedInfra.Config.Redis.from_app()
    |> Keyword.get(:timeout, 1_000)
    |> Kernel.+(500)
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(_opts), do: {:ok, %{socket: nil}}

    @impl true
    def handle_call({:command, command}, _from, state) do
      case ensure_connected(state) do
        {:ok, socket} ->
          case send_command(socket, command) do
            {:ok, reply} ->
              {:reply, {:ok, reply}, %{state | socket: socket}}

            # A dead socket answers the error and is dropped; the NEXT command reconnects.
            {:error, reason} ->
              :gen_tcp.close(socket)
              {:reply, {:error, reason}, %{state | socket: nil}}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | socket: nil}}
      end
    end

    @impl true
    def handle_call(:disconnect, _from, %{socket: socket} = state) do
      if is_port(socket), do: :gen_tcp.close(socket)
      {:reply, :ok, %{state | socket: nil}}
    end

    defp ensure_connected(%{socket: socket}) when is_port(socket), do: {:ok, socket}
    defp ensure_connected(_state), do: connect(redis_url())

    # --- the same wire code the one-shot adapter used ---------------------------------------------

    defp connect(url) do
      uri = URI.parse(url)
      host = uri.host || "localhost"
      port = uri.port || 6379

      with {:ok, socket} <-
             :gen_tcp.connect(
               String.to_charlist(host),
               port,
               # :raw, NOT :line — a BULK STRING's payload may contain \r\n, and line framing would cut
               # a value in half. The reader below counts bytes instead.
               [:binary, active: false, packet: :raw],
               timeout()
             ),
           :ok <- maybe_auth(socket, uri.userinfo),
           :ok <- maybe_select_database(socket, uri.path) do
        {:ok, socket}
      else
        {:error, reason} = error ->
          _ = reason
          error
      end
    end

    defp maybe_auth(_socket, nil), do: :ok
    defp maybe_auth(_socket, ""), do: :ok

    defp maybe_auth(socket, userinfo) do
      case String.split(userinfo, ":", parts: 2) do
        [password] -> ok(socket, ["AUTH", URI.decode(password)])
        [username, password] -> ok(socket, ["AUTH", URI.decode(username), URI.decode(password)])
      end
    end

    defp maybe_select_database(_socket, path) when path in [nil, "", "/", "/0"], do: :ok

    defp maybe_select_database(socket, "/" <> database) do
      case Integer.parse(database) do
        {0, ""} -> :ok
        {db, ""} when db > 0 -> ok(socket, ["SELECT", db])
        _ -> {:error, :invalid_redis_database}
      end
    end

    defp ok(socket, command) do
      case send_command(socket, command) do
        {:ok, _reply} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp send_command(socket, command) do
      with :ok <- :gen_tcp.send(socket, encode(command)) do
        read_reply(socket, "")
      end
    end

    # Accumulate until a COMPLETE RESP value parses. The one-shot clients do the same; the pool has
    # to, because it now carries bulk strings (RedisKV's GET) as well as the limiter's integers, and
    # a bulk reply can arrive across several packets.
    defp read_reply(socket, buffer) do
      case parse(buffer) do
        {:ok, value, _rest} ->
          {:ok, value}

        {:redis_error, message, _rest} ->
          {:error, message}

        :incomplete ->
          case :gen_tcp.recv(socket, 0, timeout()) do
            {:ok, data} -> read_reply(socket, buffer <> data)
            {:error, reason} -> {:error, reason}
          end

        :unexpected ->
          {:error, :unexpected_redis_response}
      end
    end

    defp encode(command) do
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

    defp parse(<<"+", rest::binary>>), do: with_line(rest, fn line, tail -> {:ok, line, tail} end)

    defp parse(<<"-", rest::binary>>),
      do: with_line(rest, fn line, tail -> {:redis_error, line, tail} end)

    defp parse(<<":", rest::binary>>) do
      with_line(rest, fn line, tail ->
        case Integer.parse(line) do
          {integer, ""} -> {:ok, integer, tail}
          _ -> :unexpected
        end
      end)
    end

    defp parse(<<"$", rest::binary>>), do: parse_bulk(rest)
    defp parse(<<>>), do: :incomplete
    defp parse(_other), do: :unexpected

    defp with_line(bin, fun) do
      case :binary.split(bin, "\r\n") do
        [line, tail] -> fun.(line, tail)
        [_incomplete] -> :incomplete
      end
    end

    # $-1 is a MISS and must reach the caller as :null, not as an error — RedisKV's GET returns
    # "not found" that way, and an error would read as "Redis is broken".
    defp parse_bulk(bin) do
      case :binary.split(bin, "\r\n") do
        [len_str, tail] ->
          case Integer.parse(len_str) do
            {-1, ""} ->
              {:ok, :null, tail}

            {len, ""} when len >= 0 ->
              case tail do
                # `len` is bound OUTSIDE this match, so it must be PINNED — unpinned it reads as a
                # new binding and Elixir 1.18 rejects it under --warnings-as-errors.
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

    defp redis_url do
      :shared_infra |> SharedInfra.Config.Redis.from_app() |> Keyword.fetch!(:url)
    end

    defp timeout do
      :shared_infra |> SharedInfra.Config.Redis.from_app() |> Keyword.get(:timeout, 1_000)
    end
  end
end
