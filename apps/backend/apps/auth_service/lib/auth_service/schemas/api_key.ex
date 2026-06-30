defmodule AuthService.Schemas.ApiKey do
  @moduledoc """
  Ecto schema for `api_keys` — a per-app secret credential. Only the sha256 `key_hash` + a non-secret
  `key_prefix` are stored; the raw `sk_live_…` key is never persisted (returned once at creation).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field(:app_id, :binary_id)
    field(:name, :string)
    field(:key_hash, :string)
    field(:key_prefix, :string)
    field(:created_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :id,
      :app_id,
      :name,
      :key_hash,
      :key_prefix,
      :created_at,
      :last_used_at,
      :revoked_at
    ])
    |> validate_required([:app_id, :name, :key_hash, :key_prefix])
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:app_id)
  end
end
