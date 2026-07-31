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

  Idempotent: every statement is `CREATE ... IF NOT EXISTS`, so a re-run on an already-loaded DB is a
  safe no-op. Plain DDL only (no `$$`/functions/triggers), so splitting each file into `;`-terminated
  statements is safe.
  """

  require Logger

  @doc "Apply every priv/schema/*.sql (numeric order) against DATABASE_URL. Returns :ok."
  @spec load_schema() :: :ok
  def load_schema do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ssl)

    files = sql_files()
    {:ok, conn} = Postgrex.start_link(conn_opts())

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

  # Strip line comments, split on `;`. Safe here: the schema is plain DDL (verified — no `$$` bodies,
  # functions, or triggers where a `;` could be embedded).
  defp statements(sql) do
    sql
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split("--", parts: 2) |> List.first() end)
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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
