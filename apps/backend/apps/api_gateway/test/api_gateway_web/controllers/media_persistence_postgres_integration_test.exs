defmodule ApiGatewayWeb.MediaPersistencePostgresIntegrationTest do
  @moduledoc """
  DB-backed write path: create_upload persists a media_assets row (tenant + owner + purpose + SERVER
  object_key + status 'created'); complete_upload resolves the row scoped to app_id, verifies the caller
  OWNS it (foreign owner / cross-tenant → :not_found), flips it to 'ready', and is idempotent.

  Tagged :postgres_integration (excluded by default) — requires a migrated Postgres (media_assets with the
  new app_id + purpose columns, and the tenant-zero app seed from migration 048). Exercises
  MediaService.Media directly against MediaService.Repo, the same in-process path the gateway drives.
  """
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Schemas.MediaAsset

  @moduletag :postgres_integration

  # Tenant zero — seeded by migration 048 (media_assets.app_id defaults to it + FKs apps(id)).
  @app "00000000-0000-0000-0000-000000000001"

  setup do
    prev_persist = Application.get_env(:media_service, :media_persistence, false)

    prev_adapter =
      Application.get_env(:media_service, :media_storage_adapter, MediaService.Storage.QueryPlanAdapter)

    Application.put_env(:media_service, :media_persistence, true)
    # A non-networked adapter that returns a fake upload_url so create_upload succeeds end-to-end.
    Application.put_env(:media_service, :media_storage_adapter, MediaService.Storage.InMemoryAdapter)

    start_repo!(MediaRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)

    owner = Ecto.UUID.generate()
    other = Ecto.UUID.generate()
    other_app = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()

    # FK targets, all inside MediaRepo's sandbox connection.
    seed_user!(owner)
    seed_user!(other)
    seed_app!(other_app)
    seed_conversation!(conversation, owner)

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, prev_persist)
      Application.put_env(:media_service, :media_storage_adapter, prev_adapter)
    end)

    {:ok, owner: owner, other: other, other_app: other_app, conversation: conversation}
  end

  test "create_upload (message) persists a row with tenant + conversation + purpose + server key + status 'created'",
       %{owner: owner, conversation: conversation} do
    {:ok, %{media_id: media_id}} =
      Media.create_upload(%{
        "owner_user_id" => owner,
        "app_id" => @app,
        "purpose" => "message",
        "conversation_id" => conversation,
        "filename" => "photo.png",
        "content_type" => "image/png",
        "size_bytes" => 42
      })

    asset = MediaRepo.get(MediaAsset, media_id)
    assert asset.app_id == @app
    assert asset.owner_user_id == owner
    assert asset.conversation_id == conversation
    assert asset.purpose == "message"
    assert asset.status == "created"
    # object_key is SERVER-generated (media/<owner>/<media_id>/<safe filename>), never client-supplied.
    assert asset.object_key == "media/#{owner}/#{media_id}/photo.png"
  end

  test "complete_upload by the owner flips status to 'ready'", %{owner: owner} do
    media_id = create!(owner)

    assert {:ok, %{status: "ready"}} =
             Media.complete_upload(%{"media_id" => media_id, "owner_user_id" => owner, "app_id" => @app})

    assert MediaRepo.get(MediaAsset, media_id).status == "ready"
  end

  test "complete_upload by a DIFFERENT user → 404, status unchanged (the new ownership predicate)",
       %{owner: owner, other: other} do
    media_id = create!(owner)

    assert {:error, :not_found} =
             Media.complete_upload(%{"media_id" => media_id, "owner_user_id" => other, "app_id" => @app})

    # The foreign completion did NOT flip it — the asset is untouched.
    assert MediaRepo.get(MediaAsset, media_id).status == "created"
  end

  test "complete_upload for another tenant's app_id → 404", %{owner: owner, other_app: other_app} do
    media_id = create!(owner)

    assert {:error, :not_found} =
             Media.complete_upload(%{
               "media_id" => media_id,
               "owner_user_id" => owner,
               "app_id" => other_app
             })

    assert MediaRepo.get(MediaAsset, media_id).status == "created"
  end

  test "complete_upload for an unknown media_id → 404", %{owner: owner} do
    assert {:error, :not_found} =
             Media.complete_upload(%{
               "media_id" => Ecto.UUID.generate(),
               "owner_user_id" => owner,
               "app_id" => @app
             })
  end

  test "complete_upload is idempotent (completing an already-ready asset succeeds)", %{owner: owner} do
    media_id = create!(owner)

    assert {:ok, %{status: "ready"}} =
             Media.complete_upload(%{"media_id" => media_id, "owner_user_id" => owner, "app_id" => @app})

    assert {:ok, %{status: "ready"}} =
             Media.complete_upload(%{"media_id" => media_id, "owner_user_id" => owner, "app_id" => @app})
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp create!(owner) do
    {:ok, %{media_id: media_id}} =
      Media.create_upload(%{
        "owner_user_id" => owner,
        "app_id" => @app,
        "purpose" => "user_avatar",
        "filename" => "a.png",
        "content_type" => "image/png",
        "size_bytes" => 10
      })

    media_id
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp seed_user!(id) do
    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::uuid, $2, 'active')",
      [id, "+1" <> String.slice(String.replace(id, "-", ""), 0, 10)]
    )
  end

  defp seed_app!(id) do
    MediaRepo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::uuid, 'Other App', $2)",
      [id, "other-" <> String.slice(String.replace(id, "-", ""), 0, 12)]
    )
  end

  # app_id defaults to tenant-zero (migration 048), so this conversation lands in @app.
  defp seed_conversation!(id, created_by) do
    MediaRepo.query!(
      "INSERT INTO conversations (id, type, created_by) VALUES ($1::uuid, 'group', $2::uuid)",
      [id, created_by]
    )
  end
end
