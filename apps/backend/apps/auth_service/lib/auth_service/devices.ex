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
      the token-UNIQUE re-register upsert — recorded gap;
    * DELETES its web-push subscriptions (103) — same rule for a signed-out browser. The gateway
      stamps the session's device_id on subscribe; pre-103 NULL rows can't be matched and expire via
      push-failure pruning.
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
            # 099: NULL for a primary (direct-login) session; the approving phone's device_id for a
            # QR-linked one. The client renders the "linked via <phone>" line off this.
            linked_by: s.linked_by_device_id,
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
          # ASYMMETRIC REVOCATION (099): the phone revokes its linked devices, but a LINKED device
          # (linked_by set) may never revoke a PRIMARY (direct-login, linked_by NULL) session — a
          # stolen browser session must not be able to sign the phone out. Caller identity comes
          # from the gateway's session (caller_device_id); absent (legacy caller) => primary rules.
          if linked_caller?(user_id, Map.get(attrs, "caller_device_id")) and
               is_nil(session.linked_by_device_id) do
            {:error, :cannot_revoke_primary}
          else
            revoke_sessions_tx([session], user_id)
            # session_id rides back so the gateway's session_revoked broadcast can name BOTH
            # identities — a QR-linked browser knows its session_id, not its server-minted device_id.
            {:ok, %{revoked: true, session_id: session.id}}
          end

        _ ->
          {:error, :device_not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :device_not_found}
  end

  # Is the CALLER's own session a linked one? Unknown caller row fails CLOSED (treated as linked —
  # the weaker privilege) so a spoofed/absent row can never unlock primary revocation.
  defp linked_caller?(user_id, caller_device_id) when is_binary(caller_device_id) do
    case Repo.get_by(DeviceSession, user_id: user_id, device_id: caller_device_id) do
      %DeviceSession{linked_by_device_id: nil} -> false
      %DeviceSession{} -> true
      nil -> true
    end
  end

  defp linked_caller?(_user_id, _caller_device_id), do: false

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

  @doc """
  Mint the SESSION for a QR-LINKED web/desktop device (099): a fresh device_session (platform "web",
  generated device_id, linked_by_device_id = the approving PHONE's device) + its refresh-token row,
  in one transaction, on the existing token machinery (`Tokens.prepare_issue_pair` — remember-me TTL:
  a linked desktop should survive a workday, and logout/revocation still kills it instantly).
  attrs: "user_id", "app_id" (the PHONE session's tenant — stamped into the token claims, never
  defaulted here), "device_name", "linked_by_device_id".
  → {:ok, %{access_token, access_token_expires_in_seconds, refresh_token,
            refresh_token_expires_in_seconds, session_id, device_id, device_name}}
  """
  def link_device_session(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, device_name} <- required(attrs, "device_name"),
         {:ok, linked_by} <- required(attrs, "linked_by_device_id") do
      device_id = "web-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      session_id = Ecto.UUID.generate()

      {:ok, pair} =
        AuthService.Tokens.prepare_issue_pair(
          %{
            "user_id" => user_id,
            "session_id" => session_id,
            "device_id" => device_id,
            "device_name" => device_name,
            "platform" => "web",
            "app_id" => Map.get(attrs, "app_id")
          },
          access_ttl_seconds: AuthService.Tokens.session_ttl_seconds(true)
        )

      Repo.transaction(fn ->
        with {:ok, _session} <-
               pair.device_session_attrs
               |> Map.put("id", session_id)
               |> Map.put("linked_by_device_id", linked_by)
               |> AuthService.DeviceSessions.create_device_session(),
             {:ok, _refresh} <-
               AuthService.RefreshTokens.create_refresh_token(pair.refresh_token_attrs) do
          %{
            access_token: pair.access_token,
            access_token_expires_in_seconds: pair.access_token_expires_in_seconds,
            refresh_token: pair.refresh_token,
            refresh_token_expires_in_seconds: pair.refresh_token_expires_in_seconds,
            session_id: session_id,
            device_id: device_id,
            device_name: device_name
          }
        else
          _ -> Repo.rollback(:link_invalid)
        end
      end)
      |> case do
        {:ok, minted} -> {:ok, minted}
        {:error, _} -> {:error, :link_invalid}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :link_invalid}
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

        # And the signed-out BROWSER must stop receiving web pushes (103) — subscriptions carry the
        # session's device_id since 103. Pre-103 NULL rows can't be attributed to a device and are
        # left to expire via push-failure pruning; other devices' subscriptions are untouched.
        Repo.query!(
          "DELETE FROM push_subscriptions WHERE user_id = $1::text::uuid AND device_id = ANY($2)",
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
