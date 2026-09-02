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
  # Layer 2 of 3 for the purpose set (service whitelist -> THIS changeset -> DB CHECK). All three
  # must agree; the whitelist-enumeration test in MediaService.MediaTest creates through the real
  # path per purpose, so a purpose missing at ANY layer fails the gate. "status" was missing at all
  # three while its authz arm shipped — photo/video status never worked.
  #
  # It happened AGAIN with "user_asset" (113): layer 1 and layer 3 were updated, this one was not,
  # and every UPI QR create returned :media_invalid. The comment above predicted it and the
  # enumeration test caught it — before deploy, which is the whole point of both.
  @purposes ~w(message user_avatar group_avatar status sealed_media user_asset)
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

  @doc """
  Flip to `ready` AND record the REAL measured object size (from a HEAD at complete), replacing the size the
  client merely CLAIMED at create. Usage metering sums `size_bytes`, so storing the claim would let an app
  under-report its storage forever.
  """
  def ready_changeset(%__MODULE__{} = asset, real_size_bytes, updated_at)
      when is_integer(real_size_bytes) and real_size_bytes >= 0 do
    asset
    |> change(status: "ready", size_bytes: real_size_bytes, updated_at: updated_at)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
  end
end
