defmodule RealtimeGateway.ConnectionCounter.Table do
  @moduledoc """
  Owns the named ETS table backing `RealtimeGateway.ConnectionCounter`'s `:ets` backend, so it survives
  across sockets (a socket process must not own it). Harmless when the backend is `:redis` (an empty table).
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    table = RealtimeGateway.ConnectionCounter.__table__()

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    {:ok, table}
  end
end
