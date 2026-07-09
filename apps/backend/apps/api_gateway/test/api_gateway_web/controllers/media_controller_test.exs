defmodule ApiGatewayWeb.MediaControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MediaService.Storage

  setup do
    previous_persistence = Application.get_env(:media_service, :media_persistence, false)

    previous_adapter =
      Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    Application.put_env(:media_service, :media_persistence, false)

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, previous_persistence)
      Application.put_env(:media_service, :media_storage_adapter, previous_adapter)

      if Process.whereis(Storage.InMemoryAdapter) do
        Storage.InMemoryAdapter.reset()
      end
    end)

    :ok
  end

  test "POST /api/v1/media/uploads creates placeholder upload" do
    conn =
      json_request(:post, "/api/v1/media/uploads", %{
        "filename" => "photo.png",
        "content_type" => "image/png",
        "size_bytes" => 123
      })

    assert conn.status == 201

    response = Jason.decode!(conn.resp_body)
    assert response["media_id"] =~ ~r/^[0-9a-f-]{36}$/
    assert response["object_key"] =~ "media/user_placeholder/"
    assert response["upload_url"] =~ "https://media.placeholder.local/uploads/"
    assert is_binary(response["expires_at"])
  end

  test "POST /api/v1/media/uploads rejects invalid upload payload" do
    conn =
      json_request(:post, "/api/v1/media/uploads", %{
        "filename" => "script.js",
        "content_type" => "application/javascript",
        "size_bytes" => 123
      })

    assert conn.status == 400
    assert_invalid_error(conn, "media.invalid_request")
  end

  test "POST /api/v1/media/uploads/:media_id/complete completes placeholder upload" do
    conn =
      json_request(:post, "/api/v1/media/uploads/media_123/complete", %{
        "object_key" => "media/user_placeholder/media_123/photo.png"
      })

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "media_id" => "media_123",
             "status" => "ready"
           }
  end

  test "GET /api/v1/media/:media_id/download returns placeholder download URL" do
    conn =
      :get
      |> conn(
        "/api/v1/media/media_123/download?object_key=media/user_placeholder/media_123/photo.png"
      )
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    response = Jason.decode!(conn.resp_body)
    assert response["media_id"] == "media_123"
    assert response["download_url"] == "https://media.placeholder.local/downloads/media_123"
    assert is_binary(response["expires_at"])
  end

  test "media persistence enabled requires Authorization header" do
    Application.put_env(:media_service, :media_persistence, true)

    conn =
      json_request(:post, "/api/v1/media/uploads", %{
        "filename" => "photo.png",
        "content_type" => "image/png",
        "size_bytes" => 123
      })

    assert conn.status == 401

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "media.unauthorized"
  end

  # NOTE: the former "media persistence enabled creates upload through in-memory adapter with session
  # user" test was removed. create_upload now INSERTs a media_assets row (tenant + owner) via
  # MediaService.Repo, so the persistence-enabled path requires a REAL Postgres AND a UUID owner — the old
  # combination (persistence on, session persistence off → the "user_placeholder" session, no DB) is no
  # longer coherent. That coverage moved to:
  #   * media_controller_authz_test.exs — the session → create path + field passing (media client stubbed);
  #   * media_persistence_postgres_integration_test.exs — the real persisted insert (:postgres_integration).

  defp json_request(method, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp assert_invalid_error(conn, code) do
    assert %{
             "error" => %{
               "code" => ^code,
               "message" => "Request body is invalid",
               "correlation_id" => correlation_id
             }
           } = Jason.decode!(conn.resp_body)

    assert is_binary(correlation_id) and correlation_id != "" and
             correlation_id != "corr_placeholder"
  end
end
