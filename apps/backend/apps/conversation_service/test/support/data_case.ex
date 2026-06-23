defmodule ConversationService.DataCase do
  @moduledoc """
  Test helper for Conversation Service database-backed tests.

  DB tests are opt-in with `@tag :postgres_integration` and require a prepared
  local PostgreSQL test database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ConversationService.Repo
    end
  end

  setup _tags do
    start_repo!(ConversationService.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ConversationService.Repo)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      # Unlink so a failing test's abnormal exit cannot kill the shared Repo and cascade
      # "no process" Sandbox.checkout failures into the rest of the suite.
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
