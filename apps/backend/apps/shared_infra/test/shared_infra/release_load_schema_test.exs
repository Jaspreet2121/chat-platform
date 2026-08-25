defmodule SharedInfra.ReleaseLoadSchemaTest do
  @moduledoc """
  load_schema's statement splitter and its END-TO-END proof. The splitter previously split on bare
  `;` and would have corrupted the `DO $$` blocks in 048/073 — a fresh managed DB bootstrapped
  through `bin/... eval "SharedInfra.Release.load_schema()"` would have FAILED. The postgres-gated
  test here runs the FULL init stream (every migration, 102 included) through load_schema against a
  freshly-created scratch database and asserts the resulting schema is IDENTICAL to the psql-applied
  one (`chat_platform_test`, rebuilt file-by-file by scripts/test-postgres.sh before this suite).
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Release

  # ---- The splitter itself, no DB ----------------------------------------------------------------

  test "splits plain DDL on ; and drops comments" do
    sql = """
    -- leading comment
    CREATE TABLE a (id int); -- trailing
    CREATE INDEX i ON a (id);
    """

    assert Release.statements(sql) == ["CREATE TABLE a (id int)", "CREATE INDEX i ON a (id)"]
  end

  test "semicolons inside $$ bodies are NOT statement boundaries (the 048/073 shape)" do
    sql = """
    DO $$
    DECLARE t text;
    BEGIN
      EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS app_id uuid', t);
    END $$;
    SELECT 1;
    """

    assert [do_block, "SELECT 1"] = Release.statements(sql)
    assert do_block =~ "DECLARE t text;"
    assert do_block =~ "EXECUTE format"
    assert String.ends_with?(do_block, "END $$")
  end

  test "tagged dollar quotes ($tag$…$tag$) and quoted strings protect ; and --" do
    sql = "SELECT $fn$ a; -- not a comment $fn$; INSERT INTO t VALUES ('a;b', \"c;d\");"

    assert Release.statements(sql) == [
             "SELECT $fn$ a; -- not a comment $fn$",
             "INSERT INTO t VALUES ('a;b', \"c;d\")"
           ]
  end

  test "a comment between tokens never fuses adjacent lines; block comments too" do
    assert Release.statements("SELECT 1 -- c\n+ 2; SELECT /* x */ 3;") ==
             ["SELECT 1 \n+ 2", "SELECT   3"]
  end

  test "an unterminated dollar-quoted region raises instead of half-loading" do
    assert_raise RuntimeError, ~r/unterminated/, fn ->
      Release.statements("DO $$ BEGIN never closed;")
    end
  end

  test "every real schema file splits into non-empty statements with balanced content" do
    for path <- Release.sql_files() do
      statements = path |> File.read!() |> Release.statements()
      assert statements != [], "#{Path.basename(path)} produced no statements"

      for statement <- statements do
        refute statement =~ ~r/\A\s*\z/, "#{Path.basename(path)}: blank statement"
      end
    end
  end

  # ---- End-to-end: the FULL init stream on a fresh DB equals the psql-applied schema -------------

  @scratch_db "chat_platform_load_schema_check"
  @reference_db System.get_env("POSTGRES_TEST_DATABASE", "chat_platform_test")

  @tag :postgres_integration
  test "load_schema applies ALL migrations (102 included) identically to psql" do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {:ok, admin} = Postgrex.start_link(conn_opts("postgres"))
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@scratch_db}", [])
    Postgrex.query!(admin, "CREATE DATABASE #{@scratch_db}", [])

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(conn_opts("postgres"))
      Postgrex.query!(cleanup, "DROP DATABASE IF EXISTS #{@scratch_db}", [])
      GenServer.stop(cleanup)
    end)

    assert :ok = Release.load_schema(conn_opts: conn_opts(@scratch_db))

    {:ok, scratch} = Postgrex.start_link(conn_opts(@scratch_db))
    {:ok, reference} = Postgrex.start_link(conn_opts(@reference_db))

    assert inventory(scratch, :tables) == inventory(reference, :tables)
    assert inventory(scratch, :columns) == inventory(reference, :columns)
    assert inventory(scratch, :indexes) == inventory(reference, :indexes)
    assert inventory(scratch, :constraints) == inventory(reference, :constraints)

    # The DO $$ block in 048 actually EXECUTED: it is what stamps app_id onto the core tables.
    assert {"messages", "app_id", "uuid", "NO"} in inventory(scratch, :columns)

    GenServer.stop(scratch)
    GenServer.stop(reference)
  end

  defp inventory(conn, :tables) do
    query(conn, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")
  end

  defp inventory(conn, :columns) do
    query(conn, """
    SELECT table_name, column_name, udt_name, is_nullable
    FROM information_schema.columns WHERE table_schema = 'public'
    """)
  end

  defp inventory(conn, :indexes) do
    query(conn, "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'")
  end

  defp inventory(conn, :constraints) do
    query(conn, """
    SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
    FROM pg_constraint con JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace WHERE ns.nspname = 'public'
    """)
  end

  defp query(conn, sql) do
    conn
    |> Postgrex.query!(sql, [])
    |> Map.fetch!(:rows)
    |> Enum.map(&List.to_tuple/1)
    |> Enum.sort()
  end

  defp conn_opts(database) do
    [
      hostname: System.get_env("POSTGRES_TEST_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_TEST_PORT", "5432")),
      username: System.get_env("POSTGRES_TEST_USER", "chat_user"),
      password: System.get_env("POSTGRES_TEST_PASSWORD", "chat_password"),
      database: database
    ]
  end
end
