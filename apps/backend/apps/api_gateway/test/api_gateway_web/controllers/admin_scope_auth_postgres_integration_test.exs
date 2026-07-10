defmodule ApiGatewayWeb.AdminScopeAuthPostgresIntegrationTest do
  @moduledoc """
  DB-backed: the admin console's user/role queries are confined to tenant-zero. Seeds one tenant-zero user
  and one integrator (other-app) user, then asserts the integrator is invisible/immutable:
    * list_users → the integrator is ABSENT.
    * set_role on the integrator → :user_not_found, users_auth.role UNCHANGED (the test that fails pre-fix).
    * user_detail on the integrator → :user_not_found.

  Tagged :postgres_integration (excluded by default) — needs a migrated Postgres. Exercises
  AuthService.{Accounts,Moderation} directly (the in-process path the gateway drives).
  """
  use ExUnit.Case, async: false

  alias AuthService.{Accounts, Moderation}
  alias AuthService.Repo, as: AuthRepo

  @moduletag :postgres_integration

  @default SharedInfra.Tenancy.default_app_id()

  setup do
    start_repo!(AuthRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthRepo)

    integrator_app = Ecto.UUID.generate()
    zero_user = Ecto.UUID.generate()
    integrator_user = Ecto.UUID.generate()

    seed_app!(integrator_app)
    seed_user!(zero_user, @default, "zero")
    seed_user!(integrator_user, integrator_app, "integrator")

    {:ok, zero_user: zero_user, integrator_user: integrator_user}
  end

  test "list_users returns the tenant-zero user and NOT the integrator user", ctx do
    ids = Accounts.list_users(%{"app_id" => @default}).users |> Enum.map(& &1.user_id)
    assert ctx.zero_user in ids
    refute ctx.integrator_user in ids
  end

  test "set_role on an integrator user → :user_not_found, role UNCHANGED", ctx do
    assert {:error, :user_not_found} =
             Moderation.set_role(%{
               "user_id" => ctx.integrator_user,
               "role" => "moderator",
               "actor_user_id" => ctx.zero_user,
               "app_id" => @default
             })

    assert role_of(ctx.integrator_user) == "user"
  end

  test "set_role on the tenant-zero user succeeds", ctx do
    assert {:ok, %{role: "moderator"}} =
             Moderation.set_role(%{
               "user_id" => ctx.zero_user,
               "role" => "moderator",
               "actor_user_id" => ctx.zero_user,
               "app_id" => @default
             })
  end

  test "user_detail on an integrator user → :user_not_found", ctx do
    assert {:error, :user_not_found} =
             Moderation.user_detail(%{"user_id" => ctx.integrator_user, "app_id" => @default})
  end

  defp role_of(user_id) do
    %Postgrex.Result{rows: [[role]]} =
      AuthRepo.query!("SELECT role FROM users_auth WHERE id = $1::uuid", [user_id])

    role
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp seed_app!(id) do
    AuthRepo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::uuid, 'Integrator', $2)", [
      id,
      "int-" <> String.slice(String.replace(id, "-", ""), 0, 12)
    ])
  end

  defp seed_user!(id, app_id, tag) do
    AuthRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status, app_id, role) " <>
        "VALUES ($1::uuid, $2, 'active', $3::uuid, 'user')",
      [id, "+1#{tag}#{String.slice(String.replace(id, "-", ""), 0, 8)}", app_id]
    )
  end
end
