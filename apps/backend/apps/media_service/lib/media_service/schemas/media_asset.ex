defmodule MediaService.Schemas.MediaAsset do
  @moduledoc """
  Ecto schema for `media_assets`. A row is the authoritative record of an uploaded object: who owns it
  (`owner_user_id`), which tenant (`app_id`) and conversation (`conversation_id`, nullable) it belongs to,
  its `purpose`, the SERVER-generated `object_key`, and its upload lifecycle `status`. The read path
  (Phase 2) will resolve a download by `id` scoped to `app_id` and check ownership/membership against this
  row instead of trusting a client-supplied key.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @statuses ~w(created uploading uploaded processing ready failed deleted)
  @purposes ~w(message user_avatar group_avatar)
  @providers ~w(s3 minio)

  schema "media_assets" do
    field(:owner_user_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:app_id, :binary_id)
    field(:purpose, :string)
    field(:storage_provider, :string)
    field(:bucket, :string)
    field(:object_key, :string)
    field(:mime_type, :string)
    field(:size_bytes, :integer)
    field(:checksum, :string)
    field(:status, :string)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "Changeset for the initial insert (status 'created'). created_at/updated_at are set explicitly."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :owner_user_id,
      :conversation_id,
      :app_id,
      :purpose,
      :storage_provider,
      :bucket,
      :object_key,
      :mime_type,
      :size_bytes,
      :checksum,
      :status,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :owner_user_id,
      :app_id,
      :purpose,
      :storage_provider,
      :bucket,
      :object_key,
      :mime_type,
      :size_bytes,
      :status,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:purpose, @purposes)
    |> validate_inclusion(:storage_provider, @providers)
  end

  @doc "Changeset that flips an asset's status (e.g. → 'ready' on complete), bumping updated_at."
  def status_changeset(%__MODULE__{} = asset, status, updated_at) do
    asset
    |> change(status: status, updated_at: updated_at)
    |> validate_inclusion(:status, @statuses)
  end
end
