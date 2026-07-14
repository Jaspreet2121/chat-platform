defmodule ApiGatewayWeb.V1.MessageEditDeleteTest do
  @moduledoc """
  /v1 message edit (PATCH) + SOFT-delete (DELETE). Docker-free: stubs the conversation + message clients and
  subscribes to the endpoint PubSub, so we exercise the ownership mapping (author-only → 404), the request
  shape passed to the service, and the LIVE broadcast (the socket path's exact event names).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.MessageController

  @app "44444444-4444-4444-8444-444444444444"
  @author "u-author"
  @conv "conv-1"
  @msg "msg-1"

  defmodule ConvStub do
    @moduledoc false
    # Membership gate: the end-user is a participant of @conv only.
    def get_conversation(%{"conversation_id" => "conv-1"}),
      do: {:ok, %{conversation_id: "conv-1", app_id: "44444444-4444-4444-8444-444444444444"}}

    def get_conversation(_), do: {:error, :conversation_not_found}

    def get_conversation_app(%{"conversation_id" => "conv-1"}), do: {:ok, %{conversation_id: "conv-1"}}
    def get_conversation_app(_), do: {:error, :conversation_not_found}
  end

  defmodule MsgStub do
    @moduledoc false
    # The service is AUTHOR-ONLY: only "u-author" may edit/delete msg-1. Shapes copied from
    # MessageService.Messages edited_message_response/1 + deleted_message_response/1.
    def update_message(%{"actor_user_id" => "u-author", "message_id" => "msg-1", "body" => body}) do
      {:ok,
       %{
         conversation_id: "conv-1",
         message_id: "msg-1",
         body: body,
         status: "edited",
         edited_at: "2026-07-13T00:00:00Z"
       }}
    end

    # The service refuses an edit to a soft-deleted message (no resurrect).
    def update_message(%{"actor_user_id" => "u-author", "message_id" => "msg-deleted"}),
      do: {:error, :message_deleted}

    def update_message(_attrs), do: {:error, :message_forbidden}

    def delete_message(%{"actor_user_id" => "u-author", "message_id" => "msg-1"}) do
      {:ok,
       %{
         conversation_id: "conv-1",
         message_id: "msg-1",
         deleted: true,
         status: "deleted",
         deleted_at: "2026-07-13T00:00:00Z"
       }}
    end

    def delete_message(_attrs), do: {:error, :message_forbidden}
  end

  defmodule AuthStub do
    @moduledoc false
    # The app actor names its acting user by EXTERNAL id (same convention as create): ext-* → u-*.
    def resolve_external_user(%{"external_id" => ext}),
      do: {:ok, %{user_id: "u-" <> String.replace_prefix(ext, "ext-", "")}}
  end

  setup do
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev_conv)
      restore(:message_client_adapter, prev_msg)
      restore(:auth_client_adapter, prev_auth)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # An end-user (JWT) conn acting as `user_id`.
  defp end_user_conn(method, user_id) do
    method
    |> conn("/v1/conversations/#{@conv}/messages/#{@msg}", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, user_id)
  end

  defp subscribe_conv, do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conv}")

  # --- edit ----------------------------------------------------------------------------------------

  test "author edits own message → 200 with edited_at, and message_updated broadcasts live" do
    subscribe_conv()

    conn =
      MessageController.update(end_user_conn(:patch, @author), %{
        "id" => @conv,
        "message_id" => @msg,
        "body" => "edited text"
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["message_id"] == @msg
    assert body["body"] == "edited text"
    assert body["status"] == "edited"
    assert body["edited_at"] == "2026-07-13T00:00:00Z"

    # The SAME event name the socket's message:update emits — a connected client updates with no change.
    assert_receive %Phoenix.Socket.Broadcast{event: "message_updated", payload: payload}, 1000
    assert payload.message_id == @msg
    assert payload.body == "edited text"
  end

  test "editing ANOTHER user's message → 404 (author-only), and NOTHING broadcasts" do
    subscribe_conv()

    conn =
      MessageController.update(end_user_conn(:patch, "u-someone-else"), %{
        "id" => @conv,
        "message_id" => @msg,
        "body" => "hijacked"
      })

    assert conn.status == 404
    # Never reveals that the message exists.
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "v1.not_found"
    refute_receive %Phoenix.Socket.Broadcast{event: "message_updated"}, 300
  end

  test "edit with an empty body → 400 (invalid_request), no broadcast" do
    subscribe_conv()

    conn =
      MessageController.update(end_user_conn(:patch, @author), %{
        "id" => @conv,
        "message_id" => @msg,
        "body" => ""
      })

    assert conn.status == 400
    refute_receive %Phoenix.Socket.Broadcast{event: "message_updated"}, 300
  end

  test "editing in a conversation the caller is NOT a member of → 404" do
    conn =
      MessageController.update(end_user_conn(:patch, @author), %{
        "id" => "conv-other",
        "message_id" => @msg,
        "body" => "nope"
      })

    assert conn.status == 404
  end

  # --- delete --------------------------------------------------------------------------------------

  test "author deletes own message → SOFT delete (tombstone) + message_deleted broadcast" do
    subscribe_conv()

    conn =
      MessageController.delete(end_user_conn(:delete, @author), %{
        "id" => @conv,
        "message_id" => @msg
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    # Tombstone, not a removal: the row survives with status/deleted_at.
    assert body["message_id"] == @msg
    assert body["deleted"] == true
    assert body["status"] == "deleted"
    assert body["deleted_at"] == "2026-07-13T00:00:00Z"

    assert_receive %Phoenix.Socket.Broadcast{event: "message_deleted", payload: payload}, 1000
    assert payload.message_id == @msg
    assert payload.deleted == true
  end

  test "deleting ANOTHER user's message → 404, nothing broadcasts" do
    subscribe_conv()

    conn =
      MessageController.delete(end_user_conn(:delete, "u-someone-else"), %{
        "id" => @conv,
        "message_id" => @msg
      })

    assert conn.status == 404
    refute_receive %Phoenix.Socket.Broadcast{event: "message_deleted"}, 300
  end

  test "an APP actor names the acting user via `sender` and is STILL author-only" do
    # An app (secret-key) actor has no v1_user_id; it names the user it acts as, exactly like create.
    # It edits AS that user — so it can only touch that user's own messages (no tenant-wide edit power).
    app_conn =
      :patch
      |> conn("/v1/conversations/#{@conv}/messages/#{@msg}", %{})
      |> assign(:v1_app_id, @app)
      |> assign(:v1_actor, :app)

    # Naming a user who is NOT the author → the service's author gate refuses → 404.
    assert %{status: 404} =
             MessageController.update(app_conn, %{
               "id" => @conv,
               "message_id" => @msg,
               "sender" => "ext-not-author",
               "body" => "x"
             })
  end
  test "editing a SOFT-DELETED message → 404 (gone; the tombstone is never resurrected), no broadcast" do
    subscribe_conv()

    conn =
      MessageController.update(end_user_conn(:patch, @author), %{
        "id" => @conv,
        "message_id" => "msg-deleted",
        "body" => "back from the dead"
      })

    # 404, indistinguishable from an author mismatch — a deleted message is simply gone.
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "v1.not_found"
    refute_receive %Phoenix.Socket.Broadcast{event: "message_updated"}, 300
  end
end
