defmodule AuthService.Schemas.UserAuth do
  @moduledoc """
  Ecto schema for the `users_auth` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "users_auth" do
    field(:phone_number, :string)
    field(:email, :string)
    field(:password_hash, :string)
    field(:status, :string, default: "active")
    field(:is_admin, :boolean, default: false)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_auth, attrs) do
    user_auth
    |> cast(attrs, [:id, :phone_number, :email, :password_hash, :status, :is_admin])
    |> validate_required([:status])
    |> validate_contact()
    |> validate_inclusion(:status, ["active", "suspended", "deleted"])
    |> unique_constraint(:phone_number)
    |> unique_constraint(:email)
  end

  defp validate_contact(changeset) do
    if present?(get_field(changeset, :phone_number)) or present?(get_field(changeset, :email)) do
      changeset
    else
      add_error(changeset, :phone_number, "phone_number or email is required")
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""
end
