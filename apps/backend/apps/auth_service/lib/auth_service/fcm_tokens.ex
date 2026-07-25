defmodule AuthService.FcmTokens do
  @moduledoc """
  FCM device-token storage (Phase 2, Android) — the token twin of `AuthService.PushSubscriptions`.

  An FCM registration token is a per-INSTALLATION device credential, so it lives with identity:
  UPSERT by the globally-unique token (re-registering the same token updates owner/device), DELETE
  by token scoped to the CALLER's own rows. The notification service reads this table directly to
  deliver; nothing here sends anything.

  RE-SIGN-IN: a device that logs in as a different account re-registers its SAME token, so the
  conflict update MOVES the row to the new user. That is the point — leaving the old row would keep
  delivering the previous account's messages to a phone that is now signed in as someone else.

  `delete_tokens/1` is the pruning path used by the notification service when FCM reports a token
  as dead; it is deliberately NOT user-scoped (a dead token is dead for whoever owns it).
  """

  alias AuthService.Repo

  @default_platform "android"

  def upsert_token(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, token} <- required(attrs, "token") do
      if persistence_enabled?() do
        Repo.query!(
          "INSERT INTO fcm_tokens (user_id, token, device_id, platform) " <>
            "VALUES ($1::text::uuid, $2, $3, $4) " <>
            "ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, " <>
            "device_id = EXCLUDED.device_id, platform = EXCLUDED.platform, updated_at = now()",
          [user_id, token, attrs["device_id"], platform(attrs)]
        )
      end

      {:ok, %{saved: true}}
    end
  rescue
    _ -> {:error, :auth_invalid}
  end

  def delete_token(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, token} <- required(attrs, "token") do
      if persistence_enabled?() do
        Repo.query!(
          "DELETE FROM fcm_tokens WHERE token = $1 AND user_id = $2::text::uuid",
          [token, user_id]
        )
      end

      {:ok, %{deleted: true}}
    end
  rescue
    _ -> {:error, :auth_invalid}
  end

  @doc """
  Every registration token for a user. Read side for the delivery leg; best-effort — on any error
  the caller gets `[]` and simply sends nothing, never a crash inside a fan-out.
  """
  def tokens_for_user(user_id) when is_binary(user_id) do
    case Repo.query(
           "SELECT token FROM fcm_tokens WHERE user_id = $1::text::uuid",
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [token] -> token end)
      _ -> []
    end
  rescue
    _ -> []
  end

  def tokens_for_user(_user_id), do: []

  @doc """
  Prune tokens FCM has told us are dead (UNREGISTERED / INVALID_ARGUMENT). NOT user-scoped on
  purpose: the token itself is what FCM rejected, so it is dead for whoever currently owns it.
  """
  def delete_tokens([]), do: {:ok, %{deleted: 0}}

  def delete_tokens(tokens) when is_list(tokens) do
    valid = Enum.filter(tokens, &(is_binary(&1) and &1 != ""))

    if valid == [] do
      {:ok, %{deleted: 0}}
    else
      %{num_rows: n} = Repo.query!("DELETE FROM fcm_tokens WHERE token = ANY($1)", [valid])
      {:ok, %{deleted: n}}
    end
  rescue
    _ -> {:error, :auth_invalid}
  end

  # Only ever a known platform label — an arbitrary client string must not reach the column.
  defp platform(attrs) do
    case attrs["platform"] do
      value when value in ["android", "ios", "web"] -> value
      _ -> @default_platform
    end
  end

  defp required(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp persistence_enabled?, do: AuthService.Sessions.persistence_enabled?()
end
