defmodule AuthService.Invites do
  @moduledoc """
  WhatsApp-style invites: when a searched phone number isn't on the platform, the frontend offers
  "Invite on WhatsApp / via SMS" with a pre-filled message containing an invite link. Sending happens
  entirely on the inviter's DEVICE (wa.me / sms: URL schemes) — this module only mints + records the
  invite code so the link is stable per (inviter, phone) and acceptance can be tracked later.

  `create_invite/1` is idempotent per pending pair: the same inviter inviting the same number gets the
  SAME code back (unique partial index on (inviter_user_id, invited_phone) WHERE accepted_at IS NULL).

  When auth persistence is disabled (placeholder/dev mode) a random code is returned without recording —
  the invite link still works (it just lands on login), there's simply no tracking row.
  """

  alias AuthService.Repo

  # 10 chars of base32 (no padding) ≈ 50 bits — unguessable enough for an invite deep-link.
  @code_bytes 7

  def create_invite(attrs) do
    with {:ok, inviter} <- require_attr(attrs, "inviter_user_id"),
         {:ok, phone} <- require_attr(attrs, "invited_phone") do
      if AuthService.Sessions.persistence_enabled?() do
        {:ok, %{invite_code: upsert_invite(inviter, phone)}}
      else
        {:ok, %{invite_code: generate_code()}}
      end
    end
  end

  # Reuse the pending invite for this (inviter, phone) pair; mint a new code otherwise. The partial
  # unique index makes the insert race-safe: ON CONFLICT falls back to the existing row's code.
  defp upsert_invite(inviter_user_id, invited_phone) do
    code = generate_code()

    %Postgrex.Result{rows: [[stored_code]]} =
      Repo.query!(
        "INSERT INTO invites (code, inviter_user_id, invited_phone) VALUES ($1, $2, $3) " <>
          "ON CONFLICT (inviter_user_id, invited_phone) WHERE accepted_at IS NULL " <>
          "DO UPDATE SET invited_phone = EXCLUDED.invited_phone " <>
          "RETURNING code",
        [code, uuid_param(inviter_user_id), invited_phone]
      )

    stored_code
  end

  defp generate_code do
    @code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end

  defp require_attr(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end
end
