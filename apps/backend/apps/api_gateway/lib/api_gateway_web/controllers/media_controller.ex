defmodule ApiGatewayWeb.MediaController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create_upload(conn, params) do
    if media_persistence_enabled?() do
      create_upload_with_session(conn, params)
    else
      create_placeholder_upload(conn, params)
    end
  end

  defp create_placeholder_upload(conn, params) do
    with {:ok, response} <-
           params
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.create_upload() do
      conn
      |> put_status(:created)
      |> json(response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp create_upload_with_session(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("owner_user_id", session.user_id)
           |> SharedInfra.MediaClient.create_upload() do
      conn
      |> put_status(:created)
      |> json(response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      _ -> invalid_request(conn)
    end
  end

  def complete_upload(conn, %{"media_id" => media_id} = params) do
    if media_persistence_enabled?() do
      complete_upload_with_session(conn, media_id, params)
    else
      complete_placeholder_upload(conn, media_id, params)
    end
  end

  defp complete_placeholder_upload(conn, media_id, params) do
    with {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.complete_upload() do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp complete_upload_with_session(conn, media_id, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", session.user_id)
           |> SharedInfra.MediaClient.complete_upload() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      _ -> invalid_request(conn)
    end
  end

  def download(conn, %{"media_id" => media_id} = params) do
    if media_persistence_enabled?() do
      download_with_session(conn, media_id, params)
    else
      placeholder_download(conn, media_id, params)
    end
  end

  defp placeholder_download(conn, media_id, params) do
    with {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.get_download_url() do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp download_with_session(conn, media_id, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", session.user_id)
           |> SharedInfra.MediaClient.get_download_url() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      _ -> invalid_request(conn)
    end
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "media.invalid_request")

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "media.unauthorized", "Missing or invalid access token")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp media_persistence_enabled? do
    Application.get_env(:media_service, :media_persistence, false) ||
      System.get_env("MEDIA_DB_BACKED") in ["true", "1", "yes"]
  end
end
