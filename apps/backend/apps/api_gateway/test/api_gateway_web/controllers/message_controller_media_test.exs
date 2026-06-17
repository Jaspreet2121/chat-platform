defmodule ApiGatewayWeb.MessageControllerMediaTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MessageService.MessageStore

  setup do
    previous_message_persistence =
      Application.get_env(:message_service, :message_persistence, false)

    previous_message_adapter =
      Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    previous_session_persistence =
      Application.get_env(:auth_service, :session_persistence, false)

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    Application.put_env(:auth_service, :session_persistence, false)

    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    on_exit(fn ->
      MessageStore.InMemoryAdapter.reset()
      Application.put_env(:message_service, :message_persistence, previous_message_persistence)
      Application.put_env(:message_service, :message_store_adapter, previous_message_adapter)
      Application.put_env(:auth_service, :session_persistence, previous_session_persistence)
    end)

    :ok
  end

  test "POST /api/v1/conversations/:conversation_id/messages accepts media message payload in DB-backed mode" do
    conn =
      :post
      |> conn(
        "/api/v1/conversations/conv_123/messages",
        Jason.encode!(%{
          "message_type" => "media",
          "media_id" => "44444444-4444-4444-8444-444444444444",
          "caption" => "Gateway photo"
        })
      )
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> put_req_header("content-type", "application/json")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 201

    response = Jason.decode!(conn.resp_body)

    assert response["conversation_id"] == "conv_123"
    assert response["sender_user_id"] == "user_placeholder"
    assert response["message_type"] == "media"
    assert response["media_id"] == "44444444-4444-4444-8444-444444444444"
    assert response["caption"] == "Gateway photo"
    assert response["body"] == "Gateway photo"

    assert response["metadata"] == %{
             "media_id" => "44444444-4444-4444-8444-444444444444",
             "caption" => "Gateway photo"
           }
  end

  test "POST media message persists object_key and media metadata under metadata" do
    conn =
      :post
      |> conn(
        "/api/v1/conversations/conv_123/messages",
        Jason.encode!(%{
          "message_type" => "media",
          "media_id" => "44444444-4444-4444-8444-444444444444",
          "caption" => "Gateway photo",
          "metadata" => %{
            "object_key" =>
              "media/user_placeholder/44444444-4444-4444-8444-444444444444/photo.png",
            "filename" => "photo.png",
            "content_type" => "image/png",
            "size_bytes" => 2048
          }
        })
      )
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> put_req_header("content-type", "application/json")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 201

    response = Jason.decode!(conn.resp_body)

    assert response["message_type"] == "media"
    assert response["media_id"] == "44444444-4444-4444-8444-444444444444"

    metadata = response["metadata"]

    assert metadata["object_key"] ==
             "media/user_placeholder/44444444-4444-4444-8444-444444444444/photo.png"

    assert metadata["filename"] == "photo.png"
    assert metadata["content_type"] == "image/png"
    assert metadata["size_bytes"] == "2048"
    assert metadata["media_id"] == "44444444-4444-4444-8444-444444444444"
    assert metadata["caption"] == "Gateway photo"
  end

  test "PATCH message authored by another user is rejected (author-only enforcement)" do
    bucket_date = Date.utc_today() |> Date.to_iso8601()

    {:ok, _seeded} =
      MessageStore.put_message(%{
        "conversation_id" => "conv_123",
        "bucket_date" => bucket_date,
        "message_id" => "seed-msg-author",
        "sender_user_id" => "other_user",
        "message_type" => "text",
        "body" => "Owned by other_user",
        "status" => "active",
        "created_at" => DateTime.utc_now()
      })

    conn =
      :patch
      |> conn(
        "/api/v1/conversations/conv_123/messages/seed-msg-author",
        Jason.encode!(%{"body" => "Hijacked edit"})
      )
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> put_req_header("content-type", "application/json")
      |> ApiGatewayWeb.Endpoint.call([])

    # Author-only enforcement surfaces as the documented 403 message.forbidden.
    assert conn.status == 403
    response = Jason.decode!(conn.resp_body)
    assert response["error"]["code"] == "message.forbidden"

    # The other user's message is untouched.
    assert {:ok, %{body: "Owned by other_user", status: "active"}} =
             MessageStore.get_message(%{
               "conversation_id" => "conv_123",
               "bucket_date" => bucket_date,
               "message_id" => "seed-msg-author"
             })
  end

  defp start_in_memory_store! do
    case MessageStore.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
