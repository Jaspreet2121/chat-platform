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
          "bio" => Map.get(attrs, "bio")
        })

      profile ->
        ProfileStore.update_profile(profile, allowed_profile_update_attrs(attrs))
    end
  end

  defp allowed_profile_update_attrs(attrs) do
    attrs
    |> Map.take(["display_name", "avatar_media_id", "bio"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp updated_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      avatar_media_id: profile.avatar_media_id,
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

  defp get_public_profile_from_db(attrs) do
    with {:ok, user_id} <- required_user_id(attrs) do
      profile = ProfileStore.get_profile(user_id)

      {:ok, public_profile_response(user_id, profile)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  defp public_profile_response(user_id, nil) do
    %{
      user_id: user_id,
      display_name: nil,
      avatar_media_id: nil,
      bio: nil
    }
  end

  defp public_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      avatar_media_id: profile.avatar_media_id,
      bio: profile.bio
    }
  end

  defp required_user_id(attrs) do
    case get_attr(attrs, :user_id) do
      user_id when is_binary(user_id) and user_id != "" -> {:ok, user_id}
      _ -> {:error, :profile_invalid}
    end
  end

  defp current_profile_response(user_id, nil) do
    %{
      user_id: user_id,
      display_name: nil,
      avatar_media_id: nil,
      bio: nil,
      settings: UserService.Settings.placeholder_settings(),
      privacy: UserService.Privacy.placeholder_privacy()
    }
  end

  defp current_profile_response(user_id, profile) do
    %{
      user_id: user_id,
      display_name: profile.display_name,
      avatar_media_id: profile.avatar_media_id,
      bio: profile.bio,
      settings: UserService.Settings.placeholder_settings(),
      privacy: UserService.Privacy.placeholder_privacy()
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
