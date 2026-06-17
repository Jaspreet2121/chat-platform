defmodule UserService.Schemas.UserSettings do
  @moduledoc """
  Ecto schema for the `user_settings` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:user_id, :binary_id, autogenerate: false}

  schema "user_settings" do
    field(:locale, :string, default: "en")
    field(:timezone, :string, default: "UTC")
    field(:settings, :map, default: %{})
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_settings, attrs) do
    user_settings
    |> cast(attrs, [:user_id, :locale, :timezone, :settings])
    |> validate_required([:user_id, :locale, :timezone, :settings])
    |> foreign_key_constraint(:user_id)
  end

  def update_changeset(user_settings, attrs) do
    user_settings
    |> cast(attrs, [:locale, :timezone, :settings])
    |> validate_required([:locale, :timezone, :settings])
  end
end
