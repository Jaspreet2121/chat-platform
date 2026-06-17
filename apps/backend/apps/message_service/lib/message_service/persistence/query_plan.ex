defmodule MessageService.Persistence.QueryPlan do
  @moduledoc """
  Driver-agnostic ScyllaDB query plan.

  Query plans hold parameterized CQL and ordered params only. A future ScyllaDB
  adapter can execute these without changing service boundary code.
  """

  @enforce_keys [:operation, :table, :statement, :params]
  defstruct [:operation, :table, :statement, :params]

  def new(operation, table, statement, params) when is_list(params) do
    %__MODULE__{
      operation: operation,
      table: table,
      statement: statement,
      params: params
    }
  end
end
