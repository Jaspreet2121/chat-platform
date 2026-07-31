defmodule AuthService.Devices do
  @moduledoc """
  Linked devices — the management surface over EXISTING per-device machinery (device_sessions rows,
  refresh rotation, revocation): list the caller's signed-in devices and sign any of them out. No new
  session mechanics; this is a read + revoke boundary. (The register/get/touch stubs below predate this
  and remain contract placeholders.)

  REVOCATION IS IMMEDIATE ON THE REST PATH: `Sessions.current_session` already loads the device_session
  row on every validated request and rejects `revoked_at IS NOT NULL`, so marking the row here kills the
  device's next API call (and its refresh) — no access-token grace window, no new hot-path lookup.
  The residual window is the REALTIME socket: authenticated at connect, an already-open socket lives
  until it disconnects. That window differs by client: Android drops its socket when backgrounded, so a
  revoked handset in a drawer is cut off almost at once and rejected on reconnect; an OPEN WEB TAB holds
  its socket INDEFINITELY, so a revoked browser keeps receiving live traffic while that tab stays open —
  exactly the "someone else is in my account right now" case. FOLLOW-UP (named, not built here):
  "realtime session revocation" — broadcast a revocation signal to the realtime tier that disconnects
  sockets matching (user_id, device_id) at revoke time.

  Revoking a device also, in the same transaction:
    * revokes its ACTIVE refresh tokens (every row for (user_id, device_id) — rotation keeps one live,
      the sweep is defensive);
    * DELETES its FCM tokens (074) — a signed-out handset must stop receiving pushes. Rows with a NULL
      device_id (pre-074-shape registrations) can't be matched and are left to FCM dead-token pruning /
      the token-UNIQUE re-register upsert — recorded gap. Web-push subscriptions (061) carry NO
      device_id at all, so a revoked browser keeps its push subscription — recorded gap (needs a column
      + client change).
  """

  import Ecto.Query

  alias AuthService.Repo
  alias AuthService.Schemas.DeviceSession

  @type device_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback register_device(device_attrs()) :: result()
  @callback get_device(device_attrs()) :: result()
  @callback touch_device(device_attrs()) :: result()

  def register_device(_attrs), do: {:error, :not_implemented}

  def get_device(_attrs), do: {:error, :not_implemented}

  def touch_device(_attrs), do: {:error, :not_implemented}

  @doc """
  The caller's non-revoked device sessions, most-recently-seen first (NULL last_seen_at sorts last).
  `last_seen_at` is a LOGIN/REFRESH signal (deliberately not written on every read), so it can lag by
  up to the access TTL — clients should render it as approximate.
  → {:ok, %{devices: [%{device_id, device_name, platform, last_seen_at, created_at}]}}
  """
  def list_devices(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      devices =
        DeviceSession
        |> where([s], s.user_id == ^user_id and is_nil(s.revoked_at))
        |> order_by([s], desc_nulls_last: s.last_seen_at)
        |> Repo.all()
        |> Enum.map(fn s ->
          %{
            device_id: s.device_id,
            device_name: s.device_name,
            platform: s.platform,
            last_seen_at: iso8601(s.last_seen_at),
            created_at: iso8601(s.created_at)
          }
        end)

      {:ok, %{devices: devices}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :auth_invalid}
  end

  @doc """
  Sign ONE device out: mark its device_session revoked + revoke its active refresh tokens + delete its
  FCM tokens, in one transaction. The lookup is scoped to the CALLER, so a foreign device_id is simply
  `:device_not_found` (no existence leak); an already-revoked device is not found either (it isn't in
  the list). The GATEWAY forbids self-target before calling (logout owns that gesture).
  """
  def revoke_device(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, device_id} <- required(attrs, "device_id") do
      case Repo.get_by(DeviceSession, user_id: user_id, device_id: device_id) do
        %DeviceSession{revoked_at: nil} = session ->
          revoke_sessions_tx([session], user_id)
          {:ok, %{revoked: true}}

        _ ->
          {:error, :device_not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :device_not_found}
  end

  @doc """
  "Sign out everywhere else": revoke EVERY other non-revoked device of the caller (the same per-device
  sweep as revoke_device), keeping the current one. → {:ok, %{revoked_count: n}} (0 is fine).
  """
  def revoke_other_devices(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, current_device_id} <- required(attrs, "device_id") do
      others =
        DeviceSession
        |> where(
          [s],
          s.user_id == ^user_id and is_nil(s.revoked_at) and s.device_id != ^current_device_id
        )
        |> Repo.all()

      revoke_sessions_tx(others, user_id)
      # The swept device ids ride back so the gateway can sever each device's live socket.
      {:ok,
       %{revoked_count: length(others), revoked_device_ids: Enum.map(others, & &1.device_id)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :auth_invalid}
  end

  @doc """
  Is this (user, device) session still live? ONE indexed EXISTS: the device_session is non-revoked AND
  the account is still ACTIVE — so the realtime heartbeat re-check catches BOTH device revocation and
  admin suspend/ban (which deliberately doesn't touch device_sessions rows; without this, a suspended
  user's socket would survive). → {:ok, %{active: bool}}. Unknown pair → active: false (fail closed —
  a socket whose session row vanished has no business staying up).
  """
  def session_active?(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, device_id} <- required(attrs, "device_id") do
      %{rows: [[active]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM device_sessions ds JOIN users_auth u ON u.id = ds.user_id " <>
            "WHERE ds.user_id = $1::text::uuid AND ds.device_id = $2 " <>
            "AND ds.revoked_at IS NULL AND u.status = 'active')",
          [user_id, device_id]
        )

      {:ok, %{active: active}}
    end
  rescue
    Ecto.Query.CastError -> {:ok, %{active: false}}
  end

  # One transaction for the whole sweep: sessions marked, refresh tokens revoked, FCM rows gone.
  defp revoke_sessions_tx([], _user_id), do: :ok

  defp revoke_sessions_tx(sessions, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    device_ids = Enum.map(sessions, & &1.device_id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE device_sessions SET revoked_at = $3 " <>
            "WHERE user_id = $1::text::uuid AND device_id = ANY($2) AND revoked_at IS NULL",
          [user_id, device_ids, now]
        )

        Repo.query!(
          "UPDATE refresh_tokens SET revoked_at = $3 " <>
            "WHERE user_id = $1::text::uuid AND device_id = ANY($2) AND revoked_at IS NULL",
          [user_id, device_ids, now]
        )

        # The signed-out handset must stop receiving pushes (074). NULL-device_id rows can't match here.
        Repo.query!(
          "DELETE FROM fcm_tokens WHERE user_id = $1::text::uuid AND device_id = ANY($2)",
          [user_id, device_ids]
        )
      end)

    :ok
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :auth_invalid}
    end
  end
end
