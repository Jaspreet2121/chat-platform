defmodule UserService.DataCase do
  @moduledoc """
  Test helper for User Service database-backed tests.

  DB tests are opt-in with `@tag :postgres_integration` and require a prepared
  local PostgreSQL test database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias UserService.Repo
    end
  end

  setup _tags do
    start_repo!(UserService.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(UserService.Repo)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
