defmodule SharedInfra.Scylla.XandraAdapter do
  @moduledoc """
  The REAL `SharedInfra.Scylla.Client` — a supervised `Xandra.Cluster` (Phase B).

  This is the driver only. It does NOT make Scylla the message store: `MESSAGE_STORE_ADAPTER` still
  selects Postgres, and nothing writes message rows here (the uuid/timeuuid + date/timestamp encoding
  question is Phase D — see the note at the bottom).

  BOOT SAFETY IS THE POINT. message_service serves all production chat from Postgres, so a Scylla
  problem must never take it down:

    * the cluster is started ONLY when `SCYLLA_NODES` is configured (absent → no child at all);
    * `start_link/1` NEVER returns an error — an unreachable/misconfigured cluster logs and returns
      `:ignore`, so the supervisor simply carries on without the child and the app boots;
    * `sync_connect` is deliberately left OFF (Xandra's default), so booting never blocks on a TCP
      connect — Xandra connects in the background and reconnects on its own;
    * every call checks the process is alive first, so with the child absent (or dead) callers get
      `{:error, :scylla_unavailable}` — byte-identical to the default stub they had before.

  EXECUTION. `MessageService.Persistence.QueryPlan` carries CQL with `?` placeholders and a plain,
  UNTYPED params list. Xandra can only infer parameter types from PREPARED statement metadata (a
  simple/unprepared query would require every param hand-typed as `{"text", value}`), so `execute/3`
  prepares then executes. Xandra caches prepared statements per connection, so the prepare is cheap
  after the first call and the plan reaches the driver completely unchanged.

  RESULT SHAPE is normalised to what `MessageStore.ScyllaAdapter.rows/1` already expects — verified by
  reading it, not invented: it matches `%{rows: list}`, `%{"rows" => list}`, or a bare list, and each
  row is then read with `Map.get(row, "conversation_id")`. `Xandra.Page` is a struct with `:content`
  (NOT `:rows`), so passing it through untouched would silently yield `[]` on every read. It is
  therefore converted to `%{rows: [...]}`; Xandra rows are already `%{"column" => value}` maps.
  """

  @behaviour SharedInfra.Scylla.Client

  require Logger

  @cluster __MODULE__.Cluster

  # --- supervision -------------------------------------------------------------------------------

  @doc """
  Child spec for the message service's tree. `restart: :transient` so a deliberate `:normal` shutdown
  stays down, and a crash is retried rather than being fatal.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @doc """
  Start the cluster. Returns `:ignore` — never `{:error, _}` — on any failure, so a bad host, bad
  option, or a down cluster can NEVER stop message_service from booting.
  """
  def start_link(opts \\ []) do
    case Xandra.Cluster.start_link(cluster_options(opts)) do
      {:ok, pid} ->
        Logger.info("scylla: Xandra cluster started (#{inspect(nodes(opts))}) — driver only, store is postgres")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("scylla: cluster start failed, continuing WITHOUT it: #{inspect(reason)}")
        :ignore
    end
  rescue
    error ->
      Logger.error("scylla: cluster start raised, continuing WITHOUT it: #{inspect(error)}")
      :ignore
  catch
    :exit, reason ->
      Logger.error("scylla: cluster start exited, continuing WITHOUT it: #{inspect(reason)}")
      :ignore
  end

  @doc false
  def cluster_options(opts) do
    [
      name: @cluster,
      nodes: nodes(opts),
      # Never block boot on a TCP connect (Xandra's default; stated explicitly because it is the
      # single most important option here).
      sync_connect: false,
      # One pool is plenty on this box — Scylla is pinned to --smp 1 with a 1G budget.
      pool_size: Keyword.get(opts, :pool_size, 1)
    ]
    |> put_keyspace(opts)
  end

  # `USE <keyspace>` right after each connection is established (Xandra >= 0.18 does this for us).
  # Cluster splits its own options from the connection options and forwards this one down.
  defp put_keyspace(cluster_opts, opts) do
    case Keyword.get(opts, :keyspace) do
      ks when is_binary(ks) and ks != "" -> Keyword.put(cluster_opts, :keyspace, ks)
      _ -> cluster_opts
    end
  end

  # SharedInfra.Config.Scylla yields nodes as {host, port} TUPLES; Xandra wants "host:port" STRINGS.
  defp nodes(opts) do
    opts
    |> Keyword.get(:nodes, Keyword.get(opts, :contact_points, []))
    |> List.wrap()
    |> Enum.map(fn
      {host, port} when is_integer(port) -> "#{host}:#{port}"
      node when is_binary(node) -> node
      other -> to_string(other)
    end)
    |> case do
      [] -> ["localhost:9042"]
      list -> list
    end
  end

  # --- SharedInfra.Scylla.Client -----------------------------------------------------------------

  @impl true
  def prepare(statement, opts \\ []) do
    with {:ok, cluster} <- cluster() do
      guard(fn -> Xandra.Cluster.prepare(cluster, statement, run_options(opts)) end)
    end
  end

  @impl true
  def execute(statement, params, opts \\ []) do
    run = run_options(opts)

    with {:ok, cluster} <- cluster(),
         {:ok, prepared} <- guard(fn -> Xandra.Cluster.prepare(cluster, statement, run) end),
         {:ok, result} <- guard(fn -> Xandra.Cluster.execute(cluster, prepared, params, run) end) do
      {:ok, normalize(result)}
    end
  end

  # The cluster must be RUNNING. With no child started (SCYLLA_NODES unset) or a dead one, callers get
  # exactly the stub's error, so ScyllaAdapter maps it to :message_store_unavailable as it always has.
  defp cluster do
    case Process.whereis(@cluster) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :scylla_unavailable}
    end
  end

  defp run_options(opts) do
    case Keyword.get(opts, :timeout) do
      timeout when is_integer(timeout) -> [timeout: timeout]
      _ -> []
    end
  end

  # A Scylla outage must DEGRADE, never crash the caller: everything becomes {:error, reason}.
  defp guard(fun) do
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Reads → %{rows: [%{"column" => value}]}; writes (Void) and DDL → %{rows: []}. See the moduledoc:
  # Xandra.Page has :content, not :rows, so rows/1 in ScyllaAdapter would otherwise see nothing.
  defp normalize(%Xandra.Page{} = page), do: %{rows: Enum.to_list(page)}
  defp normalize(%{__struct__: _} = other), do: %{rows: [], result: other}
  defp normalize(other), do: %{rows: [], result: other}

  # PHASE D (do not "fix" here): the write plans supply Elixir terms that do NOT yet match the CQL
  # column types — bucket_date is an ISO8601 STRING but the column is `date`, created_at/edited_at/
  # deleted_at are strings/DateTimes against `timestamp`, and metadata is an arbitrary map against
  # `map<text, text>`. message_id/reply_to_message_id are already hyphenated v1 strings, which Xandra
  # encodes fine as timeuuid. That mismatch is exactly why this phase writes NOTHING to Scylla.
end
