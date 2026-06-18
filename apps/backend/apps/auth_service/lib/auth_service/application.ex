defmodule AuthService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: AuthService.Supervisor)
  end

  # The Repo is supervised at boot in dev/prod so the server can serve DB-backed requests.
  # In :test it is NOT started here (config sets `start_repo: false`); DataCase starts it
  # per-test, keeping plain `mix test` Docker-free.
  defp children do
    if Application.get_env(:auth_service, :start_repo, true), do: [AuthService.Repo], else: []
  end
end
