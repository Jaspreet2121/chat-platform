defmodule AuthService.AppsCapRenameTest do
  @moduledoc """
  The B2C allocation additions on real SQL: the per-owner LIVE-app cap (default 3, config-raisable,
  counted under the per-owner advisory lock so concurrent creates can't both squeeze under it), and
  RENAME-only mutation — owner renames a live app; a non-owner, a twin, and a nonexistent id are the
  same :forbidden (no existence leak). Deletion/deactivation is deliberately absent (recorded
  follow-up), so there is nothing to test for it — this suite is the record that rename is the only
  mutation.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Apps

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "owner-#{id}@test.local"]
    )

    id
  end

  @tag :postgres_integration
  test "CAP: 3 live apps by default; the 4th is :app_limit_reached; config raises it" do
    owner = user!()

    for n <- 1..3 do
      assert {:ok, %{app_id: _, mode: "live"}} =
               Apps.create_app(%{"owner_user_id" => owner, "name" => "App #{n}"})
    end

    assert {:error, :app_limit_reached} =
             Apps.create_app(%{"owner_user_id" => owner, "name" => "App 4"})

    # ANOTHER owner is a fresh counter — the cap is per owner, not global.
    other = user!()
    assert {:ok, _} = Apps.create_app(%{"owner_user_id" => other, "name" => "Other's App"})

    # Config override: operators can raise the cap without a release.
    prev = Application.get_env(:auth_service, :max_apps_per_owner)
    Application.put_env(:auth_service, :max_apps_per_owner, 4)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :max_apps_per_owner, prev),
        else: Application.delete_env(:auth_service, :max_apps_per_owner)
    end)

    assert {:ok, _} = Apps.create_app(%{"owner_user_id" => owner, "name" => "App 4"})

    assert {:error, :app_limit_reached} =
             Apps.create_app(%{"owner_user_id" => owner, "name" => "App 5"})
  end

  @tag :postgres_integration
  test "RENAME: owner renames a live app; non-owner/twin/nonexistent are the SAME :forbidden" do
    owner = user!()
    stranger = user!()

    {:ok, %{app_id: app_id}} = Apps.create_app(%{"owner_user_id" => owner, "name" => "Before"})

    assert {:ok, %{app_id: ^app_id, name: "After", mode: "live"}} =
             Apps.rename_app(%{
               "owner_user_id" => owner,
               "app_id" => app_id,
               "name" => "After"
             })

    %{rows: [[stored]]} =
      Repo.query!("SELECT name FROM apps WHERE id = $1::text::uuid", [app_id])

    assert stored == "After"

    # A non-owner cannot rename it — and cannot learn it exists.
    assert {:error, :forbidden} =
             Apps.rename_app(%{
               "owner_user_id" => stranger,
               "app_id" => app_id,
               "name" => "Hijacked"
             })

    # A TWIN is never renamed directly, even by the live app's owner (its name is derived).
    Repo.query!(
      "INSERT INTO apps (id, name, slug, parent_app_id, mode) " <>
        "SELECT gen_random_uuid(), name || ' (test)', slug || '-test', id, 'test' " <>
        "FROM apps WHERE id = $1::text::uuid",
      [app_id]
    )

    %{rows: [[twin_id]]} =
      Repo.query!(
        "SELECT id::text FROM apps WHERE parent_app_id = $1::text::uuid",
        [app_id]
      )

    assert {:error, :forbidden} =
             Apps.rename_app(%{
               "owner_user_id" => owner,
               "app_id" => twin_id,
               "name" => "Twin rename"
             })

    assert {:error, :forbidden} =
             Apps.rename_app(%{
               "owner_user_id" => owner,
               "app_id" => Ecto.UUID.generate(),
               "name" => "Ghost"
             })
  end
end
