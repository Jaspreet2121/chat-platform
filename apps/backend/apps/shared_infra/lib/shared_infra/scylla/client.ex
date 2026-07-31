defmodule SharedInfra.Scylla.Client do
  @moduledoc """
  Behaviour and configured entrypoint for ScyllaDB client adapters.

  This module keeps live ScyllaDB execution behind a small adapter boundary.
  The default adapter is intentionally unavailable so normal tests and local
  development remain Docker-free until an environment opts into a real driver.
  """

  @callback prepare(statement :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback execute(statement :: String.t(), params :: list(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  def prepare(statement, opts \\ []) do
    adapter().prepare(statement, opts)
  end

  def execute(statement, params, opts \\ []) do
    adapter().execute(statement, params, opts)
  end

  def adapter do
    Application.get_env(
      :shared_infra,
      :scylla_client_adapter,
      SharedInfra.Scylla.UnavailableClient
    )
  end
end

defmodule SharedInfra.Scylla.UnavailableClient do
  @moduledoc """
  Safe default ScyllaDB client.

  It reports that live ScyllaDB execution is unavailable instead of attempting
  a network call without an explicitly configured driver adapter.
  """

  @behaviour SharedInfra.Scylla.Client

  @impl true
  def prepare(_statement, _opts \\ []), do: {:error, :scylla_unavailable}

  @impl true
  def execute(_statement, _params, _opts \\ []), do: {:error, :scylla_unavailable}
end
