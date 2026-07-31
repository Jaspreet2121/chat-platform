defmodule ApiGatewayWeb.BlockControllerTest do
  @moduledoc """
  The first-party block endpoints: POST/DELETE/GET /api/v1/blocks. Session-authed; the blocker is always the
  session user. Stubs AuthClient (token → session), ConversationClient (block/unblock/list) and
  UserClient/MediaClient (list enrichment) — no DB. The block RELATIONSHIP + enforcement are proven in
  ConversationService.BlocksTest; here we prove the controller's contract: 204s, self→400, unknown→404, the
  enriched list, and the session gate.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.BlockController

  @me "11111111-1111-4111-8111-111111111111"
  @target "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    @app "33333333-3333-4333-8333-333333333333"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    def block_user(%{"blocker_user_id" => b, "blocked_user_id" => t}) do
      cond do
        b == t -> {:error, :block_self}
        t == "ghost" -> {:error, :block_unknown_user}
        true -> {:ok, %{blocker_user_id: b, blocked_user_id: t}}
      end
    end

    def unblock_user(%{"blocker_user_id" => b, "blocked_user_id" => t}),
      do: {:ok, %{blocker_user_id: b, blocked_user_id: t}}

    def list_blocks(%{"blocker_user_id" => _}),
      do:
        {:ok,
         %{
           blocks: [
             %{
               user_id: "22222222-2222-4222-8222-222222222222",
               created_at: "2026-07-01T00:00:00Z"
             }
           ]
         }}
  end

  defmodule UserStub do
    def get_public_profile(%{"user_id" => uid}),
      do: {:ok, %{user_id: uid, display_name: "Bob", avatar_media_id: "m1"}}
  end

  defmodule MediaStub do
    def get_download_url(%{"purpose" => "user_avatar"}),
      do: {:ok, %{download_url: "https://minio/bob.png"}}

    def get_download_url(_), do: {:error, :not_found}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:user_client_adapter, prev.user)
      restore(:media_client_adapter, prev.media)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(token \\ "me") do
    :post |> conn("/api/v1/blocks", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  test "POST blocks a user → 204" do
    conn = BlockController.create(authed(), %{"user_id" => @target})
    assert conn.status == 204
  end

  test "blocking YOURSELF → 400" do
    conn = BlockController.create(authed(), %{"user_id" => @me})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "blocks.self"
  end

  test "blocking an UNKNOWN user → 404 (no existence leak)" do
    conn = BlockController.create(authed(), %{"user_id" => "ghost"})
    assert conn.status == 404
  end

  test "POST without a user_id → 400" do
    conn = BlockController.create(authed(), %{})
    assert conn.status == 400
  end

  test "DELETE unblocks → 204" do
    conn = BlockController.delete(authed(), %{"user_id" => @target})
    assert conn.status == 204
  end

  test "GET lists blocks, enriched with display_name + presigned avatar" do
    conn = BlockController.index(authed(), %{})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert [row] = body["blocks"]
    assert row["user_id"] == "22222222-2222-4222-8222-222222222222"
    assert row["display_name"] == "Bob"
    assert row["avatar_url"] == "https://minio/bob.png"
    assert row["created_at"] == "2026-07-01T00:00:00Z"
  end

  test "no session → 401" do
    conn = BlockController.create(authed("nobody"), %{"user_id" => @target})
    assert conn.status == 401
  end
end
