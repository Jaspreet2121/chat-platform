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

  defp update_current_profile_in_db(attrs) do
    with {:ok, user_id} <- required_user_id(attrs),
         {:ok, profile} <- upsert_profile(user_id, attrs) do
      {:ok, updated_profile_response(user_id, profile)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
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
