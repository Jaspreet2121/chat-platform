defmodule AuthService.AdminReauthRequestTest do
  @moduledoc """
  The step-up REQUEST, end to end, against real Postgres — the half nothing had tested.

  `AdminReauthTest` proves what a minted token means. It never calls `AdminReauth.request/1`, and
  that gap is exactly where production failed: migration 132 taught the database CHECK about the
  `admin_reauth` purpose, but `VerificationCode.changeset/2` carried its OWN allow-list and nobody
  widened it. Every request died as a changeset error before a row or an SMS existed, and the
  gateway's catch-all turned it into 403 `admin.reauth_failed` in three milliseconds. Two allow-lists
  for one fact, and a test that only exercised one of them.

  So this goes the whole way: request → a stored code under the right purpose → verify → a proof
  that `verify_token/2` accepts. If either list forgets the purpose again, it fails here.
  """
  use AuthService.DataCase, async: false

  alias AuthService.AdminReauth
  alias AuthService.Schemas.VerificationCode

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    keys = [:otp_request_persistence, :otp_verify_persistence, :otp_delivery_mode]
    previous = Map.new(keys, &{&1, Application.get_env(:auth_service, &1)})

    # Real rows, and the plaintext code echoed back the way a local/staging box gets it — there is
    # no handset in a test, and the point is the DATABASE path, not the SMS provider.
    Application.put_env(:auth_service, :otp_request_persistence, true)
    Application.put_env(:auth_service, :otp_verify_persistence, true)
    Application.put_env(:auth_service, :otp_delivery_mode, "echo")

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:auth_service, key),
          else: Application.put_env(:auth_service, key, value)
      end
    end)

    :ok
  end

  defp admin!(phone) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, role) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', 'root')",
      [id, @tenant, phone]
    )

    id
  end

  test "the changeset's purpose list and the step-up purpose agree" do
    # The single fact the outage came from, pinned as a fact rather than as behaviour.
    assert AdminReauth.purpose() in VerificationCode.purposes()
  end

  @tag :postgres_integration
  test "request stores a code under admin_reauth, verify mints a proof, and the proof is accepted" do
    admin = admin!("+15550199777")

    assert {:ok, %{otp_request_id: request_id, debug_code: code}} =
             AdminReauth.request(%{"user_id" => admin})

    # A REAL ROW exists, under the step-up purpose — this is the line that was never reached.
    %Postgrex.Result{rows: [[purpose, destination]]} =
      Repo.query!(
        "SELECT purpose, destination FROM verification_codes WHERE id = $1::text::uuid",
        [request_id]
      )

    assert purpose == "admin_reauth"
    # The destination came from the database, never from the request.
    assert destination == "+15550199777"

    assert {:ok, %{reauth_token: token, expires_in_seconds: 300}} =
             AdminReauth.verify(%{
               "user_id" => admin,
               "otp_request_id" => request_id,
               "otp_code" => code
             })

    assert AdminReauth.verify_token(token, admin) == :ok
  end

  @tag :postgres_integration
  test "the response carries the request id and never the destination or the code hash" do
    admin = admin!("+15550199778")
    {:ok, response} = AdminReauth.request(%{"user_id" => admin})

    assert is_binary(response.otp_request_id)
    refute Map.has_key?(response, :destination)
    refute Map.has_key?(response, :phone_number)
    refute Map.has_key?(response, :code_hash)
  end

  @tag :postgres_integration
  test "an admin with no phone on file is told so, not given a generic failure" do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, status, role) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', 'admin')",
      [id, @tenant, "noreply-#{System.unique_integer([:positive])}@example.test"]
    )

    # The fix is administrative (give them a number), not a retry — the code says which.
    assert AdminReauth.request(%{"user_id" => id}) == {:error, :reauth_no_destination}
  end
end
