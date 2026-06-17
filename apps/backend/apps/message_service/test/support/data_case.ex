defmodule MessageService.DataCase do
  @moduledoc """
  Test helper for Message Service Postgres-backed store tests.

  DB tests are opt-in with `@tag :postgres_integration` and require a prepared
  local PostgreSQL test database (with the message store tables from
  infra/docker/postgres/init/020_message_store.sql applied).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias MessageService.Repo
    end
  end

  setup _tags do
    start_repo!(MessageService.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MessageService.Repo)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
