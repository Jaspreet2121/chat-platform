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
