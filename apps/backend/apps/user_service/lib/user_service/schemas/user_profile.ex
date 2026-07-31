defmodule UserService.Schemas.UserProfile do
  @moduledoc """
  Ecto schema for the `user_profiles` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:user_id, :binary_id, autogenerate: false}

  schema "user_profiles" do
    field(:display_name, :string)
    field(:avatar_media_id, :binary_id)
    field(:avatar_object_key, :string)
    field(:bio, :string)

    # The optional @handle (080): `username` as typed (display), `username_key` = lowercase (uniqueness +
    # lookup, per-tenant). DELIBERATELY not cast by the changesets below — every write goes through
    # UserService.Usernames (validation, holds, change budget); a generic profile update can't touch them.
    field(:username, :string)
    field(:username_key, :string)

    # The profile's tenant (migration 048). Read-only here — surfaced so the gateway can presign the
    # avatar scoped to the ASSET's app (the /avatar route is unauthenticated → no caller app_id).
    field(:app_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_profile, attrs) do
    user_profile
    |> cast(attrs, [:user_id, :display_name, :avatar_media_id, :avatar_object_key, :bio])
    |> validate_required([:user_id, :display_name])
    |> foreign_key_constraint(:user_id)
  end

  def update_changeset(user_profile, attrs) do
    user_profile
    |> cast(attrs, [:display_name, :avatar_media_id, :avatar_object_key, :bio])
    |> validate_required([:display_name])
  end
end
