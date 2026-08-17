defmodule UserService.Profiles do
  @moduledoc """
  User profile boundary.

  By default this module returns contract-aligned placeholders so normal tests and
  local development do not require PostgreSQL. DB-backed current profile reads are
  opt-in through `:user_profile_persistence` or `USER_PROFILE_DB_BACKED=true`.
  """

  alias UserService.ProfileStore

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
         {:ok, profile} <- upsert_profile(user_id, attrs),
         {:ok, profile} <- maybe_set_username(user_id, profile, attrs) do
      {:ok, updated_profile_response(user_id, profile)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
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
        ProfileStore.create_profile(%{
          "user_id" => user_id,
          "display_name" => Map.get(attrs, "display_name", "Placeholder User"),
          "avatar_media_id" => Map.get(attrs, "avatar_media_id"),
          "avatar_object_key" => Map.get(attrs, "avatar_object_key"),
          "bio" => Map.get(attrs, "bio")
        })

      profile ->
        ProfileStore.update_profile(profile, allowed_profile_update_attrs(attrs))
    end
  end

  # Build the update attrs. A nil value means "field not provided" (skip — keep existing). But an
  # explicit EMPTY STRING on an avatar field means "REMOVE the photo" → we set it to nil in the
  # changeset (so the column is cleared) rather than dropping it. This is the clear-avatar path (the
  # frontend sends avatar_media_id="" + avatar_object_key="" to revert to initials).
  @avatar_fields ["avatar_media_id", "avatar_object_key"]

  defp allowed_profile_update_attrs(attrs) do
    attrs
    |> Map.take(["display_name", "avatar_media_id", "avatar_object_key", "bio"])
    |> Enum.reduce(%{}, fn
      {key, ""}, acc when key in @avatar_fields -> Map.put(acc, key, nil)
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
      bio: profile.bio
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
