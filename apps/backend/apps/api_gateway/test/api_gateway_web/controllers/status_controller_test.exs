defmodule ApiGatewayWeb.StatusControllerTest do
  @moduledoc """
  Status endpoints + the purpose-"status" media-authz arm (Docker-free; Auth/Message/Media clients
  stubbed). Proves: create 201 (text) and the media-ownership gate (a foreign / wrong-purpose /
  not-ready media_id → 422 status.invalid_media — the avatar ownership rule); the feed carries
  `my_status` (nil without posts, summary with); validation codes surface; delete 404 maps; the
  MediaAuthz "status" arm allows exactly when the message service says allowed (deny + unavailable
  mapped; UNKNOWN purposes stay denied — nothing else loosened); 401s. Commit 2 adds: the audience
  settings round-trip + its codes, view recording (404 when the caller can't see the post), the
  owner-only viewer list incl. viewers_hidden passthrough, and my_status carrying its view count. The
  audience/expiry/sweep/reciprocity SQL is MessageService.StatusesTest.

  Commit 3 adds replies: the DM goes through the ORDINARY create path (resolve-or-create direct →
  authorize_send → create_message) carrying a TEXT-ONLY metadata.status_ref snapshot; the reply-time
  audience refusal is a clean 403 status.reply_forbidden; a self-reply is refused 409 BEFORE any
  conversation is created; a blocked owner still yields the synthetic-ack 201 with no live fan-out.
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

    # "My status" now carries its VIEW COUNT (commit 2).
    def my_status(%{"owner_user_id" => @me}),
      do: {:ok, %{post_count: 2, latest_at: "t6", view_count: 3, viewers_hidden: false}}

    def my_status(_attrs), do: {:ok, nil}

    def list_status_posts(%{"owner_user_id" => owner}) when owner != @me, do: {:ok, %{posts: []}}
    def list_status_posts(_attrs), do: {:ok, %{posts: []}}

    # --- commit 2 ---
    def get_status_audience(%{"user_id" => @me}),
      do: {:ok, %{mode: "contacts", member_user_ids: []}}

    def set_status_audience(%{"mode" => "everyone"}), do: {:error, :status_invalid_mode}
    def set_status_audience(%{"mode" => "toomany"}), do: {:error, :status_audience_limit}

    def set_status_audience(%{"mode" => mode, "member_user_ids" => members}),
      do: {:ok, %{mode: mode, member_user_ids: members || []}}

    # A status the caller can't see (or that doesn't exist) → not_found, identical either way.
    def record_status_view(%{"status_id" => "st-1"}), do: {:ok, %{recorded: true}}
    def record_status_view(_attrs), do: {:error, :status_not_found}

    # Owner-only: only @me owns "st-1".
    def status_viewers(%{"status_id" => "st-1", "owner_user_id" => @me}),
      do:
        {:ok,
         %{
           status_id: "st-1",
           viewers: [%{user_id: @friend, viewed_at: "t7"}],
           view_count: 1,
           viewers_hidden: false
         }}

    def status_viewers(_attrs), do: {:error, :status_not_found}

    # --- commit 3 ---
    # "st-1" is @friend's live status, visible to @me. "st-gone" fell out of the audience (live but
    # not visible now); "st-mine" is the caller's OWN; anything else is unknown/expired.
    def status_for_reply(%{"status_id" => "st-1", "viewer_user_id" => @me}),
      do: {:ok, %{owner_user_id: @friend, status_id: "st-1", kind: "image", excerpt: "at the beach"}}

    def status_for_reply(%{"status_id" => "st-mine", "viewer_user_id" => @me}),
      do: {:ok, %{owner_user_id: @me, status_id: "st-mine", kind: "text", excerpt: "mine"}}

    def status_for_reply(%{"status_id" => "st-gone"}), do: {:error, :status_not_visible}
    def status_for_reply(_attrs), do: {:error, :status_not_found}

    def create_message(attrs) do
      send(:status_reply_test, {:created, attrs})
      {:ok, %{message_id: "msg-1", conversation_id: attrs["conversation_id"], body: attrs["body"]}}
    end

    def delete_status(%{"status_id" => "st-1", "owner_user_id" => @me}), do: {:ok, %{deleted: true}}
    def delete_status(_attrs), do: {:error, :status_not_found}

    # The authz arm's oracle: media "m-ok" visible to @friend; everything else denied.
    def status_media_allowed(%{"media_id" => "m-ok", "viewer_user_id" => @friend}),
      do: {:ok, %{allowed: true}}

    def status_media_allowed(%{"media_id" => "m-down"}), do: {:error, :message_unavailable}
    def status_media_allowed(_attrs), do: {:ok, %{allowed: false}}
  end

  defmodule ConvStub do
    @owner_dm "dm-with-owner"

    def start_link, do: Agent.start_link(fn -> %{log: [], blocked: false} end, name: __MODULE__)
    def set_blocked(v), do: Agent.update(__MODULE__, &Map.put(&1, :blocked, v))
    def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()
    defp record(entry), do: Agent.update(__MODULE__, &Map.update!(&1, :log, fn l -> [entry | l] end))

    # The SAME entry point a normal first DM uses (find_or_create_direct downstream).
    def create_conversation(%{"type" => "direct", "participant_user_ids" => [recipient]} = attrs) do
      record({:create_conversation, recipient, attrs["created_by"]})
      {:ok, %{conversation_id: @owner_dm, type: "direct", created: true}}
    end

    def authorize_send(_attrs) do
      if Agent.get(__MODULE__, & &1.blocked),
        do: {:ok, %{authorized: true, delivery: "drop"}},
        else: {:ok, %{authorized: true}}
    end

    def get_conversation(_attrs), do: {:ok, %{participants: []}}

    def inbox_rows(%{"user_ids" => uids, "conversation_id" => cid}),
      do: {:ok, %{rows: Enum.map(uids, &%{user_id: &1, conversation_id: cid, unread_count: 0})}}
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
    Process.register(self(), :status_reply_test)
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
      restore(:media_client_adapter, prev.media)
      restore(:conversation_client_adapter, prev.conv)
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

  test "feed: threads + my_status carrying its VIEW COUNT (commit 2)" do
    conn = StatusController.feed(authed(:get), %{})
    assert conn.status == 200

    response = body(conn)
    assert [%{"owner_user_id" => @friend, "post_count" => 2, "unseen_count" => 1}] = response["threads"]

    assert response["my_status"] == %{
             "post_count" => 2,
             "latest_at" => "t6",
             "view_count" => 3,
             "viewers_hidden" => false
           }
  end

  test "audience settings round-trip; invalid mode + cap carry their codes" do
    get_conn = StatusController.get_audience(authed(:get), %{})
    assert get_conn.status == 200
    assert body(get_conn) == %{"mode" => "contacts", "member_user_ids" => []}

    set_conn =
      StatusController.set_audience(authed(:put), %{"mode" => "only", "member_user_ids" => [@friend]})

    assert set_conn.status == 200
    assert body(set_conn) == %{"mode" => "only", "member_user_ids" => [@friend]}

    bad = StatusController.set_audience(authed(:put), %{"mode" => "everyone"})
    assert bad.status == 400
    assert body(bad)["error"]["code"] == "status.invalid_mode"

    capped = StatusController.set_audience(authed(:put), %{"mode" => "toomany"})
    assert capped.status == 400
    assert body(capped)["error"]["code"] == "status.audience_limit"
    assert body(capped)["error"]["limit"] == 256
  end

  test "view recording: 200 when visible; 404 when the caller can't see it (indistinguishable from unknown)" do
    ok = StatusController.record_view(authed(:post), %{"status_id" => "st-1"})
    assert ok.status == 200
    assert body(ok) == %{"recorded" => true}

    hidden = StatusController.record_view(authed(:post), %{"status_id" => "not-visible"})
    assert hidden.status == 404
    assert body(hidden)["error"]["code"] == "status.not_found"
  end

  test "viewer list is OWNER-ONLY: the owner gets it, anyone else 404s" do
    mine = StatusController.viewers(authed(:get), %{"status_id" => "st-1"})
    assert mine.status == 200

    assert body(mine) == %{
             "status_id" => "st-1",
             "viewers" => [%{"user_id" => @friend, "viewed_at" => "t7"}],
             "view_count" => 1,
             "viewers_hidden" => false
           }

    theirs = StatusController.viewers(authed(:get, @friend), %{"status_id" => "st-1"})
    assert theirs.status == 404
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

  test "REPLY: an ordinary DM through the normal create path, carrying the TEXT-ONLY snapshot" do
    conn = StatusController.reply(authed(:post), %{"status_id" => "st-1", "body" => "love this"})

    assert conn.status == 201
    assert body(conn)["message_id"] == "msg-1"

    # The DM was resolved through the SAME create_conversation entry point (direct, to the owner).
    assert ConvStub.log() == [{:create_conversation, @friend, @me}]

    # The outgoing message is a plain text DM whose metadata quotes a snapshot — no media pointer.
    assert_received {:created, attrs}
    assert attrs["message_type"] == "text"
    assert attrs["body"] == "love this"
    ref = attrs["metadata"]["status_ref"]
    assert ref == %{"status_id" => "st-1", "kind" => "image", "excerpt" => "at the beach"}
    refute Map.has_key?(ref, "thumbnail_media_id")
    refute Map.has_key?(ref, "media_id")
    # Nothing marks it as a drop (the owner hasn't blocked the replier).
    refute Map.has_key?(attrs, "delivery_disposition")
  end

  test "REPLY-TIME audience refusal → 403 status.reply_forbidden, and NO conversation is created" do
    conn = StatusController.reply(authed(:post), %{"status_id" => "st-gone", "body" => "hi"})

    assert conn.status == 403
    assert body(conn)["error"]["code"] == "status.reply_forbidden"
    # The refusal happens BEFORE any DM is minted.
    assert ConvStub.log() == []
    refute_received {:created, _}
  end

  test "SELF-REPLY → 409 status.cannot_reply_own, refused BEFORE any conversation is created" do
    conn = StatusController.reply(authed(:post), %{"status_id" => "st-mine", "body" => "hi"})

    assert conn.status == 409
    assert body(conn)["error"]["code"] == "status.cannot_reply_own"
    # Critical: no orphan single-participant conversation was minted.
    assert ConvStub.log() == []
    refute_received {:created, _}
  end

  test "a BLOCKED owner still yields the synthetic 201 (block-drop inherited, no live fan-out)" do
    ConvStub.set_blocked(true)
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@friend}")

    conn = StatusController.reply(authed(:post), %{"status_id" => "st-1", "body" => "hello?"})

    assert conn.status == 201
    assert_received {:created, attrs}
    # The server sets the drop flag; the sender learns nothing.
    assert attrs["delivery_disposition"] == "drop"
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_updated"}, 200
  end

  test "reply validation: unknown status → 404; empty body → 400" do
    unknown = StatusController.reply(authed(:post), %{"status_id" => "nope", "body" => "hi"})
    assert unknown.status == 404

    empty = StatusController.reply(authed(:post), %{"status_id" => "st-1", "body" => "   "})
    assert empty.status == 400
    assert body(empty)["error"]["code"] == "status.invalid_body"
  end

  test "no session → 401 across the surface (incl. the commit-2 actions)" do
    assert StatusController.create(authed(:post, ""), %{"kind" => "text", "body" => "x"}).status == 401
    assert StatusController.feed(authed(:get, ""), %{}).status == 401
    assert StatusController.delete(authed(:delete, ""), %{"status_id" => "s"}).status == 401
    assert StatusController.get_audience(authed(:get, ""), %{}).status == 401
    assert StatusController.set_audience(authed(:put, ""), %{"mode" => "contacts"}).status == 401
    assert StatusController.record_view(authed(:post, ""), %{"status_id" => "st-1"}).status == 401
    assert StatusController.viewers(authed(:get, ""), %{"status_id" => "st-1"}).status == 401
    assert StatusController.reply(authed(:post, ""), %{"status_id" => "st-1", "body" => "x"}).status == 401
  end
end
