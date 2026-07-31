defmodule ApiGatewayWeb.AdminScopeAnalyticsPostgresIntegrationTest do
  @moduledoc """
  DB-backed: admin analytics count tenant-zero ONLY. Seeds one tenant-zero and one integrator user,
  conversation, message, and media asset, then asserts overview counts each domain as 1 (not 2). Messages
  are counted via the parent CONVERSATION's app_id (messages.app_id is unreliable).

  Tagged :postgres_integration — needs a migrated Postgres. Exercises MessageService.Analytics directly.
  """
  use ExUnit.Case, async: false

  alias MessageService.Analytics
  alias MessageService.Repo, as: MsgRepo

  @moduletag :postgres_integration

  @default SharedInfra.Tenancy.default_app_id()

  setup do
    start_repo!(MsgRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MsgRepo)

    int_app = Ecto.UUID.generate()
    zero_user = Ecto.UUID.generate()
    int_user = Ecto.UUID.generate()
    zero_convo = Ecto.UUID.generate()
    int_convo = Ecto.UUID.generate()

    seed_app!(int_app)
    seed_user!(zero_user, @default)
    seed_user!(int_user, int_app)
    seed_convo!(zero_convo, @default, zero_user)
    seed_convo!(int_convo, int_app, int_user)
    seed_message!(zero_convo, zero_user)
    seed_message!(int_convo, int_user)
    seed_media!(zero_user, @default)
    seed_media!(int_user, int_app)

    :ok
  end

  test "overview totals count tenant-zero only (users/conversations/messages/media = 1, not 2)" do
    totals = Analytics.overview(@default).totals

    assert totals.users == 1
    assert totals.conversations == 1
    # messages routed through the parent conversation's app_id (messages.app_id unreliable).
    assert totals.messages == 1
    assert totals.media == 1
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp seed_app!(id) do
    MsgRepo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Integrator', $2)", [
      id,
      "int-" <> String.slice(String.replace(id, "-", ""), 0, 12)
    ])
  end

  defp seed_user!(id, app_id) do
    MsgRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status, app_id, role) " <>
        "VALUES ($1::text::uuid, $2, 'active', $3::text::uuid, 'user')",
      [id, "+1#{String.slice(String.replace(id, "-", ""), 0, 10)}", app_id]
    )
  end

  defp seed_convo!(id, app_id, created_by) do
    MsgRepo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active')",
      [id, app_id, created_by]
    )
  end

  defp seed_message!(conversation_id, sender) do
    MsgRepo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, status) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'text', 'active')",
      [conversation_id, sender]
    )
  end

  defp seed_media!(owner, app_id) do
    MsgRepo.query!(
      "INSERT INTO media_assets (id, owner_user_id, app_id, purpose, storage_provider, bucket, " <>
        "object_key, mime_type, size_bytes, status) VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, " <>
        "'message', 'minio', 'chat-media', $3, 'image/png', 10, 'ready')",
      [owner, app_id, "media/#{owner}/#{Ecto.UUID.generate()}/a.png"]
    )
  end
end
