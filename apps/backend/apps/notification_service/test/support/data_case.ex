defmodule NotificationService.DataCase do
  @moduledoc """
  Test helper for notification-service Postgres-backed tests.

  DB tests are opt-in with `@tag :postgres_integration` and require a prepared local
  PostgreSQL test database (with the tables from
  infra/docker/postgres/init/040_notifications.sql applied). The Repo is started here in
  setup (NOT via the app supervision tree), so it is available to Repo-only tests
  independent of the `NOTIFICATION_CONSUMER_ENABLED` flag, while plain `mix test` stays
  Docker-free (nothing starts the Repo when no DB test runs).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias NotificationService.Repo
    end
  end

  setup _tags do
    start_repo!(NotificationService.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(NotificationService.Repo)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
