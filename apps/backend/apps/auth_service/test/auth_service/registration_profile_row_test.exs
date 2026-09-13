defmodule AuthService.RegistrationProfileRowTest do
  @moduledoc """
  A user never exists without a card (122): the first OTP verify for a new number creates the
  users_auth row AND its user_profiles row in ONE transaction; a later verify is a no-op on it.

  Asserted on the ROW, not on a peer's card fetch: once the read side answers a minimal card for
  any active row-less user, a missing registration insert would be invisible from the card — the
  row is the only thing that proves this path ran.
  """
  use AuthService.DataCase, async: false

  alias AuthService.{OTP, VerificationCodes}

  @real_code "123456"

  setup do
    prev = Application.get_env(:auth_service, :otp_verify_persistence, false)
    Application.put_env(:auth_service, :otp_verify_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :otp_verify_persistence, prev) end)
    :ok
  end

  defp code!(destination) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      VerificationCodes.create_verification_code(%{
        "id" => id,
        "purpose" => "login",
        "destination" => destination,
        "code_hash" => OTP.hash_code(destination, "login", @real_code),
        "attempts" => 0,
        "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second)
      })

    id
  end

  defp verify!(destination) do
    {:ok, %{user_id: user_id}} =
      OTP.verify_otp(%{
        "otp_request_id" => code!(destination),
        "phone_number" => destination,
        "otp_code" => @real_code,
        "device_id" => "device-" <> Integer.to_string(System.unique_integer([:positive])),
        "platform" => "android"
      })

    user_id
  end

  defp profile_rows(user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT display_name, app_id::text, avatar_media_id FROM user_profiles " <>
          "WHERE user_id = $1::text::uuid",
        [user_id]
      )

    rows
  end

  defp account_app(user_id) do
    %{rows: [[app]]} =
      Repo.query!("SELECT app_id::text FROM users_auth WHERE id = $1::text::uuid", [user_id])

    app
  end

  @tag :postgres_integration
  test "the first verify for a NEW number creates the profile row with the account" do
    phone = "+1555#{System.unique_integer([:positive])}"

    user_id = verify!(phone)

    assert [[display_name, app_id, avatar]] = profile_rows(user_id),
           "registration wrote users_auth alone — this user has no card, and every peer's " <>
             "fetch for it is a 404 while the account messages freely"

    assert display_name == nil
    assert avatar == nil
    assert app_id == account_app(user_id), "the profile's tenant must be the account's"
  end

  @tag :postgres_integration
  test "a second verify (re-login) is a no-op on the profile row — a set name survives" do
    phone = "+1555#{System.unique_integer([:positive])}"
    user_id = verify!(phone)

    Repo.query!("UPDATE user_profiles SET display_name = 'Asha' WHERE user_id = $1::text::uuid", [
      user_id
    ])

    assert ^user_id = verify!(phone)
    assert [["Asha", _app, nil]] = profile_rows(user_id)
  end
end
