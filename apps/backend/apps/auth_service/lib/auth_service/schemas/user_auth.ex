defmodule AuthService.Schemas.UserAuth do
  @moduledoc """
  Ecto schema for the `users_auth` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "users_auth" do
    # The app (tenant) this identity belongs to (migration 048).
    field(:app_id, :binary_id)
    field(:phone_number, :string)
    field(:email, :string)

    # Integrator-supplied opaque end-user id, unique per (app_id, external_id) (migration 050). Lets a
    # token-exchange map an external end-user to a stable user row within the app.
    field(:external_id, :string)
    field(:password_hash, :string)
    field(:status, :string, default: "active")
    field(:is_admin, :boolean, default: false)
    # IAM role (migration 058). One role per user; permission bundles live in SharedInfra.IAM.
    field(:role, :string, default: "user")
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_auth, attrs) do
    user_auth
    |> cast(attrs, [
      :id,
      :app_id,
      :phone_number,
      :email,
      :external_id,
      :password_hash,
      :status,
      :is_admin,
      :role
    ])
    |> validate_required([:status])
    |> validate_contact()
    |> validate_inclusion(:status, ["active", "suspended", "deleted"])
    |> validate_inclusion(:role, SharedInfra.IAM.roles())
    |> unique_constraint(:phone_number)
    |> unique_constraint(:email)
    |> unique_constraint(:external_id, name: :users_auth_app_external_id_key)
  end

  defp validate_contact(changeset) do
    if present?(get_field(changeset, :phone_number)) or present?(get_field(changeset, :email)) or
         present?(get_field(changeset, :external_id)) do
      changeset
    else
      add_error(changeset, :phone_number, "phone_number, email, or external_id is required")
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""
end
