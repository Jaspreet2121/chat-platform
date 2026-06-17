defmodule AuthService.Schemas.DeviceSession do
  @moduledoc """
  Ecto schema for the `device_sessions` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "device_sessions" do
    field(:user_id, :binary_id)
    field(:device_id, :string)
    field(:device_name, :string)
    field(:platform, :string)
    field(:refresh_token_hash, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(device_session, attrs) do
    device_session
    |> cast(attrs, [
      :id,
      :user_id,
      :device_id,
      :device_name,
      :platform,
      :refresh_token_hash,
      :last_seen_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :device_id, :platform, :refresh_token_hash])
    |> validate_inclusion(:platform, ["android", "ios", "web"])
    |> unique_constraint([:user_id, :device_id])
    |> foreign_key_constraint(:user_id)
  end
end
