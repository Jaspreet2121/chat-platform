defmodule SharedInfra.TestAdapters.Scylla do
  @moduledoc """
  Offline ScyllaDB adapter for tests.
  """

  @behaviour SharedInfra.Scylla.Client

  @impl true
  def prepare(statement, opts \\ []) do
    {:ok, %{adapter: __MODULE__, statement: statement, opts: opts}}
  end

  @impl true
  def execute(statement, params, opts \\ []) do
    {:ok, %{adapter: __MODULE__, statement: statement, params: params, opts: opts}}
  end
end
