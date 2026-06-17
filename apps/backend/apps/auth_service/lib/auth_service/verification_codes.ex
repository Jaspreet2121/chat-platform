defmodule AuthService.VerificationCodes do
  @moduledoc """
  Data-access boundary for OTP/verification code persistence.

  This does not generate, deliver, or verify real OTP values yet. Callers must
  provide already-hashed code values.
  """

  import Ecto.Query

  alias AuthService.Repo
  alias AuthService.Schemas.VerificationCode

  def verification_code_changeset(attrs \\ %{}) do
    VerificationCode.changeset(%VerificationCode{}, attrs)
  end

  def create_verification_code(attrs) do
    attrs
    |> verification_code_changeset()
    |> Repo.insert()
  end

  def get_verification_code(id), do: Repo.get(VerificationCode, id)

  def consume_verification_code(%VerificationCode{} = verification_code, attrs) do
    verification_code
    |> VerificationCode.changeset(attrs)
    |> Repo.update()
  end

  def find_active_code(destination, purpose, now \\ DateTime.utc_now()) do
    VerificationCode
    |> where([code], code.destination == ^destination)
    |> where([code], code.purpose == ^purpose)
    |> where([code], is_nil(code.consumed_at))
    |> where([code], code.expires_at > ^now)
    |> order_by([code], desc: code.created_at)
    |> limit(1)
    |> Repo.one()
  end
end
