defmodule AuthService.AdminReauthTest do
  @moduledoc """
  Step-up re-auth (132). Ban, permanent delete and a privileged role change are one API call from a
  console session that may have been unattended for hours; this is the proof that it is really the
  admin sitting there.

  The three properties that matter, and the three mutations that must break them:
    * no proof at all is refused;
    * an EXPIRED proof is refused — a walk-away between proving and acting must not count;
    * ANOTHER ADMIN'S valid proof is refused — a token is a statement about a person, not a key.
  """
  use AuthService.DataCase, async: false

  alias AuthService.AdminReauth
  alias AuthService.Tokens

  @tenant "00000000-0000-0000-0000-000000000001"

  defp admin! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, role, is_admin) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', 'root', true)",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp proof_for(user_id, expires_in_seconds) do
    {:ok, token} =
      Tokens.sign_claims(%{
        "typ" => "admin_reauth",
        "sub" => user_id,
        "exp" =>
          DateTime.utc_now() |> DateTime.add(expires_in_seconds, :second) |> DateTime.to_unix()
      })

    token
  end

  @tag :postgres_integration
  test "a fresh proof minted for THIS admin is accepted" do
    admin = admin!()
    assert :ok = AdminReauth.verify_token(proof_for(admin, 300), admin)
  end

  @tag :postgres_integration
  test "NO proof is refused — and every shape of 'no proof' answers the same reason" do
    admin = admin!()

    for token <- ["", "not-a-token", "v1.garbage.sig"] do
      assert {:error, :reauth_required} = AdminReauth.verify_token(token, admin)
    end

    assert {:error, :reauth_required} = AdminReauth.verify_token(nil, admin)
  end

  @tag :postgres_integration
  test "an EXPIRED proof is refused — walking away between proving and acting must not count" do
    admin = admin!()
    assert {:error, :reauth_required} = AdminReauth.verify_token(proof_for(admin, -1), admin)
  end

  @tag :postgres_integration
  test "ANOTHER ADMIN'S valid proof is refused — a proof is about a person, not a door key" do
    alice = admin!()
    bob = admin!()

    # Bob's token is perfectly valid and unexpired. It still must not let Alice act.
    bobs_proof = proof_for(bob, 300)
    assert :ok = AdminReauth.verify_token(bobs_proof, bob)
    assert {:error, :reauth_required} = AdminReauth.verify_token(bobs_proof, alice)
  end

  @tag :postgres_integration
  test "a SESSION token is not a step-up proof — the types are not interchangeable" do
    admin = admin!()

    {:ok, session_shaped} =
      Tokens.sign_claims(%{
        "typ" => "access",
        "sub" => admin,
        "exp" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      })

    assert {:error, :reauth_required} = AdminReauth.verify_token(session_shaped, admin)
  end

  @tag :postgres_integration
  test "the OTP rides its own purpose — a step-up code is never a login code" do
    assert AdminReauth.purpose() == "admin_reauth"
    assert AdminReauth.ttl_seconds() == 300
  end
end
