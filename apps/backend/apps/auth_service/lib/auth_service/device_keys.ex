defmodule AuthService.DeviceKeys do
  @moduledoc """
  Device PUBLIC-key registry (107) — the offline-messaging foundation. One row per (user, device):
  an ed25519 signing key + an x25519 agreement key, exactly 32 bytes each, bound to the SESSION's
  device_id (never client-claimed). Re-upload rotates in place (updated_at moves). Nothing secret
  is ever stored.

  The FETCH is membership-gated AT THE STORE: a caller sees keys only for users they share a live
  conversation with (or themself — their own other devices), same app, and only NON-REVOKED
  devices. Anyone else is SILENTLY OMITTED from the result — absence is indistinguishable from
  "no keys uploaded", so the endpoint is not an existence oracle.
  """

  alias AuthService.Repo

  @key_bytes 32
  @max_fetch_ids 50

  def save_keys(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, device_id} <- required(attrs, "device_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, ed25519} <- key_of(attrs, "ed25519_public"),
         {:ok, x25519} <- key_of(attrs, "x25519_public") do
      # `changed` drives the secret-chat keys_changed system message (108): a first upload or a
      # byte-different key is a change; re-uploading identical keys is not (no spam).
      %{rows: previous} =
        Repo.query!(
          "SELECT ed25519_public, x25519_public FROM device_keys " <>
            "WHERE user_id = $1::text::uuid AND device_id = $2",
          [user_id, device_id]
        )

      changed =
        case previous do
          [[^ed25519, ^x25519]] -> false
          _ -> true
        end

      Repo.query!(
        """
        INSERT INTO device_keys (user_id, device_id, app_id, ed25519_public, x25519_public)
        VALUES ($1::text::uuid, $2, $3::text::uuid, $4, $5)
        ON CONFLICT (user_id, device_id) DO UPDATE SET
          app_id = EXCLUDED.app_id,
          ed25519_public = EXCLUDED.ed25519_public,
          x25519_public = EXCLUDED.x25519_public,
          updated_at = now()
        """,
        [user_id, device_id, app_id, ed25519, x25519]
      )

      {:ok, %{saved: true, changed: changed}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :device_keys_invalid}
    _error in Postgrex.Error -> {:error, :device_keys_invalid}
  end

  @doc """
  Keys for the requested users, MEMBERSHIP-GATED (see moduledoc): per admitted user, their active
  devices' public keys. Requested users the caller may not see are simply absent from the result.
  """
  def fetch_keys(attrs) do
    with {:ok, caller_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, ids} <- ids_of(attrs) do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT k.user_id::text, k.device_id, ds.platform,
                 k.ed25519_public, k.x25519_public, k.updated_at
          FROM (SELECT DISTINCT (t.id)::uuid AS id FROM unnest($3::text[]) AS t(id)) requested
          JOIN device_keys k ON k.user_id = requested.id
          JOIN users_auth a ON a.id = requested.id
            AND a.app_id = $2::text::uuid AND a.status = 'active'
          -- Only keys for LIVE devices: a revoked session's keys disappear with it.
          JOIN device_sessions ds ON ds.user_id = k.user_id AND ds.device_id = k.device_id
            AND ds.revoked_at IS NULL
          WHERE k.app_id = $2::text::uuid
            -- MEMBERSHIP GATE (store level): self, or a live shared conversation. Everyone else is
            -- silently omitted — no existence oracle.
            AND (requested.id = $1::text::uuid OR EXISTS (
              SELECT 1 FROM conversation_participants mine
              JOIN conversation_participants theirs
                ON theirs.conversation_id = mine.conversation_id
              WHERE mine.user_id = $1::text::uuid AND mine.left_at IS NULL
                AND theirs.user_id = requested.id AND theirs.left_at IS NULL
            ))
          ORDER BY k.user_id, k.device_id
          """,
          [caller_id, app_id, ids]
        )

      users =
        rows
        |> Enum.group_by(fn [user_id | _] -> user_id end)
        |> Enum.map(fn {user_id, device_rows} ->
          %{
            user_id: user_id,
            devices:
              Enum.map(device_rows, fn [_uid, device_id, platform, ed, x, updated_at] ->
                %{
                  device_id: device_id,
                  platform: platform,
                  ed25519_public: Base.encode64(ed),
                  x25519_public: Base.encode64(x),
                  # Safety-number convenience (108): sha256 of the SIGNING key, hex — what clients
                  # display; deriving client-side from ed25519_public gives the same value.
                  key_fingerprint: Base.encode16(:crypto.hash(:sha256, ed), case: :lower),
                  updated_at: iso(updated_at)
                }
              end)
          }
        end)

      {:ok, %{users: users}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :device_keys_invalid}
    _error in Postgrex.Error -> {:error, :device_keys_invalid}
  end

  defp key_of(attrs, field) do
    with value when is_binary(value) <- Map.get(attrs, field),
         {:ok, decoded} <- Base.decode64(value),
         true <- byte_size(decoded) == @key_bytes do
      {:ok, decoded}
    else
      _ -> {:error, :device_keys_invalid}
    end
  end

  defp ids_of(attrs) do
    case Map.get(attrs, "ids") do
      list when is_list(list) and list != [] and length(list) <= @max_fetch_ids ->
        if Enum.all?(list, &(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1)))),
          do: {:ok, list},
          else: {:error, :device_keys_invalid}

      _ ->
        {:error, :device_keys_invalid}
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :device_keys_invalid}
    end
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso(value), do: to_string(value)
end
