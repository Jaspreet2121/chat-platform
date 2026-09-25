defmodule AuthService.Schemas.VerificationCode do
  @moduledoc """
  Ecto schema for the `verification_codes` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # THE ONE LIST of purposes a code may carry. The database CHECK (010, widened in 132) and this
  # changeset are two allow-lists for the same fact, and on 2026-09-25 they disagreed: 132 taught
  # the CHECK about "admin_reauth" and nobody taught this line, so every step-up request died here
  # — a changeset error, no row, no SMS, and a 403 at the gateway in three milliseconds. The
  # accessor exists so a test can pin AdminReauth.purpose/0 against it.
  @purposes ~w(login signup email_verify phone_verify admin_reauth)

  def purposes, do: @purposes

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
    |> validate_inclusion(:purpose, @purposes)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
