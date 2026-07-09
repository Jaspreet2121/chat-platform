defmodule ApiGatewayWeb.V1.ConversationAuthzTest do
  @moduledoc """
  The security gate for conversation-scoped /v1 routes: an app (secret-key) actor has tenant-wide access;
  an end-user (JWT) actor must be an ACTIVE PARTICIPANT. A non-member or a cross-tenant id both return a
  404 with a generic body — never a 403, never any existence reveal.

  Calls the controller actions directly with the assigns V1Auth would leave (bypassing the plug), and
  stubs the conversation/auth/message client boundaries so membership is decided by the input.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.ConversationController
  alias ApiGatewayWeb.V1.MessageController

  @app "44444444-4444-4444-8444-444444444444"
  @convo "11111111-1111-4111-8111-111111111111"
  @member "22222222-2222-4222-8222-222222222222"
  # A user of the SAME app who is NOT a participant of @convo.
  @stranger "33333333-3333-4333-8333-333333333333"
  @bob "55555555-5555-4555-8555-555555555555"
  # A conversation in a DIFFERENT app (cross-tenant).
  @cross_convo "99999999-9999-4999-8999-999999999999"
  @other_convo "88888888-8888-4888-8888-888888888888"

  defmodule ConvStub do
    @moduledoc false

    @app "44444444-4444-4444-8444-444444444444"
    @convo "11111111-1111-4111-8111-111111111111"
    @member "22222222-2222-4222-8222-222222222222"
    @stranger "33333333-3333-4333-8333-333333333333"
    @bob "55555555-5555-4555-8555-555555555555"
    @other_convo "88888888-8888-4888-8888-888888888888"

    # Tenant-only path (app actor): the (app_id, id) predicate. Cross-tenant/unknown → not_found.
    def get_conversation_app(%{"conversation_id" => @convo, "app_id" => @app}), do: {:ok, summary()}
    def get_conversation_app(_), do: {:error, :conversation_not_found}

    # Membership path (end-user actor): a participant → detail (carries app_id + participants); a
    # non-participant → :conversation_forbidden; anything else (unknown/cross-tenant) → :conversation_not_found.
    def get_conversation(%{"conversation_id" => @convo, "user_id" => @member}), do: {:ok, detail()}
    def get_conversation(%{"conversation_id" => @convo, "user_id" => @stranger}),
      do: {:error, :conversation_forbidden}

    def get_conversation(_), do: {:error, :conversation_not_found}

    # Membership-scoped list: each user sees only their own conversations.
    def list_conversations(%{"user_id" => @member}), do: {:ok, %{conversations: [row(@convo, "Alice & Bob")]}}
    def list_conversations(%{"user_id" => @stranger}),
      do: {:ok, %{conversations: [row(@other_convo, "Stranger's chat")]}}

    def list_conversations(_), do: {:ok, %{conversations: []}}

    # Echo created_by + participants back so the test can assert what the controller decided.
    def create_conversation(attrs) do
      {:ok,
       %{
         conversation_id: "new-convo",
         type: attrs["type"],
         created_by: attrs["created_by"],
         participant_user_ids: attrs["participant_user_ids"]
       }}
    end

    defp summary do
      %{
        conversation_id: @convo,
        app_id: @app,
        type: "direct",
        title: nil,
        created_by: @member,
        status: "active",
        created_at: "2026-07-01T00:00:00Z"
      }
    end

    # The membership detail shape — INCLUDES app_id (the gate pins it) and internal participant user_ids
    # (which is exactly why show/ must NOT return this raw across /v1).
    defp detail do
      %{
        conversation_id: @convo,
        app_id: @app,
        type: "direct",
        title: nil,
        created_by: @member,
        participants: [%{user_id: @member}, %{user_id: @bob}]
      }
    end

    # A list row carrying internal group-avatar storage keys — the controller must drop them.
    defp row(convo_id, title) do
      %{
        conversation_id: convo_id,
        type: "direct",
        title: title,
        last_message_preview: "hey",
        last_message_kind: "text",
        unread_count: 0,
        updated_at: "2026-07-01T00:00:00Z",
        group_avatar_media_id: "internal-media-id",
        group_avatar_object_key: "internal/object/key"
      }
    end
  end

  defmodule AuthStub do
    @moduledoc false
    @member "22222222-2222-4222-8222-222222222222"
    @bob "55555555-5555-4555-8555-555555555555"

    def resolve_external_user(%{"external_id" => "ext-alice"}), do: {:ok, %{user_id: @member}}
    def resolve_external_user(%{"external_id" => "ext-bob"}), do: {:ok, %{user_id: @bob}}
    def resolve_external_user(_), do: {:error, :not_found}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(_attrs), do: {:ok, %{"message_id" => "m1", "body" => "hi", "status" => "active"}}
    def list_messages(_attrs), do: {:ok, %{"messages" => [], "next_cursor" => nil}}
  end

  setup do
    prev = %{
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter)
    }

    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev.conv)
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # A conn with the assigns V1Auth leaves for an end-user JWT (has a user_id).
  defp end_user_conn(user_id) do
    :get
    |> conn("/", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, user_id)
  end

  # A conn for the app (secret-key) actor: app_id, no user_id.
  defp app_conn do
    :get
    |> conn("/", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :app)
    |> assign(:v1_user_id, nil)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Assert a 404 that reveals NOTHING and is NOT a 403.
  defp assert_opaque_not_found(conn) do
    assert conn.status == 404
    refute conn.status == 403
    b = body(conn)
    assert b["error"]["code"] == "v1.not_found"
    # No resource detail leaks — only the generic error envelope.
    assert Map.keys(b) == ["error"]
    assert Map.keys(b["error"]) |> Enum.sort() == ["code", "correlation_id", "message"]
  end

  # --- GET /v1/conversations/:id/messages -----------------------------------------------------------

  describe "GET /conversations/:id/messages" do
    test "end-user participant → 200" do
      conn = MessageController.index(end_user_conn(@member), %{"id" => @convo})
      assert conn.status == 200
    end

    test "end-user NON-participant → 404 (opaque, not 403)" do
      conn = MessageController.index(end_user_conn(@stranger), %{"id" => @convo})
      assert_opaque_not_found(conn)
    end

    test "secret-key actor, same conversation → 200 (tenant-wide access preserved)" do
      conn = MessageController.index(app_conn(), %{"id" => @convo})
      assert conn.status == 200
    end

    test "cross-tenant id → 404 for the end-user actor" do
      conn = MessageController.index(end_user_conn(@member), %{"id" => @cross_convo})
      assert_opaque_not_found(conn)
    end

    test "cross-tenant id → 404 for the app actor" do
      conn = MessageController.index(app_conn(), %{"id" => @cross_convo})
      assert_opaque_not_found(conn)
    end
  end

  # --- POST /v1/conversations/:id/messages ----------------------------------------------------------

  describe "POST /conversations/:id/messages" do
    defp send_params(id), do: %{"id" => id, "message_type" => "text", "body" => "hi"}

    test "end-user participant → 201" do
      conn = MessageController.create(end_user_conn(@member), send_params(@convo))
      assert conn.status == 201
    end

    test "end-user NON-participant → 404 (opaque, not 403) — cannot post into a conversation they aren't in" do
      conn = MessageController.create(end_user_conn(@stranger), send_params(@convo))
      assert_opaque_not_found(conn)
    end

    test "secret-key actor (names the sender) → 201 (tenant-wide send preserved)" do
      params = Map.put(send_params(@convo), "sender", "ext-alice")
      conn = MessageController.create(app_conn(), params)
      assert conn.status == 201
    end

    test "cross-tenant id → 404 for the end-user actor" do
      conn = MessageController.create(end_user_conn(@member), send_params(@cross_convo))
      assert_opaque_not_found(conn)
    end
  end

  # --- GET /v1/conversations/:id --------------------------------------------------------------------

  describe "GET /conversations/:id" do
    test "end-user participant → 200, and the body is the SAFE summary (no internal participant ids)" do
      conn = ConversationController.show(end_user_conn(@member), %{"id" => @convo})
      assert conn.status == 200
      b = body(conn)
      assert b["conversation_id"] == @convo
      # The detail shape's internal participant user_ids must NOT cross the /v1 boundary.
      refute Map.has_key?(b, "participants")
    end

    test "end-user NON-participant → 404 (opaque, not 403)" do
      conn = ConversationController.show(end_user_conn(@stranger), %{"id" => @convo})
      assert_opaque_not_found(conn)
    end

    test "secret-key actor, same conversation → 200" do
      conn = ConversationController.show(app_conn(), %{"id" => @convo})
      assert conn.status == 200
      assert body(conn)["conversation_id"] == @convo
    end

    test "cross-tenant id → 404 for the end-user actor" do
      conn = ConversationController.show(end_user_conn(@member), %{"id" => @cross_convo})
      assert_opaque_not_found(conn)
    end

    test "cross-tenant id → 404 for the app actor" do
      conn = ConversationController.show(app_conn(), %{"id" => @cross_convo})
      assert_opaque_not_found(conn)
    end
  end

  # --- POST /v1/conversations -----------------------------------------------------------------------

  describe "POST /conversations" do
    test "end-user actor → created_by is the caller, and the caller is a participant even if omitted" do
      # The request lists only Bob — the caller (Alice/@member) is absent from participants.
      conn =
        ConversationController.create(end_user_conn(@member), %{
          "type" => "direct",
          "participants" => ["ext-bob"]
        })

      assert conn.status == 201
      b = body(conn)
      assert b["created_by"] == @member
      assert @member in b["participant_user_ids"]
      assert @bob in b["participant_user_ids"]
    end

    test "secret-key actor → unchanged (first resolved participant is the creator; caller not forced in)" do
      conn =
        ConversationController.create(app_conn(), %{
          "type" => "direct",
          "participants" => ["ext-bob", "ext-alice"]
        })

      assert conn.status == 201
      b = body(conn)
      assert b["created_by"] == @bob
      assert b["participant_user_ids"] == [@bob, @member]
    end
  end

  # --- GET /v1/conversations ------------------------------------------------------------------------

  describe "GET /conversations" do
    test "end-user actor → only THEIR conversations; another user's is absent" do
      conn = ConversationController.index(end_user_conn(@member), %{})
      assert conn.status == 200
      ids = body(conn)["conversations"] |> Enum.map(& &1["conversation_id"])
      assert @convo in ids
      refute @other_convo in ids
    end

    test "end-user list rows drop the internal group-avatar storage keys" do
      conn = ConversationController.index(end_user_conn(@member), %{})
      row = body(conn)["conversations"] |> hd()
      refute Map.has_key?(row, "group_avatar_object_key")
      refute Map.has_key?(row, "group_avatar_media_id")
    end

    test "secret-key actor → 403 v1.end_user_only (no tenant-wide list here)" do
      conn = ConversationController.index(app_conn(), %{})
      assert conn.status == 403
      assert body(conn)["error"]["code"] == "v1.end_user_only"
    end
  end
end
