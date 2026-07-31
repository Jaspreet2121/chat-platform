defmodule ApiGatewayWeb.StatusControllerTest do
  @moduledoc """
  Status endpoints + the purpose-"status" media-authz arm (Docker-free; Auth/Message/Media clients
  stubbed). Proves: create 201 (text) and the media-ownership gate (a foreign / wrong-purpose /
  not-ready media_id → 422 status.invalid_media — the avatar ownership rule); the feed carries
  `my_status` (nil without posts, summary with); validation codes surface; delete 404 maps; the
  MediaAuthz "status" arm allows exactly when the message service says allowed (deny + unavailable
  mapped; UNKNOWN purposes stay denied — nothing else loosened); 401s. The audience/expiry/sweep SQL is
  MessageService.StatusesTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.{MediaAuthz, StatusController}

  @me "11111111-1111-4111-8111-111111111111"
  @friend "22222222-2222-4222-8222-222222222222"
  @my_media "33333333-3333-4333-8333-333333333333"
  @foreign_media "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule MsgStub do
    @me "11111111-1111-4111-8111-111111111111"
    @friend "22222222-2222-4222-8222-222222222222"

    def post_status(%{"kind" => "audio"}), do: {:error, :status_invalid_kind}

    def post_status(attrs) do
      {:ok,
       %{
         status_id: "st-1",
         owner_user_id: attrs["owner_user_id"],
         kind: attrs["kind"],
         body: attrs["body"],
         media_id: attrs["media_id"],
         created_at: "t1",
         expires_at: "t2"
       }}
    end

    def status_feed(%{"viewer_user_id" => @me}),
      do: {:ok, %{threads: [%{owner_user_id: @friend, post_count: 2, latest_at: "t9", unseen_count: 1}]}}

    # The viewer's own posts (my_status): present for @me, empty for others.
    def list_status_posts(%{"viewer_user_id" => @me, "owner_user_id" => @me}),
      do: {:ok, %{posts: [%{status_id: "mine-1", created_at: "t5"}, %{status_id: "mine-2", created_at: "t6"}]}}

    def list_status_posts(%{"owner_user_id" => owner}) when owner != @me, do: {:ok, %{posts: []}}

    def delete_status(%{"status_id" => "st-1", "owner_user_id" => @me}), do: {:ok, %{deleted: true}}
    def delete_status(_attrs), do: {:error, :status_not_found}

    # The authz arm's oracle: media "m-ok" visible to @friend; everything else denied.
    def status_media_allowed(%{"media_id" => "m-ok", "viewer_user_id" => @friend}),
      do: {:ok, %{allowed: true}}

    def status_media_allowed(%{"media_id" => "m-down"}), do: {:error, :message_unavailable}
    def status_media_allowed(_attrs), do: {:ok, %{allowed: false}}
  end

  defmodule MediaStub do
    @me "11111111-1111-4111-8111-111111111111"
    @my_media "33333333-3333-4333-8333-333333333333"
    @foreign_media "44444444-4444-4444-8444-444444444444"

    def get_asset(%{"media_id" => @my_media}),
      do: {:ok, %{owner_user_id: @me, purpose: "status", status: "ready"}}

    # Someone else's asset — right purpose, wrong owner.
    def get_asset(%{"media_id" => @foreign_media}),
      do: {:ok, %{owner_user_id: "someone-else", purpose: "status", status: "ready"}}

    # The caller's own asset but a chat-message upload — wrong purpose.
    def get_asset(%{"media_id" => "chat-upload"}),
      do: {:ok, %{owner_user_id: @me, purpose: "message", status: "ready"}}

    def get_asset(_attrs), do: {:error, :not_found}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
      restore(:media_client_adapter, prev.media)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(method, token \\ @me) do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "create: text 201; OWN ready status-upload 201; foreign / wrong-purpose media → 422 invalid_media" do
    text = StatusController.create(authed(:post), %{"kind" => "text", "body" => "hi"})
    assert text.status == 201
    assert body(text)["status_id"] == "st-1"

    ok_media = StatusController.create(authed(:post), %{"kind" => "image", "media_id" => @my_media})
    assert ok_media.status == 201

    for media_id <- [@foreign_media, "chat-upload", "unknown-id"] do
      conn = StatusController.create(authed(:post), %{"kind" => "image", "media_id" => media_id})
      assert conn.status == 422, "expected 422 for #{media_id}"
      assert body(conn)["error"]["code"] == "status.invalid_media"
    end
  end

  test "validation codes surface: unknown kind → status.invalid_kind" do
    conn = StatusController.create(authed(:post), %{"kind" => "audio", "body" => "x"})
    assert conn.status == 400
    assert body(conn)["error"]["code"] == "status.invalid_kind"
  end

  test "feed: threads + my_status summary (latest of the viewer's own posts)" do
    conn = StatusController.feed(authed(:get), %{})
    assert conn.status == 200

    response = body(conn)
    assert [%{"owner_user_id" => @friend, "post_count" => 2, "unseen_count" => 1}] = response["threads"]
    assert response["my_status"] == %{"post_count" => 2, "latest_at" => "t6"}
  end

  test "an owner list the viewer can't see is an EMPTY list (no existence reveal); delete maps 404" do
    conn = StatusController.list(authed(:get), %{"owner_user_id" => "55555555-5555-4555-8555-555555555555"})
    assert conn.status == 200
    assert body(conn)["posts"] == []

    assert StatusController.delete(authed(:delete), %{"status_id" => "st-1"}).status == 200

    gone = StatusController.delete(authed(:delete), %{"status_id" => "not-mine"})
    assert gone.status == 404
    assert body(gone)["error"]["code"] == "status.not_found"
  end

  test "the MediaAuthz 'status' arm: allowed ⇔ the status service says so; unknown purposes stay denied" do
    # Visible to the friend → :ok.
    assert :ok = MediaAuthz.authorize_download("m-ok", %{purpose: "status"}, @friend)
    # Not visible (stranger / expired / deleted — the service said no) → denied.
    assert {:error, :not_a_member} = MediaAuthz.authorize_download("m-ok", %{purpose: "status"}, @me)
    assert {:error, :not_a_member} = MediaAuthz.authorize_download("m-hidden", %{purpose: "status"}, @friend)
    # Service down → unavailable (fail closed, mapped like the message arm).
    assert {:error, :conversation_unavailable} =
             MediaAuthz.authorize_download("m-down", %{purpose: "status"}, @friend)

    # The catch-all is untouched: an unknown purpose is still denied.
    assert {:error, :not_a_member} = MediaAuthz.authorize_download("x", %{purpose: "mystery"}, @me)
  end

  test "no session → 401 across the surface" do
    assert StatusController.create(authed(:post, ""), %{"kind" => "text", "body" => "x"}).status == 401
    assert StatusController.feed(authed(:get, ""), %{}).status == 401
    assert StatusController.delete(authed(:delete, ""), %{"status_id" => "s"}).status == 401
  end
end
