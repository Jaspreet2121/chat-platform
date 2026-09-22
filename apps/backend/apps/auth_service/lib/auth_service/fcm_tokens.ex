defmodule AuthService.FcmTokens do
  @moduledoc """
  FCM device-token storage (Phase 2, Android) — the token twin of `AuthService.PushSubscriptions`.

  An FCM registration token is a per-INSTALLATION device credential, so it lives with identity —
  and since 121 the row is keyed on the DEVICE: one row per (user_id, device_id), UNIQUE and NOT
  NULL. A rotated token for a device that already has a row UPDATES that row; before 121 the
  upsert was keyed on the token, so every rotation added a second row for the same handset and
  nothing ever removed the first (prod: three rows, three tokens, one phone). DELETE by token stays
  scoped to the CALLER's own rows. The notification service reads this table directly to deliver;
  nothing here sends anything.

  RE-SIGN-IN: a device that logs in as a different account re-registers its SAME token. The row it
  held under the previous account is removed first and the new (user, device) row takes the token —
  leaving the old row would keep delivering the previous account's messages to a phone that is now
  signed in as someone else. `token` stays UNIQUE, and that pre-delete is what keeps a token moving
  between devices or accounts from tripping it.

  `delete_tokens/1` is the pruning path used by the notification service when FCM reports a token
  as dead; it is deliberately NOT user-scoped (a dead token is dead for whoever owns it).
  """

  alias AuthService.Repo

  @default_platform "android"

  def upsert_token(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, token} <- required(attrs, "token"),
         # NOT NULL since 121: a row that names no device can never be addressed again. The gateway
         # supplies this from the SESSION, never from the client's body.
         {:ok, device_id} <- required(attrs, "device_id") do
      if persistence_enabled?() do
        {:ok, _} =
          Repo.transaction(fn ->
            # THE TOKEN-MOVE CASE, handled before it can raise. `token` is still UNIQUE, so a token
            # arriving for a DIFFERENT (user, device) than the one it currently sits on — a re-sign-in
            # on the same handset, or the same handset registering a fresh device id — would make the
            # device-keyed upsert below trip the token index. Remove the row the token occupies unless
            # it is already exactly this (user, device), which is a plain refresh for the ON CONFLICT.
            Repo.query!(
              "DELETE FROM fcm_tokens WHERE token = $1 " <>
                "AND NOT (user_id = $2::text::uuid AND device_id = $3)",
              [token, user_id, device_id]
            )

            # ON CONFLICT ON THE SAME EXPRESSION THE UNIQUE INDEX USES (129). An iPhone registers
            # TWO credentials for one device — an alert token and a VoIP token — so the key is
            # (user, device, kind), and COALESCE is what keeps every Android row (kind NULL)
            # collapsing to a single key instead of inserting a new row per re-registration.
            Repo.query!(
              "INSERT INTO fcm_tokens (user_id, token, device_id, platform, kind, environment) " <>
                "VALUES ($1::text::uuid, $2, $3, $4, $5, $6) " <>
                "ON CONFLICT (user_id, device_id, COALESCE(kind, '')) DO UPDATE SET " <>
                "token = EXCLUDED.token, platform = EXCLUDED.platform, " <>
                "environment = EXCLUDED.environment, updated_at = now()",
              [user_id, token, device_id, platform(attrs), kind(attrs), environment(attrs)]
            )
          end)
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

  # APNs CHANNEL (129). NULL for anything that is not iOS: Android and web have one push channel and
  # a value there would only invent a distinction the senders do not have. An iOS registration with
  # no kind defaults to `alert` rather than being rejected — the alert channel is the one an app
  # registers first and the one a client that predates VoIP support would send.
  defp kind(attrs) do
    case {platform(attrs), attrs["kind"]} do
      {"ios", value} when value in ["alert", "voip"] -> value
      {"ios", _} -> "alert"
      _ -> nil
    end
  end

  # SANDBOX OR PRODUCTION, and the client is the only thing that knows. The same device token is
  # valid at exactly one APNs host, decided by how the APP was signed — a TestFlight build and an App
  # Store build of one binary differ here — not by how the server was deployed. An iOS registration
  # that does not say defaults to `production`: a missing value on a shipped build is far more likely
  # to be a release than a debug build, and sandbox is the one a reviewer would set explicitly.
  defp environment(attrs) do
    case {platform(attrs), attrs["environment"]} do
      {"ios", value} when value in ["sandbox", "production"] -> value
      {"ios", _} -> "production"
      _ -> nil
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
