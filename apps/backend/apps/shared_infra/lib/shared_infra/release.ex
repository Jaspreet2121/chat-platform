defmodule SharedInfra.Release do
  @moduledoc """
  Release tasks runnable via `bin/<release> eval`.

  The project's schema is RAW SQL (`infra/docker/postgres/init/001..042`), NOT Ecto migrations, and
  a managed Postgres (e.g. a fresh Fly Postgres) comes EMPTY — there is no `docker-entrypoint-initdb`
  auto-load outside the compose path. `load_schema/0` applies those files from inside the release.

  The SQL ships in shared_infra's `priv/schema` — a release-bundled COPY of
  `infra/docker/postgres/init` (the latter stays canonical for the compose initdb mount + CI; the two
  are kept byte-identical by `SharedInfra.ReleaseSchemaDriftTest`). priv is always bundled into a
  release, so the files are readable at runtime via `Application.app_dir/2` (the release image has no
  `psql`, hence Postgrex).

  Run on a FRESH DB after provisioning, BEFORE booting the server:

      bin/chat_platform eval "SharedInfra.Release.load_schema()"

  Idempotent: every statement is guarded (`IF NOT EXISTS` / `ON CONFLICT DO NOTHING`), so a re-run on
  an already-loaded DB is a safe no-op. Statements are split on `;` by a scanner that respects
  single-quoted strings, double-quoted identifiers, `--` line comments, `/* */` block comments, and
  dollar-quoted bodies (`$$…$$` / `$tag$…$tag$`) — 048 and 073 carry `DO $$` blocks whose inner
  semicolons are content, not statement boundaries.
  """

  require Logger

  @doc """
  Apply every priv/schema/*.sql (numeric order) against DATABASE_URL. Returns :ok.
  `opts[:conn_opts]` overrides the connection (tests point it at a scratch DB); production callers
  pass nothing and the connection comes from DATABASE_URL as always.
  """
  @spec load_schema(keyword()) :: :ok
  def load_schema(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ssl)

    files = sql_files()
    {:ok, conn} = Postgrex.start_link(Keyword.get(opts, :conn_opts) || conn_opts())

    try do
      Enum.each(files, fn path ->
        statements = path |> File.read!() |> statements()

        Logger.info(
          "load_schema: applying #{Path.basename(path)} (#{length(statements)} statements)"
        )

        Enum.each(statements, &Postgrex.query!(conn, &1, []))
      end)
    after
      GenServer.stop(conn)
    end

    Logger.info("load_schema: done (#{length(files)} files)")
    :ok
  end

  @doc "The bundled schema SQL files, in numeric (filename) order."
  @spec sql_files() :: [String.t()]
  def sql_files do
    :shared_infra
    |> Application.app_dir("priv/schema")
    |> Path.join("*.sql")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc false
  # Split SQL into `;`-terminated statements. A single-pass scanner, because a naive split corrupts
  # anything with an embedded `;`: dollar-quoted bodies (DO $$…$$ in 048/073), quoted strings, and
  # comments. Comments are dropped; quoted/dollar-quoted content passes through verbatim.
  # Public (doc false) so the splitter's edge cases are testable without a database.
  def statements(sql) do
    sql
    |> scan([], [])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # scan(rest, current_statement_iodata, completed_statements_reversed)
  defp scan(<<>>, current, acc),
    do: Enum.reverse([IO.iodata_to_binary(current) | acc])

  defp scan(<<";", rest::binary>>, current, acc),
    do: scan(rest, [], [IO.iodata_to_binary(current) | acc])

  # A dropped comment leaves whitespace behind so tokens on adjacent lines never fuse.
  defp scan(<<"--", rest::binary>>, current, acc),
    do: scan(drop_through(rest, "\n"), [current, ?\n], acc)

  defp scan(<<"/*", rest::binary>>, current, acc),
    do: scan(drop_through(rest, "*/"), [current, ?\s], acc)

  # 'string' — a doubled '' simply re-enters this clause on the next quote; content is preserved.
  defp scan(<<?', rest::binary>>, current, acc) do
    {chunk, rest} = take_through(rest, "'")
    scan(rest, [current, ?', chunk], acc)
  end

  # "identifier"
  defp scan(<<?", rest::binary>>, current, acc) do
    {chunk, rest} = take_through(rest, "\"")
    scan(rest, [current, ?", chunk], acc)
  end

  defp scan(<<?$, _::binary>> = bin, current, acc) do
    case dollar_delimiter(bin) do
      {delimiter, rest} ->
        {chunk, rest} = take_through(rest, delimiter)
        scan(rest, [current, delimiter, chunk], acc)

      nil ->
        <<byte, rest::binary>> = bin
        scan(rest, [current, byte], acc)
    end
  end

  defp scan(<<byte, rest::binary>>, current, acc), do: scan(rest, [current, byte], acc)

  # `$tag$` / `$$` at the head of the binary, or nil when this `$` is not a dollar-quote opener
  # (e.g. a positional parameter in a comment-free line — none exist in DDL, but be exact anyway).
  defp dollar_delimiter(<<?$, rest::binary>>) do
    case take_tag(rest, []) do
      {tag, <<?$, after_delim::binary>>} -> {"$" <> tag <> "$", after_delim}
      _ -> nil
    end
  end

  defp take_tag(<<byte, rest::binary>>, acc)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_,
       do: take_tag(rest, [acc, byte])

  defp take_tag(rest, acc), do: {IO.iodata_to_binary(acc), rest}

  # Content up to AND INCLUDING the closing marker. Unterminated regions raise — a truncated schema
  # file must fail loudly, never load a half-parsed statement.
  defp take_through(bin, marker) do
    case :binary.split(bin, marker) do
      [chunk, rest] -> {chunk <> marker, rest}
      [_] -> raise "load_schema: unterminated #{inspect(marker)} region in schema SQL"
    end
  end

  # Content dropped up to and including the marker; hitting EOF is fine (trailing comment).
  defp drop_through(bin, marker) do
    case :binary.split(bin, marker) do
      [_chunk, rest] -> rest
      [_] -> ""
    end
  end

  defp conn_opts do
    url = System.get_env("DATABASE_URL") || raise "load_schema: DATABASE_URL is not set"
    uri = URI.parse(url)
    {user, pass} = userinfo(uri.userinfo)

    base = [
      hostname: uri.host,
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: uri.path |> to_string() |> String.trim_leading("/")
    ]

    # Mirror config/runtime.exs's Ecto SSL default (verify_none — pragmatic for managed PG first deploy).
    if System.get_env("DATABASE_SSL", "true") in ["true", "1", "yes"] do
      base ++ [ssl: true, ssl_opts: [verify: :verify_none]]
    else
      base
    end
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [u, p] -> {u, p}
      [u] -> {u, nil}
    end
  end
end
