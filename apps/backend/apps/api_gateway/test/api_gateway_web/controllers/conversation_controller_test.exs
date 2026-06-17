defmodule ApiGatewayWeb.ConversationControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "POST /api/v1/conversations creates placeholder conversation" do
    conn =
      json_request(:post, "/api/v1/conversations", %{
        "type" => "group",
        "participant_user_ids" => ["user_123", "user_456"],
        "title" => "Launch Team",
        "tenant_id" => nil
      })

    assert conn.status == 201

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_placeholder",
             "tenant_id" => nil,
             "type" => "group",
             "title" => "Launch Team",
             "created_by" => "user_placeholder",
             "participant_user_ids" => ["user_123", "user_456"],
             "created_at" => "2026-06-17T10:00:00Z"
           }
  end

  test "GET /api/v1/conversations lists placeholder conversations" do
    conn =
      :get
      |> conn("/api/v1/conversations")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversations" => [
               %{
                 "conversation_id" => "conv_placeholder",
                 "type" => "group",
                 "title" => "Launch Team",
                 "last_message_preview" => nil,
                 "unread_count" => 0,
                 "updated_at" => "2026-06-17T10:00:00Z"
               }
             ]
           }
  end

  test "GET /api/v1/conversations/:conversation_id returns placeholder conversation" do
    conn =
      :get
      |> conn("/api/v1/conversations/conv_123")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "tenant_id" => nil,
             "type" => "group",
             "title" => "Launch Team",
             "participants" => [
               %{
                 "user_id" => "user_123",
                 "role" => "member",
                 "joined_at" => "2026-06-17T10:00:00Z"
               }
             ]
           }
  end

  test "POST /api/v1/conversations/:conversation_id/participants adds placeholder participant" do
    conn =
      json_request(:post, "/api/v1/conversations/conv_123/participants", %{
        "user_id" => "user_789",
        "role" => "member"
      })

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "user_id" => "user_789",
             "role" => "member",
             "joined_at" => "2026-06-17T10:00:00Z"
           }
  end

  test "DELETE /api/v1/conversations/:conversation_id/participants/:user_id removes placeholder participant" do
    conn =
      :delete
      |> conn("/api/v1/conversations/conv_123/participants/user_789")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "user_id" => "user_789",
             "removed" => true
           }
  end

  test "POST /api/v1/conversations rejects invalid create payload" do
    conn = json_request(:post, "/api/v1/conversations", %{"type" => "group"})

    assert conn.status == 400

    assert_invalid_error(conn, "conversation.invalid_request")
  end

  test "POST /api/v1/conversations/:conversation_id/participants rejects invalid payload" do
    conn = json_request(:post, "/api/v1/conversations/conv_123/participants", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "conversation.invalid_request")
  end

  defp json_request(method, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp assert_invalid_error(conn, code) do
    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => code,
               "message" => "Request body is invalid",
               "correlation_id" => "corr_placeholder"
             }
           }
  end
end
