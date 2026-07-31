defmodule ApiGatewayWeb.MediaAvatarPresignTest do
  @moduledoc """
  The avatar/admin presign call-sites now pass app_id (the asset's tenant) and assert the asset's purpose.
  The stubbed MediaClient mimics the real media service: it presigns ONLY when (app_id, purpose) match the
  row; otherwise :not_found. So these prove each call-site scopes to the right app and refuses a
  wrong-purpose asset (the avatar_media_id poisoning narrowing), and that the tenant app_id never leaks.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.{AdminContentController, ConversationController, UserController}

  @app "44444444-4444-4444-8444-444444444444"
  @user_ok "22222222-2222-4222-8222-222222222222"
  @user_cross "33333333-3333-4333-8333-333333333333"
  @user_poison "77777777-7777-4777-8777-777777777777"
  @user_noavatar "88888888-8888-4888-8888-888888888888"
  @member "22222222-2222-4222-8222-222222222222"
  @convo "11111111-1111-4111-8111-111111111111"

  # avatar assets (media_id → {app, purpose}) — see MediaStub. @avatar_cross / @avatar_poison live in the
  # stubs (nested modules have their own attribute scope); the tests reach them via @user_cross/@user_poison.
  @avatar_ok "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @group_ok "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  @group_cross "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
  @msg_ok "ffffffff-ffff-4fff-8fff-ffffffffffff"

  defmodule MediaStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    @other_app "99999999-9999-4999-8999-999999999999"
    @avatar_ok "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    @avatar_cross "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    @avatar_poison "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    @group_ok "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    @group_cross "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    @msg_ok "ffffffff-ffff-4fff-8fff-ffffffffffff"

    # (media_id → {app_id, purpose}). A poisoned avatar points at a MESSAGE asset in the same app.
    @assets %{
      @avatar_ok => %{app_id: @app, purpose: "user_avatar"},
      @avatar_cross => %{app_id: @other_app, purpose: "user_avatar"},
      @avatar_poison => %{app_id: @app, purpose: "message"},
      @group_ok => %{app_id: @app, purpose: "group_avatar"},
      @group_cross => %{app_id: @other_app, purpose: "group_avatar"},
      @msg_ok => %{app_id: @app, purpose: "message"}
    }

    # Presign only when BOTH app_id and purpose match the row (mirrors media.ex download_persisted).
    def get_download_url(%{"media_id" => id, "app_id" => app, "purpose" => purpose}) do
      case Map.get(@assets, id) do
        %{app_id: ^app, purpose: ^purpose} ->
          {:ok,
           %{
             media_id: id,
             download_url: "https://minio.local/get/" <> id,
             expires_at: "x",
             mime_type: "image/png"
           }}

        _ ->
          {:error, :not_found}
      end
    end

    def get_download_url(_), do: {:error, :not_found}
  end

  defmodule UserStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    @user_ok "22222222-2222-4222-8222-222222222222"
    @user_cross "33333333-3333-4333-8333-333333333333"
    @user_poison "77777777-7777-4777-8777-777777777777"
    @avatar_ok "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    @avatar_cross "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    @avatar_poison "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    def get_public_profile(%{"user_id" => uid}), do: {:ok, profile(uid)}
    def get_current_profile(%{"user_id" => uid}), do: {:ok, profile(uid)}

    # The PROFILE is always in @app; its avatar_media_id may point at an asset in another app / wrong purpose.
    defp profile(uid) do
      %{
        user_id: uid,
        display_name: "U",
        bio: nil,
        app_id: @app,
        avatar_object_key: "media/x/y/a.png",
        avatar_media_id: avatar_for(uid)
      }
    end

    defp avatar_for(@user_ok), do: @avatar_ok
    defp avatar_for(@user_cross), do: @avatar_cross
    defp avatar_for(@user_poison), do: @avatar_poison
    defp avatar_for(_), do: nil
  end

  defmodule AuthStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    @member "22222222-2222-4222-8222-222222222222"
    @convo "11111111-1111-4111-8111-111111111111"

    # get_conversation (membership) returns a detail map with a group_avatar_media_id set by the test.
    def get_conversation(%{"user_id" => @member} = attrs) do
      {:ok,
       %{
         conversation_id: @convo,
         app_id: "44444444-4444-4444-8444-444444444444",
         type: "group",
         group_avatar_media_id: Map.get(attrs, "group_avatar_media_id_for_test"),
         participants: [%{user_id: @member, role: "owner"}]
       }}
    end

    def get_conversation(_), do: {:error, :conversation_forbidden}
  end

  setup do
    prev = %{
      persist: Application.get_env(:conversation_service, :conversation_persistence, false),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:conversation_service, :conversation_persistence, true)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, prev.persist)
      restore(:media_client_adapter, prev.media)
      restore(:user_client_adapter, prev.user)
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # profile/avatar are authenticated now — the AuthStub maps "Bearer <uid>" → a session in @app.
  defp authed_conn, do: put_req_header(conn(:get, "/"), "authorization", "Bearer caller-1")

  # --- user avatar (via GET /users/:id/profile — session-gated) -------------------------------------

  test "profile with a valid same-app avatar → 200, avatar_url present, app_id NOT leaked" do
    conn = UserController.profile(authed_conn(), %{"user_id" => @user_ok})
    assert conn.status == 200
    b = body(conn)
    assert b["avatar_url"] == "https://minio.local/get/" <> @avatar_ok
    refute Map.has_key?(b, "app_id")
  end

  test "profile whose avatar_media_id points at an asset in ANOTHER app → no avatar (fail-open), no cross-tenant presign" do
    conn = UserController.profile(authed_conn(), %{"user_id" => @user_cross})
    assert conn.status == 200
    assert body(conn)["avatar_url"] == nil
    refute Map.has_key?(body(conn), "app_id")
  end

  test "avatar_media_id pointing at a purpose=message asset → no avatar (the purpose assertion)" do
    conn = UserController.profile(authed_conn(), %{"user_id" => @user_poison})
    assert conn.status == 200
    assert body(conn)["avatar_url"] == nil
  end

  test "profile with no avatar → avatar_url nil" do
    conn = UserController.profile(authed_conn(), %{"user_id" => @user_noavatar})
    assert conn.status == 200
    assert body(conn)["avatar_url"] == nil
  end

  # --- the 302 /users/:id/avatar route --------------------------------------------------------------

  test "GET /users/:id/avatar redirects (302) when the avatar is valid" do
    conn = UserController.avatar(authed_conn(), %{"user_id" => @user_ok})
    assert conn.status == 302
    assert Enum.any?(conn.resp_headers, fn {k, v} -> k == "location" and v =~ @avatar_ok end)
  end

  test "GET /users/:id/avatar → 404 when there is no avatar" do
    conn = UserController.avatar(authed_conn(), %{"user_id" => @user_noavatar})
    assert conn.status == 404
  end

  # --- group avatar (via GET /conversations/:id show) -----------------------------------------------

  # Drive ConversationController.show; the test's chosen group_avatar_media_id rides through the ConvStub
  # via a params key it echoes into the conversation map (→ with_group_avatar_url).
  defp show(user_id, group_avatar_media_id) do
    base =
      put_req_header(
        conn(:get, "/api/v1/conversations/#{@convo}", %{}),
        "authorization",
        "Bearer " <> user_id
      )

    ConversationController.show(base, %{
      "conversation_id" => @convo,
      "group_avatar_media_id_for_test" => group_avatar_media_id
    })
  end

  test "group avatar: a member with a valid same-app group avatar → group_avatar_url present" do
    conn = show(@member, @group_ok)
    assert conn.status == 200
    assert body(conn)["group_avatar_url"] == "https://minio.local/get/" <> @group_ok
  end

  test "group avatar in ANOTHER app → no group_avatar_url" do
    conn = show(@member, @group_cross)
    assert conn.status == 200
    assert body(conn)["group_avatar_url"] == nil
  end

  test "group avatar pointing at a purpose=message asset → no group_avatar_url" do
    conn = show(@member, @msg_ok)
    assert conn.status == 200
    assert body(conn)["group_avatar_url"] == nil
  end

  # --- admin content (enrich_media/2 direct) --------------------------------------------------------

  test "admin content presigns message media with the asset's app_id" do
    enriched =
      AdminContentController.enrich_media(%{message_type: "media", media_id: @msg_ok}, @app)

    assert enriched.download_url == "https://minio.local/get/" <> @msg_ok
  end

  test "admin content with the WRONG app_id → no download_url" do
    enriched =
      AdminContentController.enrich_media(
        %{message_type: "media", media_id: @msg_ok},
        "99999999-9999-4999-8999-999999999999"
      )

    refute Map.has_key?(enriched, :download_url)
  end
end
