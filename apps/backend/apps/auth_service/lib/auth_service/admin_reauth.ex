defmodule AuthService.AdminReauth do
  @moduledoc """
  STEP-UP RE-AUTH for the irreversible admin actions (132).

  Ban, permanent delete, and a role change touching root/admin are one API call away from a console
  session that was opened with an ordinary login and may have been sitting unattended for hours. This
  makes those three prove possession of the acting admin's OWN phone within the last five minutes.

  ## The proof is a token, and it is bound to the admin who earned it

  `request/1` sends an OTP to the admin's registered number under purpose `admin_reauth` — its own
  purpose, so a step-up code can never be spent as a login and a login code can never be spent as a
  step-up. `verify/1` checks it through the login verifier's own primitives (same brute-force cap,
  same charge-before-check ordering, same expiry) and mints a signed token carrying
  `typ: "admin_reauth"`, `sub: <the admin's user id>` and a five-minute expiry.

  `verify_token/2` then requires BOTH that the signature and expiry hold AND that `sub` is the
  caller. That second half is the point: a token is a proof about a person, not a key that opens the
  door for whoever is holding it. Another admin's valid token is refused.

  The OTP is consumed on success, so the proof cannot be replayed inside its own TTL either.
  """

  alias AuthService.OTP
  alias AuthService.Repo
  alias AuthService.Tokens

  require Logger

  @purpose "admin_reauth"
  # Five minutes: long enough to read a confirmation dialog and type a number, short enough that a
  # walk-away between the proof and the action does not hand somebody a live one.
  @ttl_seconds 300

  @doc "How long a step-up proof is good for, in seconds."
  def ttl_seconds, do: @ttl_seconds

  @doc "The OTP purpose reserved for step-up. Never `login`."
  def purpose, do: @purpose

  @doc """
  Send a step-up code to the acting admin's OWN registered phone. attrs: "user_id".

  The destination is read from the database, never from the request: an admin cannot nominate where
  their own step-up code is delivered, which is the whole security property.
  """
  def request(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, destination} <- admin_destination(user_id) do
      OTP.request_otp(%{"phone_number" => destination, "purpose" => @purpose})
    end
  rescue
    _ -> {:error, :reauth_unavailable}
  end

  @doc """
  Verify the step-up code and mint the proof. attrs: "user_id", "otp_request_id", "otp_code".

  The destination is read from the database again — the caller supplies only the request id and the
  code, so a caller cannot verify a code that was sent to a different number.
  """
  def verify(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, otp_request_id} <- required(attrs, "otp_request_id"),
         {:ok, otp_code} <- required(attrs, "otp_code"),
         {:ok, destination} <- admin_destination(user_id),
         {:ok, _} <-
           OTP.verify_code_only(%{
             "phone_number" => destination,
             "otp_request_id" => otp_request_id,
             "otp_code" => otp_code,
             "purpose" => @purpose
           }) do
      expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

      {:ok, token} =
        Tokens.sign_claims(%{
          "typ" => @purpose,
          "sub" => user_id,
          "exp" => DateTime.to_unix(expires_at)
        })

      Logger.info("admin step-up verified for #{String.slice(user_id, 0, 8)}…")

      {:ok,
       %{
         reauth_token: token,
         expires_in_seconds: @ttl_seconds,
         expires_at: DateTime.to_iso8601(expires_at)
       }}
    end
  end

  @doc """
  Is `token` a live step-up proof belonging to `user_id`?

  Returns `:ok` or `{:error, :reauth_required}`. EVERY failure collapses to that one reason —
  missing, malformed, expired, wrong type, someone else's. A caller learns only that they need to
  step up again, never which part of the token was wrong.
  """
  def verify_token(token, user_id) when is_binary(token) and is_binary(user_id) and token != "" do
    case Tokens.verify_signed_token(token) do
      {:ok, %{"typ" => @purpose, "sub" => ^user_id}} -> :ok
      _ -> {:error, :reauth_required}
    end
  end

  def verify_token(_token, _user_id), do: {:error, :reauth_required}

  # The acting admin's registered phone, from the database. Never from the request.
  defp admin_destination(user_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT phone_number FROM users_auth WHERE id = $1::text::uuid AND status = 'active'",
        [user_id]
      )

    case rows do
      [[phone]] when is_binary(phone) and phone != "" -> {:ok, phone}
      _ -> {:error, :reauth_no_destination}
    end
  rescue
    _ -> {:error, :reauth_no_destination}
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end
end
