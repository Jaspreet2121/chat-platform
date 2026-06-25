defmodule ApiGatewayWeb.UserController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @allowed_update_fields ["display_name", "bio", "avatar_media_id", "avatar_object_key"]

  def me(conn, params) do
    if user_profile_persistence_enabled?() do
      current_profile_from_db(conn, params)
    else
      placeholder_current_profile(conn, params)
    end
  end

  def update_me(conn, params) do
    if user_profile_persistence_enabled?() do
      update_current_profile_from_db(conn, params)
    else
      placeholder_update_current_profile(conn, params)
    end
  end

  def profile(conn, %{"user_id" => user_id} = params) do
    with {:ok, response} <-
           SharedInfra.UserClient.get_public_profile(Map.put(params, "user_id", user_id)) do
      json(conn, with_avatar_url(response))
    else
      {:error, :profile_invalid} -> invalid_request(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
    end
  end

  defp placeholder_current_profile(conn, params) do
    with {:ok, response} <- SharedInfra.UserClient.get_current_profile(params) do
      json(conn, with_avatar_url(response))
    end
  end

  defp current_profile_from_db(conn, _params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.UserClient.get_current_profile(%{"user_id" => session.user_id}) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :profile_invalid} -> session_invalid(conn)
      _ -> session_invalid(conn)
    end
  end

  defp placeholder_update_current_profile(conn, params) do
    with :ok <- validate_update_payload(params),
         {:ok, response} <- SharedInfra.UserClient.update_current_profile(params) do
      json(conn, with_avatar_url(response))
    else
      _ -> invalid_request(conn)
    end
  end

  defp update_current_profile_from_db(conn, params) do
    with :ok <- validate_update_payload(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.UserClient.update_current_profile(
             Map.put(params, "user_id", session.user_id)
           ) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :profile_invalid} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  # Enrich a profile map with a ready-to-use signed `avatar_url`. The profile stores `avatar_media_id`
  # + `avatar_object_key`; presigning a download URL needs the object_key (a viewer can't reconstruct
  # another user's key), so the gateway resolves it via the media client and attaches `avatar_url`.
  # Best-effort: any missing field or media error just leaves the profile unchanged (no avatar_url).
  # NOTE: not yet gated by `profile_photo_visibility` (the privacy module is a placeholder today) —
  # avatar visibility gating is a tracked follow-up.
  defp with_avatar_url(profile) when is_map(profile) do
    with media_id when is_binary(media_id) <- Map.get(profile, :avatar_media_id),
         object_key when is_binary(object_key) <- Map.get(profile, :avatar_object_key),
         owner_user_id when is_binary(owner_user_id) <- Map.get(profile, :user_id),
         {:ok, download} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "owner_user_id" => owner_user_id,
             "object_key" => object_key
           }),
         url when is_binary(url) <- Map.get(download, :download_url) do
      Map.put(profile, :avatar_url, url)
    else
      _ -> profile
    end
  end

  defp with_avatar_url(other), do: other

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp validate_update_payload(params) do
    keys = Enum.map(Map.keys(params), &to_string/1)

    if keys != [] and Enum.all?(keys, &(&1 in @allowed_update_fields)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "user.invalid_request")

  defp service_unavailable(conn), do: ErrorResponse.service_unavailable(conn, "user.unavailable")

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")
end
