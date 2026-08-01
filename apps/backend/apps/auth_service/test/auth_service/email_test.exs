defmodule AuthService.EmailTest do
  @moduledoc """
  USER EMAIL (091) — an UNVERIFIED contact detail on users_auth, never an identity.

  Proves: PER-TENANT uniqueness (two tenants CAN hold one address; a duplicate inside one tenant is
  refused with a specific code) and that it is CASE-INSENSITIVE (the gap 091 closed — 048 had already
  scoped email per-tenant, but on the raw value); normalisation on write; the identity-CHECK edge (a
  user may not strip their last identifier); pragmatic validation; and that email is NOT a login
  method (the OTP branch refuses it outright).
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  defp app! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Other', $2)",
      [id, "oth-" <> String.slice(String.replace(id, "-", ""), 0, 12)]
    )

    id
  end

  defp user!(app_id \\ @tenant_zero, opts \\ []) do
    id = Ecto.UUID.generate()
    phone = Keyword.get(opts, :phone, "+1555#{System.unique_integer([:positive])}")
    email = Keyword.get(opts, :email)

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, email, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'active', now(), now())",
      [id, app_id, phone, email]
    )

    id
  end

  defp stored_email(user_id) do
    %{rows: [[email]]} =
      Repo.query!("SELECT email FROM users_auth WHERE id = $1::text::uuid", [user_id])

    email
  end

  @tag :postgres_integration
  test "PER-TENANT: two tenants hold the SAME address; a duplicate inside one tenant is refused" do
    other_app = app!()
    mine = user!()
    theirs = user!(other_app)

    assert {:ok, %{email: "shared@example.com"}} =
             Accounts.update_email(@tenant_zero, mine, "shared@example.com")

    # The SAME address in a DIFFERENT tenant is fine — this is what 048 made possible and what the
    # platform being multi-tenant requires.
    assert {:ok, %{email: "shared@example.com"}} =
             Accounts.update_email(other_app, theirs, "shared@example.com")

    # ...but a second holder inside ONE tenant is refused with a specific code, not a raw constraint.
    neighbour = user!()

    assert {:error, :email_taken} =
             Accounts.update_email(@tenant_zero, neighbour, "shared@example.com")
  end

  @tag :postgres_integration
  test "CASE-INSENSITIVE within a tenant (the gap 091 closed) — and normalised on write" do
    owner = user!()
    assert {:ok, _} = Accounts.update_email(@tenant_zero, owner, "  Bob@Example.COM  ")

    # Stored lowercase and trimmed — one canonical form.
    assert stored_email(owner) == "bob@example.com"

    # A case VARIANT is the same address: refused for a different user in the same tenant.
    neighbour = user!()

    assert {:error, :email_taken} =
             Accounts.update_email(@tenant_zero, neighbour, "BOB@example.com")

    # The owner may re-set their own address in any case — it resolves to the same row.
    assert {:ok, _} = Accounts.update_email(@tenant_zero, owner, "BoB@Example.com")
    assert stored_email(owner) == "bob@example.com"
  end

  @tag :postgres_integration
  test "THE IDENTITY-CHECK EDGE: a phone user may clear it; an email-only user may NOT" do
    with_phone = user!()
    {:ok, _} = Accounts.update_email(@tenant_zero, with_phone, "clearable@example.com")

    # Phone remains → clearing is allowed (both nil and "" mean clear).
    assert {:ok, %{email: nil}} = Accounts.update_email(@tenant_zero, with_phone, nil)
    assert stored_email(with_phone) == nil

    # An EMAIL-ONLY user (no phone, no external_id) must not be able to strip their last identifier —
    # that would be an unrecoverable account. Refused in the domain with a clean code, so the
    # users_auth_identity_check never has to surface as a raw constraint error.
    email_only = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [email_only, @tenant_zero, "only@example.com"]
    )

    assert {:error, :email_last_identifier} =
             Accounts.update_email(@tenant_zero, email_only, nil)

    assert {:error, :email_last_identifier} = Accounts.update_email(@tenant_zero, email_only, "")
    assert stored_email(email_only) == "only@example.com"
  end

  @tag :postgres_integration
  test "validation is PRAGMATIC: obvious rubbish refused, ordinary addresses accepted" do
    owner = user!()

    for bad <- ["not-an-email", "no@domain", "@example.com", "spaces in@example.com", "a@b@c.com"] do
      assert {:error, :email_invalid} = Accounts.update_email(@tenant_zero, owner, bad),
             "#{bad} should be refused"
    end

    assert {:error, :email_invalid} =
             Accounts.update_email(@tenant_zero, owner, String.duplicate("a", 250) <> "@ex.com")

    for good <- [
          "simple@example.com",
          "with+tag@example.co.uk",
          "dots.in.local@sub.example.com",
          "digits123@example.io"
        ] do
      assert {:ok, _} = Accounts.update_email(@tenant_zero, owner, good), "#{good} should be accepted"
    end
  end

  @tag :postgres_integration
  test "EMAIL IS NOT A LOGIN METHOD: the OTP path refuses an email destination outright" do
    owner = user!()
    {:ok, _} = Accounts.update_email(@tenant_zero, owner, "login@example.com")

    # The user lookup happens at VERIFY (find_or_create_user), so that is where the refusal lands.
    # Nobody proved they own this address, and the OTP flow carries no tenant — so it cannot be a
    # destination. Fails closed rather than minting a session for whichever tenant's row it found.
    prev = Application.get_env(:auth_service, :otp_verify_persistence, false)
    Application.put_env(:auth_service, :otp_verify_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :otp_verify_persistence, prev) end)

    otp_request_id = Ecto.UUID.generate()

    {:ok, _} =
      AuthService.VerificationCodes.create_verification_code(%{
        "id" => otp_request_id,
        "purpose" => "login",
        "destination" => "login@example.com",
        "code_hash" => AuthService.OTP.hash_code("login@example.com", "login", "123456"),
        "attempts" => 0,
        "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second)
      })

    assert {:error, :email_login_unsupported} =
             AuthService.OTP.verify_otp(%{
               "otp_request_id" => otp_request_id,
               "email" => "login@example.com",
               "otp_code" => "123456",
               "device_id" => "d1",
               "platform" => "ios"
             })
  end

  @tag :postgres_integration
  test "the app-scoped lookup finds only its OWN tenant's row, case-folded" do
    other_app = app!()
    mine = user!()
    theirs = user!(other_app)

    {:ok, _} = Accounts.update_email(@tenant_zero, mine, "dual@example.com")
    {:ok, _} = Accounts.update_email(other_app, theirs, "dual@example.com")

    # The old 1-arity version would have raised MultipleResultsError on exactly this data.
    assert %{id: ^mine} = Accounts.get_by_email(@tenant_zero, "DUAL@example.com")
    assert %{id: ^theirs} = Accounts.get_by_email(other_app, "dual@EXAMPLE.com")
    assert Accounts.get_by_email(app!(), "dual@example.com") == nil
  end
end
