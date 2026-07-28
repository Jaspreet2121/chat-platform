defmodule ApiGatewayWeb.InviteLinkControllerTest do
  @moduledoc """
  Group invite-link endpoints. Session-gated; ConversationClient + Media/Auth stubbed, no DB/HTTP. Proves the
  contract: create/reset → {code, url} (url from web_base_url + /join/<code>); non-owner → 403
  conversation.not_owner; revoke → {revoked}; preview → EXACTLY {name, avatar_url, member_count}; join fresh
  → 200 {status:"joined"} AND a conversation_updated :participant frame to the joiner (like an owner add),
  already-member → no frame, removed → 403 invite_link.removed, unknown code → 404; no session → 401. The SQL
  (owner-only, one-active, join cases, app-scope) is proven in ConversationService.InviteLinksTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.InviteLinkController

  @conv "22222222-2222-4222-8222-222222222222"
  @code "the-invite-code"
  @reset_code "the-reset-code"
  @owner "u-owner"
  @joiner "u-joiner"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @conv "22222222-2222-4222-8222-222222222222"
    @code "the-invite-code"

    # Owner-only management (actor "u-owner" is the owner; anyone else → not_owner).
    def create_group_invite_link(%{"actor_user_id" => "u-owner", "conversation_id" => c}),
      do: {:ok, %{code: "the-invite-code", conversation_id: c}}

    def create_group_invite_link(_), do: {:error, :not_owner}

    def revoke_group_invite_link(%{"actor_user_id" => "u-owner"}), do: {:ok, %{revoked: true}}
    def revoke_group_invite_link(_), do: {:error, :not_owner}

    def reset_group_invite_link(%{"actor_user_id" => "u-owner", "conversation_id" => c}),
      do: {:ok, %{code: "the-reset-code", conversation_id: c}}

    def reset_group_invite_link(_), do: {:error, :not_owner}

    def preview_group_invite_link(%{"code" => @code}),
      do: {:ok, %{name: "Design Team", group_avatar_media_id: "gm-1", member_count: 3}}

    def preview_group_invite_link(_), do: {:error, :link_not_found}

    def join_group_invite_link(%{"code" => code, "user_id" => uid}) do
      cond do
        code != @code -> {:error, :link_not_found}
        uid == "u-removed" -> {:error, :removed}
        uid == "u-already" -> {:ok, %{status: "already_member", conversation_id: @conv, role: "member"}}
        true -> {:ok, %{status: "joined", conversation_id: @conv, role: "member"}}
      end
    end

    # Consumed by the :participant broadcast after a fresh join (fans to each participant's own row).
    def get_conversation(_attrs), do: {:ok, %{participants: [%{user_id: "u-joiner"}]}}

    def inbox_rows(%{"user_ids" => uids}) do
      {:ok, %{rows: Enum.map(uids, &%{user_id: &1, conversation_id: @conv, unread_count: 0})}}
    end
  end

  defmodule MediaStub do
    def get_download_url(%{"media_id" => "gm-1", "purpose" => "group_avatar"}),
      do: {:ok, %{download_url: "https://signed/gm-1"}}

    def get_download_url(_), do: {:error, :not_found}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      web: Application.get_env(:api_gateway, :web_base_url)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:api_gateway, :web_base_url, "https://web.test")

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev.auth)
      restore(:shared_infra, :conversation_client_adapter, prev.conv)
      restore(:shared_infra, :media_client_adapter, prev.media)
      restore(:api_gateway, :web_base_url, prev.web)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp authed(uid) do
    :post |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{uid}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "create → 200 {code, url} with url built from web_base_url + /join/<code>" do
    conn = InviteLinkController.create_link(authed(@owner), %{"conversation_id" => @conv})
    assert conn.status == 200
    assert body(conn) == %{"code" => @code, "url" => "https://web.test/join/#{@code}"}
  end

  test "create by a NON-owner → 403 conversation.not_owner" do
    conn = InviteLinkController.create_link(authed("u-member"), %{"conversation_id" => @conv})
    assert conn.status == 403
    assert body(conn)["error"]["code"] == "conversation.not_owner"
  end

  test "revoke → 200 {revoked: true}; reset → 200 {code, url}" do
    revoked = InviteLinkController.revoke_link(authed(@owner), %{"conversation_id" => @conv})
    assert revoked.status == 200
    assert body(revoked) == %{"revoked" => true}

    reset = InviteLinkController.reset_link(authed(@owner), %{"conversation_id" => @conv})
    assert reset.status == 200
    assert body(reset) == %{"code" => @reset_code, "url" => "https://web.test/join/#{@reset_code}"}
  end

  test "preview → 200 with EXACTLY {name, avatar_url, member_count} (avatar presigned)" do
    conn = InviteLinkController.preview(authed(@joiner), %{"code" => @code})
    assert conn.status == 200

    b = body(conn)
    assert b == %{"name" => "Design Team", "avatar_url" => "https://signed/gm-1", "member_count" => 3}
    # Exactly the three fields — no member list, no conversation_id, nothing more.
    assert Enum.sort(Map.keys(b)) == ["avatar_url", "member_count", "name"]
  end

  test "preview of an unknown code → 404 invite_link.not_found" do
    conn = InviteLinkController.preview(authed(@joiner), %{"code" => "nope"})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "invite_link.not_found"
  end

  test "join fresh → 200 {status:joined} AND a conversation_updated :participant frame to the joiner" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@joiner}")

    conn = InviteLinkController.join(authed(@joiner), %{"code" => @code})
    assert conn.status == 200
    assert body(conn) == %{"status" => "joined", "conversation_id" => @conv, "role" => "member"}

    # The fresh join fires the SAME frame an owner add fires — the group appears in the joiner's inbox live.
    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_updated", topic: topic}, 1000
    assert topic == "user:#{@joiner}"
  end

  test "join when ALREADY a member → 200 {already_member} and NO broadcast (nothing changed)" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:u-already")

    conn = InviteLinkController.join(authed("u-already"), %{"code" => @code})
    assert conn.status == 200
    assert body(conn)["status"] == "already_member"

    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_updated"}, 300
  end

  test "join by a REMOVED user → 403 invite_link.removed" do
    conn = InviteLinkController.join(authed("u-removed"), %{"code" => @code})
    assert conn.status == 403
    assert body(conn)["error"]["code"] == "invite_link.removed"
  end

  test "join with an unknown code → 404 invite_link.not_found" do
    conn = InviteLinkController.join(authed(@joiner), %{"code" => "nope"})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "invite_link.not_found"
  end

  test "no session → 401" do
    conn = InviteLinkController.create_link(authed(""), %{"conversation_id" => @conv})
    assert conn.status == 401
  end
end
