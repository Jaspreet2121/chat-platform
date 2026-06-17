defmodule AuthService.Schemas.RefreshToken do
  @moduledoc """
  Ecto schema for the `refresh_tokens` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "refresh_tokens" do
    field(:user_id, :binary_id)
    field(:device_id, :string)
    field(:token_hash, :string)
    field(:replaced_by_token_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(refresh_token, attrs) do
    refresh_token
    |> cast(attrs, [
      :id,
      :user_id,
      :device_id,
      :token_hash,
      :replaced_by_token_id,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :device_id, :token_hash, :expires_at])
    |> foreign_key_constraint(:user_id)
  end

  def revoke_changeset(refresh_token, attrs) do
    refresh_token
    |> cast(attrs, [:revoked_at, :replaced_by_token_id])
    |> validate_required([:revoked_at])
  end
end
