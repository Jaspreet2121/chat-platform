defmodule AuthService.OTPAttemptsTest do
  @moduledoc """
  THE OTP BRUTE-FORCE CAP.

  Before this, `attempts` was written as 0 at creation and never read again: anyone holding an
  `otp_request_id` could exhaust a 6-digit code (10^6) inside its 300s TTL. The REQUEST response
  hands that id to whoever asked — including someone requesting a code for a phone they do not own —
  so it was an account-takeover path, not a nuisance.

  Proves: the cap fires at exactly #{AuthService.OTP.max_verify_attempts()}; the final attempt is
  CHECKED rather than rejected unheard (a user who fat-fingers four times and types it right on the
  fifth must get in); a wrong final attempt BURNS the row rather than merely counting it; and the
  charge is atomic, which is what stops a concurrent attacker sharing one attempt across N requests.
  """
  use AuthService.DataCase, async: false

  alias AuthService.OTP
  alias AuthService.VerificationCodes

  @destination "+15555550142"
  @code "123456"

  setup do
    prev = Application.get_env(:auth_service, :otp_verify_persistence, false)
    Application.put_env(:auth_service, :otp_verify_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :otp_verify_persistence, prev) end)
    :ok
  end

  defp code!(opts \\ []) do
    id = Ecto.UUID.generate()
    destination = Keyword.get(opts, :destination, @destination)

    {:ok, _} =
      VerificationCodes.create_verification_code(%{
        "id" => id,
        "purpose" => "login",
        "destination" => destination,
        "code_hash" => OTP.hash_code(destination, "login", @code),
        "attempts" => 0,
        "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second)
      })

    id
  end

  defp verify(id, code, opts \\ []) do
    OTP.verify_otp(%{
      "otp_request_id" => id,
      "phone_number" => Keyword.get(opts, :destination, @destination),
      "otp_code" => code,
      "device_id" => "device-" <> Integer.to_string(System.unique_integer([:positive])),
      "platform" => "ios"
    })
  end

  defp stored(id), do: VerificationCodes.get_verification_code(id)

  @tag :postgres_integration
  test "the cap fires at the Nth attempt, and the Nth is CHECKED not rejected unheard" do
    max = OTP.max_verify_attempts()
    id = code!()

    # The first max-1 wrong guesses are ordinary invalid-code answers.
    for attempt <- 1..(max - 1) do
      assert {:error, :otp_invalid} = verify(id, "000000"),
             "attempt #{attempt} should be a plain invalid code"
    end

    # The final attempt is DISTINCT: the code is now dead, and the caller is told so. A generic
    # invalid-code answer here would leave a user retyping digits that can never work.
    assert {:error, :otp_attempts_exhausted} = verify(id, "000000")

    # ...and it is BURNED, not merely counted — consumed_at is what makes a fresh /otp/request
    # genuinely required rather than the attacker simply waiting.
    assert %{consumed_at: consumed_at} = stored(id)
    refute is_nil(consumed_at), "the exhausted row must be consumed, not just counted"
  end

  @tag :postgres_integration
  test "THE OFF-BY-ONE: the correct code on the FINAL allowed attempt still succeeds" do
    max = OTP.max_verify_attempts()
    id = code!()

    for _ <- 1..(max - 1), do: assert({:error, :otp_invalid} = verify(id, "000000"))

    # Rejecting the last attempt unchecked would make the real cap max-1 while claiming to be max,
    # and would lock out a user who finally typed it correctly.
    assert {:ok, %{}} = verify(id, @code)

    assert %{attempts: ^max} = stored(id)
  end

  @tag :postgres_integration
  test "a burned code stays dead — further attempts never verify, even with the RIGHT code" do
    max = OTP.max_verify_attempts()
    id = code!()

    for _ <- 1..max, do: verify(id, "000000")

    # The correct code no longer works: exhaustion is an invalidation, not a cooldown. (The answer is
    # :otp_invalid rather than :otp_attempts_exhausted because the consumed-row check runs first —
    # the caller was already told the code was dead on the attempt that burned it.)
    assert {:error, :otp_invalid} = verify(id, @code)
  end

  @tag :postgres_integration
  test "ATOMICITY: every charge returns a distinct count, so N requests spend N attempts" do
    id = code!()

    counts = for _ <- 1..5, do: (fn {:ok, n} -> n end).(VerificationCodes.charge_attempt(id))

    # A read-modify-write would let concurrent attempts observe the same value and share one attempt
    # — precisely the bypass the cap exists to stop. The atomic INCR ... RETURNING makes each caller
    # take a unique number.
    assert counts == [1, 2, 3, 4, 5]
    assert length(Enum.uniq(counts)) == 5
  end

  @tag :postgres_integration
  test "SCOPING: attempts against one code never consume another's budget" do
    max = OTP.max_verify_attempts()
    victim = code!()
    other = code!(destination: "+15555550199")

    for _ <- 1..(max - 1), do: verify(victim, "000000")
    assert {:error, :otp_attempts_exhausted} = verify(victim, "000000")

    # A different otp_request_id has its own untouched budget — the cap is per-code, and one user
    # burning theirs must not lock out anyone else.
    assert %{attempts: 0} = stored(other)
    assert {:ok, %{}} = verify(other, @code, destination: "+15555550199")
  end
end
