defmodule AuthService.DataCase do
  @moduledoc """
  Test helper for Auth Service database-backed tests.

  DB tests are opt-in with `@tag :postgres_integration` and require a prepared
  local PostgreSQL test database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AuthService.Repo
    end
  end

  setup _tags do
    start_repo!(AuthService.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthService.Repo)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
