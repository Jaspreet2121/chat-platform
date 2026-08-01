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

  @doc """
  ATOMICALLY charge one verify attempt against this code, returning `{:ok, new_count}`.

  Atomic (`UPDATE ... SET attempts = attempts + 1 RETURNING attempts`) rather than read-modify-write
  BECAUSE THIS IS THE BRUTE-FORCE COUNTER: a concurrent attacker firing N verifies at one
  `otp_request_id` must consume N distinct counts. A read-then-write would let them all read the same
  value and share a single attempt, which is precisely the bypass the cap exists to stop.
  """
  def charge_attempt(id) do
    {1, [attempts]} =
      Repo.update_all(
        from(code in VerificationCode, where: code.id == ^id, select: code.attempts),
        inc: [attempts: 1]
      )

    {:ok, attempts}
  rescue
    # Unknown/malformed id → no row to charge. The caller has already resolved the row, so this is
    # only reachable on a concurrent delete; treat it as "no attempts left" (fails closed).
    _ -> {:error, :otp_invalid}
  end

  @doc """
  Burn a code so it can never be verified again — the exhausted-attempts kill switch.

  Sets `consumed_at`, which `valid_verification_code?/4` already rejects. This is what makes the cap
  a real invalidation rather than a counter someone can wait out: the row is DEAD, and only a fresh
  `/otp/request` can produce a working code.
  """
  def burn_verification_code(id, now \\ DateTime.utc_now()) do
    Repo.update_all(
      from(code in VerificationCode, where: code.id == ^id, where: is_nil(code.consumed_at)),
      set: [consumed_at: now]
    )

    :ok
  rescue
    _ -> :ok
  end

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
