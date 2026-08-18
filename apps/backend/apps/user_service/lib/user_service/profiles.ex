defmodule UserService.Profiles do
  @moduledoc """
  User profile boundary.

  By default this module returns contract-aligned placeholders so normal tests and
  local development do not require PostgreSQL. DB-backed current profile reads are
  opt-in through `:user_profile_persistence` or `USER_PROFILE_DB_BACKED=true`.
  """

  alias UserService.ProfileStore

  @avatar_fields ["avatar_media_id", "avatar_object_key"]
  # 100: keys where an explicit nil is a REAL write (clears) — the generic nil-means-skip rule would
  # make the payment block unclearable.
  @nullable_fields [
    "upi_id",
    "payment_name",
    "upi_merchant",
    "upi_qr_media_id",
    "address",
    "website",
    "business_email",
    "business_hours"
  ]

  @type profile_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback get_current_profile(profile_attrs()) :: result()
  @callback update_current_profile(profile_attrs()) :: result()
  @callback get_public_profile(profile_attrs()) :: result()

  def get_current_profile(attrs \\ %{}) do
    if user_profile_persistence_enabled?() do
      get_current_profile_from_db(attrs)
    else
      {:ok, placeholder_current_profile()}
    end
  end

  def update_current_profile(attrs) do
    if user_profile_persistence_enabled?() do
      update_current_profile_in_db(attrs)
    else
      {:ok,
       %{
         user_id: "user_placeholder",
         display_name: Map.get(attrs, "display_name", "Placeholder User"),
         avatar_media_id: Map.get(attrs, "avatar_media_id"),
         bio: Map.get(attrs, "bio"),
         updated_at: "2026-06-16T18:30:00Z"
       }}
    end
  end

  def get_public_profile(attrs) do
    if user_profile_persistence_enabled?() do
      get_public_profile_from_db(attrs)
    else
      {:ok,
       %{
         user_id: Map.get(attrs, "user_id", "user_placeholder"),
         display_name: "Placeholder User",
         avatar_media_id: nil,
         bio: "Public profile placeholder"
       }}
    end
  end

  def get_me(attrs \\ %{}), do: get_current_profile(attrs)

  @doc """
  Case-insensitive SUBSTRING search over display_name + username, inside ONE app (2026-08-17).
  attrs: "q" (pre-validated by the gateway — min length lives there), "app_id" (the caller's session
  tenant), "caller_user_id" (excluded from results), optional "limit" (clamped 1..50, default 20).

  Rows are the SAME public-profile card `get_public_profile/1` returns (the gateway runs each through
  ProfilePresenter, so redaction cannot differ from by-phone/by-username). ACTIVE accounts only
  (status parity with those lookups). Ordering: prefix matches (display_name OR username starting
  with q) first, then alphabetical by display_name — ties broken by user_id so pages are stable.
  LIKE wildcards in q are escaped: a query containing % or _ matches those LITERAL characters.
  Rides the 098 trigram indexes (lower(col) LIKE against gin_trgm_ops expressions).
  """
  def search_users(attrs) do
    if user_profile_persistence_enabled?() do
      search_users_in_db(attrs)
    else
      {:ok, %{users: []}}
    end
  end

  defp search_users_in_db(attrs) do
    with {:ok, q} <- required_attr(attrs, :q),
         {:ok, app_id} <- required_attr(attrs, :app_id),
         {:ok, caller_id} <- required_attr(attrs, :caller_user_id) do
      limit = search_limit(get_attr(attrs, :limit))
      needle = q |> String.trim() |> String.downcase() |> escape_like()
      pattern = "%" <> needle <> "%"
      prefix = needle <> "%"

      %{rows: rows} =
        UserService.Repo.query!(
          """
          SELECT p.user_id::text, p.display_name, p.username, p.avatar_media_id::text,
                 p.avatar_object_key, p.app_id::text, p.bio
          FROM user_profiles p
          JOIN users_auth a ON a.id = p.user_id
          WHERE p.app_id = $1::text::uuid
            AND a.status = 'active'
            AND p.user_id <> $2::text::uuid
            AND (lower(p.display_name) LIKE $3 OR lower(p.username) LIKE $3)
          ORDER BY (CASE WHEN lower(p.display_name) LIKE $4 OR lower(p.username) LIKE $4
                    THEN 0 ELSE 1 END),
                   lower(p.display_name), p.user_id
          LIMIT #{limit}
          """,
          [app_id, caller_id, pattern, prefix]
        )

      users =
        Enum.map(rows, fn [user_id, display_name, username, media_id, object_key, row_app, bio] ->
          %{
            user_id: user_id,
            display_name: display_name,
            username: username,
            avatar_media_id: media_id,
            avatar_object_key: object_key,
            # The profile's tenant — presign input only; the gateway's presenter strips it.
            app_id: row_app,
            bio: bio
          }
        end)

      {:ok, %{users: users}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
    _error in Postgrex.Error -> {:error, :profile_invalid}
  end

  # % and _ are LIKE wildcards and \\ is the default LIKE escape — all three become literals.
  defp escape_like(q), do: String.replace(q, ~r/[\\%_]/, fn ch -> "\\" <> ch end)

  defp search_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)

  defp search_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> search_limit(n)
      :error -> 20
    end
  end

  defp search_limit(_), do: 20

  defp update_current_profile_in_db(attrs) do
    with {:ok, user_id} <- required_user_id(attrs),
         {:ok, attrs} <- resolve_payment_attrs(attrs),
         {:ok, attrs} <- resolve_visibility_attrs(user_id, attrs),
         {:ok, profile} <- upsert_profile(user_id, attrs),
         {:ok, profile} <- maybe_set_username(user_id, profile, attrs),
         {:ok, profile} <- maybe_regenerate_upi_qr(user_id, profile, attrs) do
      {:ok, updated_profile_response(user_id, profile)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  # --- UPI payment (100) -------------------------------------------------------------------------

  # Turn the client's payment input into column writes. Three shapes:
  #   * "upi_qr_payload" = a full scanned "upi://pay?..." string → pa/pn parsed, everything else
  #     passed through as the merchant map (never invented, never dropped);
  #   * "upi_qr_payload" = nil/"" → CLEAR the whole payment block;
  #   * manual "upi_id" (+ optional "payment_name") → same columns, no merchant params.
  # Parse errors surface as typed errors (the gateway maps them to 400 codes).
  defp resolve_payment_attrs(attrs) do
    cond do
      Map.has_key?(attrs, "upi_qr_payload") ->
        case Map.get(attrs, "upi_qr_payload") do
          empty when empty in [nil, ""] ->
            {:ok, clear_payment(attrs)}

          payload ->
            case UserService.Upi.parse_payload(payload) do
              {:ok, parsed} ->
                {:ok,
                 attrs
                 |> Map.put("upi_id", parsed.upi_id)
                 |> Map.put("payment_name", parsed.payment_name)
                 |> Map.put("upi_merchant", parsed.merchant)}

              {:error, reason} ->
                {:error, reason}
            end
        end

      Map.has_key?(attrs, "upi_id") ->
        case Map.get(attrs, "upi_id") do
          empty when empty in [nil, ""] ->
            {:ok, clear_payment(attrs)}

          vpa ->
            with {:ok, upi_id} <- UserService.Upi.validate_vpa(vpa) do
              # Manual entry carries no merchant params — the QR is identity-only.
              {:ok, attrs |> Map.put("upi_id", upi_id) |> Map.put("upi_merchant", %{})}
            end
        end

      true ->
        {:ok, attrs}
    end
  end

  @visibility_defaults %{"payment" => "contacts", "business" => "everyone"}
  @payment_visibilities ~w(everyone contacts nobody)
  @business_visibilities ~w(everyone nobody)

  @doc "The stored visibility map with the 100 defaults applied (missing key = default)."
  def visibility_with_defaults(stored),
    do: Map.merge(@visibility_defaults, stored || %{})

  # Partial update: only the provided keys change; each must be a legal value; merged onto the
  # existing map at write (the changeset then stores the merged whole).
  defp resolve_visibility_attrs(user_id, attrs) do
    case Map.get(attrs, "profile_visibility") do
      nil ->
        {:ok, attrs}

      updates when is_map(updates) ->
        payment = Map.get(updates, "payment")
        business = Map.get(updates, "business")

        cond do
          payment not in [nil | @payment_visibilities] ->
            {:error, :invalid_visibility}

          business not in [nil | @business_visibilities] ->
            {:error, :invalid_visibility}

          true ->
            current =
              case ProfileStore.get_profile(user_id) do
                %{profile_visibility: stored} when is_map(stored) -> stored
                _ -> %{}
              end

            validated =
              %{}
              |> then(&if payment, do: Map.put(&1, "payment", payment), else: &1)
              |> then(&if business, do: Map.put(&1, "business", business), else: &1)

            {:ok, Map.put(attrs, "profile_visibility", Map.merge(current, validated))}
        end

      _not_a_map ->
        {:error, :invalid_visibility}
    end
  end

  defp clear_payment(attrs) do
    attrs
    |> Map.put("upi_id", nil)
    |> Map.put("payment_name", nil)
    |> Map.put("upi_merchant", nil)
    |> Map.put("upi_qr_media_id", nil)
  end

  # Regenerate the QR PNG when the payment identity changed (new asset, old purged); purge on clear.
  # A generation failure fails the WRITE (the client retries) — a profile claiming a QR it doesn't
  # have would break /qr silently.
  defp maybe_regenerate_upi_qr(user_id, profile, attrs) do
    payment_touched? = Map.has_key?(attrs, "upi_qr_payload") or Map.has_key?(attrs, "upi_id")

    cond do
      not payment_touched? ->
        {:ok, profile}

      is_nil(profile.upi_id) ->
        # Cleared: drop the stored asset (best-effort) — the column was nulled by clear_payment.
        if old_qr = previous_qr_id(attrs),
          do: UserService.UpiQr.purge(old_qr, get_attr(attrs, :app_id) || profile.app_id)

        {:ok, profile}

      true ->
        payload =
          UserService.Upi.canonical_payload(
            profile.upi_id,
            profile.payment_name || profile.display_name,
            profile.upi_merchant || %{}
          )

        app_id = get_attr(attrs, :app_id) || profile.app_id

        case UserService.UpiQr.generate_and_store(user_id, app_id, payload) do
          {:ok, media_id} ->
            if old_qr = previous_qr_id(attrs), do: UserService.UpiQr.purge(old_qr, app_id)
            ProfileStore.update_profile(profile, %{"upi_qr_media_id" => media_id})

          {:error, _reason} ->
            {:error, :upi_qr_failed}
        end
    end
  end

  # The pre-write QR id (the upsert stashes it before overwriting the row) — read-once.
  defp previous_qr_id(_attrs) do
    id = Process.get(:previous_upi_qr_media_id)
    Process.delete(:previous_upi_qr_media_id)
    id
  end

  # The username rides the SAME PATCH /me the other profile fields use, but through its own write path
  # (UserService.Usernames: validation codes, per-tenant uniqueness, case-only-free, holds + change
  # budget) — the generic changeset can't touch it. Runs AFTER the field upsert so a fresh user can set
  # display_name + username in one call (the row must exist to carry the tenant scope). "" removes.
  defp maybe_set_username(user_id, profile, attrs) do
    case Map.get(attrs, "username") do
      nil ->
        {:ok, profile}

      username ->
        with {:ok, _result} <-
               UserService.Usernames.set_username(%{"user_id" => user_id, "username" => username}) do
          {:ok, ProfileStore.get_profile(user_id)}
        end
    end
  end

  defp upsert_profile(user_id, attrs) do
    case ProfileStore.get_profile(user_id) do
      nil ->
        ProfileStore.create_profile(
          %{
            "user_id" => user_id,
            "display_name" => Map.get(attrs, "display_name", "Placeholder User"),
            "avatar_media_id" => Map.get(attrs, "avatar_media_id"),
            "avatar_object_key" => Map.get(attrs, "avatar_object_key"),
            "bio" => Map.get(attrs, "bio")
          }
          |> Map.merge(
            Map.take(
              attrs,
              ["profile_visibility" | @nullable_fields]
            )
          )
        )

      profile ->
        # Stash the pre-write QR id so the regeneration step can purge the replaced asset.
        Process.put(:previous_upi_qr_media_id, profile.upi_qr_media_id)
        ProfileStore.update_profile(profile, allowed_profile_update_attrs(attrs))
    end
  end

  # Build the update attrs. A nil value means "field not provided" (skip — keep existing). But an
  # explicit EMPTY STRING on an avatar field means "REMOVE the photo" → we set it to nil in the
  # changeset (so the column is cleared) rather than dropping it. This is the clear-avatar path (the
  # frontend sends avatar_media_id="" + avatar_object_key="" to revert to initials).

  defp allowed_profile_update_attrs(attrs) do
    attrs
    |> Map.take(
      ["display_name", "avatar_media_id", "avatar_object_key", "bio", "profile_visibility"] ++
        @nullable_fields
    )
    |> Enum.reduce(%{}, fn
      {key, ""}, acc when key in @avatar_fields -> Map.put(acc, key, nil)
      {key, nil}, acc when key in @nullable_fields -> Map.put(acc, key, nil)
      {key, ""}, acc when key in @nullable_fields -> Map.put(acc, key, nil)
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp updated_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      avatar_media_id: profile.avatar_media_id,
      avatar_object_key: profile.avatar_object_key,
      app_id: profile.app_id,
      bio: profile.bio,
      username: profile.username,
      updated_at: DateTime.to_iso8601(profile.updated_at || DateTime.utc_now())
    }
    |> Map.merge(own_payment_business(profile))
  end

  # The OWNER's payment/business block (100) — includes the merchant passthrough (owner-only; the
  # public card never carries it) and the visibility map with defaults applied.
  defp own_payment_business(profile) do
    %{
      upi_id: profile.upi_id,
      payment_name: profile.payment_name,
      upi_merchant: profile.upi_merchant,
      upi_qr_media_id: profile.upi_qr_media_id,
      address: profile.address,
      website: profile.website,
      business_email: profile.business_email,
      business_hours: profile.business_hours,
      profile_visibility: visibility_with_defaults(profile.profile_visibility)
    }
  end

  defp get_current_profile_from_db(attrs) do
    with {:ok, user_id} <- required_user_id(attrs) do
      profile = ProfileStore.get_profile(user_id)
      {:ok, current_profile_response(user_id, profile)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  # App-SCOPED public read: the profile must belong to the CALLER's app (passed as "app_id"). A
  # cross-tenant user_id (or a user with no profile row) → :profile_not_found → the gateway 404s. This is
  # the tenant gate for /users/:id/profile and the avatar reads — no cross-tenant profile leak.
  defp get_public_profile_from_db(attrs) do
    with {:ok, user_id} <- required_user_id(attrs),
         {:ok, app_id} <- required_attr(attrs, :app_id) do
      case ProfileStore.get_profile_in_app(user_id, app_id) do
        nil -> {:error, :profile_not_found}
        profile -> {:ok, public_profile_response(user_id, profile)}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  # (A nil profile no longer reaches here — get_public_profile_from_db returns :profile_not_found for a
  # missing / cross-tenant row, so the public read is app-scoped and 404s instead of returning empty data.)
  defp public_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      # Visible to anyone who can see the profile at all — a handle exists to be shared (nil when unset).
      username: profile.username,
      avatar_media_id: profile.avatar_media_id,
      avatar_object_key: profile.avatar_object_key,
      # The profile's tenant — the gateway presigns the avatar scoped to this app (the /avatar route has
      # no caller session). Stripped by the gateway before the response reaches the client.
      app_id: profile.app_id,
      bio: profile.bio,
      # 100: the payment trio + business card, gated PER FIELD-GROUP by the gateway presenter using
      # profile_visibility (which itself never reaches a non-owner client). The merchant jsonb is
      # OWNER-ONLY and deliberately absent here.
      upi_id: profile.upi_id,
      payment_name: profile.payment_name,
      upi_qr_media_id: profile.upi_qr_media_id,
      address: profile.address,
      website: profile.website,
      business_email: profile.business_email,
      business_hours: profile.business_hours,
      profile_visibility: visibility_with_defaults(profile.profile_visibility)
    }
  end

  defp required_user_id(attrs) do
    case get_attr(attrs, :user_id) do
      user_id when is_binary(user_id) and user_id != "" -> {:ok, user_id}
      _ -> {:error, :profile_invalid}
    end
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :profile_invalid}
    end
  end

  defp current_profile_response(user_id, nil) do
    %{
      user_id: user_id,
      display_name: nil,
      avatar_media_id: nil,
      avatar_object_key: nil,
      bio: nil,
      username: nil,
      settings: UserService.Settings.placeholder_settings(),
      # REAL privacy now (was a placeholder) — same shape, so `me`'s contract is unchanged; a user with no
      # settings row simply gets the column defaults.
      privacy: UserService.Privacy.privacy_map(user_id)
    }
  end

  defp current_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      avatar_media_id: profile.avatar_media_id,
      avatar_object_key: profile.avatar_object_key,
      app_id: profile.app_id,
      bio: profile.bio,
      # The caller's own handle (nil when unset — clients render it only when non-null).
      username: profile.username,
      settings: UserService.Settings.placeholder_settings(),
      privacy: UserService.Privacy.privacy_map(user_id)
    }
    |> Map.merge(own_payment_business(profile))
  end

  defp placeholder_current_profile do
    %{
      user_id: "user_placeholder",
      display_name: "Placeholder User",
      avatar_media_id: nil,
      bio: "User profile placeholder",
      settings: UserService.Settings.placeholder_settings(),
      privacy: UserService.Privacy.placeholder_privacy()
    }
  end

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
