defmodule SharedInfra.TestAdapters.Redis do
  @moduledoc """
  Offline Redis adapter for tests.
  """

  @behaviour SharedInfra.Redis.Client

  @impl true
  def command(command, opts \\ []) do
    {:ok, %{adapter: __MODULE__, command: command, opts: opts}}
  end

  @impl true
  def pipeline(commands, opts \\ []) do
    {:ok, %{adapter: __MODULE__, commands: commands, opts: opts}}
  end
end
