defmodule AuthService.Schemas.VerificationCode do
  @moduledoc """
  Ecto schema for the `verification_codes` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "verification_codes" do
    field(:purpose, :string)
    field(:destination, :string)
    field(:code_hash, :string)
    field(:attempts, :integer, default: 0)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(verification_code, attrs) do
    verification_code
    |> cast(attrs, [:id, :purpose, :destination, :code_hash, :attempts, :expires_at, :consumed_at])
    |> validate_required([:purpose, :destination, :code_hash, :expires_at])
    |> validate_inclusion(:purpose, ["login", "signup", "email_verify", "phone_verify"])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
