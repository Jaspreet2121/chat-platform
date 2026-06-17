defmodule ApiGatewayWeb.ConversationControllerPostgresIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AuthService.Repo, as: AuthRepo
  alias AuthService.Schemas.DeviceSession
  alias AuthService.Schemas.UserAuth
  alias AuthService.Tokens
  alias ConversationService.Repo, as: ConversationRepo

  @tag :postgres_integration
  test "GET /api/v1/conversations returns an empty DB-backed list for authenticated user" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    conn = authenticated_get("/api/v1/conversations", access_token)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"conversations" => []}
  end

  @tag :postgres_integration
  test "GET /api/v1/conversations/:conversation_id rejects missing DB-backed conversation for authenticated user" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    conn = authenticated_get("/api/v1/conversations/#{Ecto.UUID.generate()}", access_token)

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "conversation.invalid_request"
             }
           } = Jason.decode!(conn.resp_body)
  end

  @tag :postgres_integration
  test "conversation endpoints reject missing Authorization header when DB-backed" do
    create_conn =
      json_request(
        :post,
        "/api/v1/conversations",
        %{
          "type" => "group",
          "title" => "Launch Team",
          "participant_user_ids" => [Ecto.UUID.generate()]
        }
      )

    assert create_conn.status == 401
    assert_session_invalid(create_conn)

    list_conn = authenticated_get("/api/v1/conversations", nil)

    assert list_conn.status == 401
    assert_session_invalid(list_conn)

    show_conn = authenticated_get("/api/v1/conversations/#{Ecto.UUID.generate()}", nil)

    assert show_conn.status == 401
    assert_session_invalid(show_conn)
  end

  setup do
    previous_auth_session_persistence =
      Application.get_env(:auth_service, :session_persistence, false)

    previous_conversation_persistence =
      Application.get_env(:conversation_service, :conversation_persistence, false)

    Application.put_env(:auth_service, :session_persistence, true)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(AuthRepo)
    start_repo!(ConversationRepo)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ConversationRepo)

    on_exit(fn ->
      Application.put_env(:auth_service, :session_persistence, previous_auth_session_persistence)

      Application.put_env(
        :conversation_service,
        :conversation_persistence,
        previous_conversation_persistence
      )
    end)

    :ok
  end

  defp json_request(method, path, params, access_token \\ nil) do
    conn =
      method
      |> conn(path, Jason.encode!(params))
      |> put_req_header("content-type", "application/json")

    conn =
      if access_token do
        put_req_header(conn, "authorization", "Bearer #{access_token}")
      else
        conn
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp authenticated_get(path, access_token) do
    conn = conn(:get, path)

    conn =
      if access_token do
        put_req_header(conn, "authorization", "Bearer #{access_token}")
      else
        conn
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp create_session_fixture! do
    user_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    device_id = "conversation-device-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    assert {:ok, user} =
             %UserAuth{}
             |> UserAuth.changeset(%{
               "id" => user_id,
               "phone_number" => unique_phone_number(),
               "status" => "active"
             })
             |> AuthRepo.insert()

    assert {:ok, device_session} =
             %DeviceSession{}
             |> DeviceSession.changeset(%{
               "id" => session_id,
               "user_id" => user.id,
               "device_id" => device_id,
               "device_name" => "Integration Device",
               "platform" => "ios",
               "refresh_token_hash" =>
                 Tokens.hash_token("conversation-refresh-token-#{device_id}"),
               "last_seen_at" => now
             })
             |> AuthRepo.insert()

    %{
      user_id: user.id,
      session_id: device_session.id,
      device_id: device_session.device_id,
      platform: device_session.platform
    }
  end

  defp create_access_token!(fixture) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, Tokens.access_token_ttl_seconds(), :second)

    claims = %{
      "typ" => "access",
      "sub" => fixture.user_id,
      "sid" => fixture.session_id,
      "did" => fixture.device_id,
      "iat" => DateTime.to_unix(now),
      "exp" => DateTime.to_unix(expires_at),
      "jti" => Ecto.UUID.generate()
    }

    assert {:ok, token} = Tokens.sign_claims(claims)

    token
  end

  defp assert_session_invalid(conn) do
    assert %{
             "error" => %{
               "code" => "auth.session_invalid"
             }
           } = Jason.decode!(conn.resp_body)
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp unique_phone_number do
    "+1555#{System.unique_integer([:positive])}"
  end
end
