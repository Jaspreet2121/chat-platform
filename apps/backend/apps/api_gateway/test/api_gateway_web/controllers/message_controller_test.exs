defmodule ApiGatewayWeb.MessageControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "POST /api/v1/conversations/:conversation_id/messages sends placeholder message" do
    conn =
      json_request(:post, "/api/v1/conversations/conv_123/messages", %{
        "message_type" => "text",
        "body" => "Hello",
        "reply_to_message_id" => nil,
        "metadata" => %{}
      })

    assert conn.status == 201

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "message_id" => "msg_placeholder",
             "sender_user_id" => "user_placeholder",
             "message_type" => "text",
             "body" => "Hello",
             "status" => "active",
             "created_at" => "2026-06-17T10:15:00Z"
           }
  end

  test "GET /api/v1/conversations/:conversation_id/messages lists placeholder messages" do
    conn =
      :get
      |> conn("/api/v1/conversations/conv_123/messages")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "messages" => [
               %{
                 "message_id" => "msg_placeholder",
                 "sender_user_id" => "user_placeholder",
                 "message_type" => "text",
                 "body" => "Hello",
                 "status" => "active",
                 "created_at" => "2026-06-17T10:15:00Z"
               }
             ],
             "next_cursor" => nil
           }
  end

  test "PATCH /api/v1/conversations/:conversation_id/messages/:message_id edits placeholder message" do
    conn =
      json_request(:patch, "/api/v1/conversations/conv_123/messages/msg_123", %{
        "body" => "Hello edited"
      })

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "message_id" => "msg_123",
             "body" => "Hello edited",
             "status" => "edited",
             "edited_at" => "2026-06-17T10:20:00Z"
           }
  end

  test "DELETE /api/v1/conversations/:conversation_id/messages/:message_id deletes placeholder message" do
    conn =
      :delete
      |> conn("/api/v1/conversations/conv_123/messages/msg_123")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "message_id" => "msg_123",
             "status" => "deleted",
             "deleted_at" => "2026-06-17T10:25:00Z"
           }
  end

  test "POST /api/v1/conversations/:conversation_id/messages/:message_id/read marks placeholder read receipt" do
    conn =
      :post
      |> conn("/api/v1/conversations/conv_123/messages/msg_123/read")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "message_id" => "msg_123",
             "read_by_user_id" => "user_placeholder",
             "read_at" => "2026-06-17T10:30:00Z"
           }
  end

  test "POST /api/v1/conversations/:conversation_id/messages/:message_id/delivered marks placeholder delivered receipt" do
    conn =
      :post
      |> conn("/api/v1/conversations/conv_123/messages/msg_123/delivered")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "conversation_id" => "conv_123",
             "message_id" => "msg_123",
             "delivered_to_user_id" => "user_placeholder",
             "delivered_at" => "2026-06-17T10:30:00Z"
           }
  end

  test "POST /api/v1/conversations/:conversation_id/messages rejects invalid send payload" do
    conn =
      json_request(:post, "/api/v1/conversations/conv_123/messages", %{"message_type" => "text"})

    assert conn.status == 400

    assert_invalid_error(conn, "message.invalid_request")
  end

  test "PATCH /api/v1/conversations/:conversation_id/messages/:message_id rejects invalid edit payload" do
    conn = json_request(:patch, "/api/v1/conversations/conv_123/messages/msg_123", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "message.invalid_request")
  end

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
