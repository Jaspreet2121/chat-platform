defmodule ConversationService.Schemas.Conversation do
  @moduledoc """
  Ecto schema for the `conversations` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "conversations" do
    field(:tenant_id, :binary_id)

    # The app (tenant) this conversation belongs to (migration 048). The direct-dedup unique index is
    # (app_id, direct_key), so dedup is per-app.
    field(:app_id, :binary_id)
    field(:type, :string)
    field(:title, :string)
    field(:avatar_media_id, :binary_id)
    field(:created_by, :binary_id)
    field(:status, :string, default: "active")
    # Canonical "min:max" pair key for type='direct' (NULL otherwise). A partial unique index
    # (idx_conversations_direct_key_unique, migration 047) makes direct chats one-per-pair.
    field(:direct_key, :string)

    # 108: opt-in E2EE — content is client-sealed; the server relays ciphertext only. One-way in v1.
    field(:secret, :boolean, default: false)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :id,
      :tenant_id,
      :app_id,
      :type,
      :title,
      :avatar_media_id,
      :created_by,
      :status,
      :direct_key,
      :created_at,
      :updated_at
    ])
    |> validate_required([:type, :created_by, :status])
    |> validate_inclusion(:type, ["direct", "group", "business"])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:created_by)
    |> unique_constraint(:direct_key, name: :idx_conversations_direct_key_unique)
  end

  def update_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :avatar_media_id, :status])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
  end
end
