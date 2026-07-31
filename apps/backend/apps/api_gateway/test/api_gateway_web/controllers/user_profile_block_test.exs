defmodule ApiGatewayWeb.UserProfileBlockTest do
  @moduledoc """
  Block redaction on the profile surfaces (GET /users/:id/profile + by-phone): a blocked user's account STILL
  EXISTS (name shown) but the avatar is hidden — identical to a user with no avatar, so the block is never
  revealed and "you are blocked" never leaks. Stubs AuthClient/UserClient/MediaClient/ConversationClient — no
  DB. (Last-seen/online is a separate surface, covered by SharedInfra.PresenceAuthzTest.)
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.UserController

  @target "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    @app "33333333-3333-4333-8333-333333333333"
    @target "22222222-2222-4222-8222-222222222222"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
    def lookup_user_by_phone(%{"phone_number" => "+15551234567"}), do: {:ok, %{user_id: @target}}
    def lookup_user_by_phone(_), do: {:error, :not_found}
  end

  defmodule UserStub do
    def start_link, do: Agent.start_link(fn -> "everyone" end, name: __MODULE__)
    def set_photo(v), do: Agent.update(__MODULE__, fn _ -> v end)

    def get_public_profile(%{"user_id" => uid}),
      do:
        {:ok,
         %{
           user_id: uid,
           display_name: "Bob",
           avatar_media_id: "m1",
           app_id: "33333333-3333-4333-8333-333333333333"
         }}

    def get_privacy(_attrs),
      do:
        {:ok,
         %{
           last_seen_visibility: "everyone",
           profile_photo_visibility: Agent.get(__MODULE__, & &1),
           read_receipts_enabled: true
         }}
  end

  defmodule MediaStub do
    def get_download_url(%{"purpose" => "user_avatar"}),
      do: {:ok, %{download_url: "https://minio/bob.png"}}

    def get_download_url(_), do: {:error, :not_found}
  end

  defmodule ConvStub do
    def start_link,
      do: Agent.start_link(fn -> %{blocked: false, shares: true} end, name: __MODULE__)

    def set_blocked(v), do: Agent.update(__MODULE__, &Map.put(&1, :blocked, v))
    def set_shares(v), do: Agent.update(__MODULE__, &Map.put(&1, :shares, v))
    def either_blocked?(_attrs), do: {:ok, %{blocked: Agent.get(__MODULE__, & &1.blocked)}}
    def shares_conversation?(_attrs), do: {:ok, %{shares: Agent.get(__MODULE__, & &1.shares)}}
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:user_client_adapter, prev.user)
      restore(:media_client_adapter, prev.media)
      restore(:conversation_client_adapter, prev.conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed do
    :get |> conn("/x") |> put_req_header("authorization", "Bearer me")
  end

  test "NOT blocked → profile shows the presigned avatar" do
    ConvStub.set_blocked(false)
    body = Jason.decode!(UserController.profile(authed(), %{"user_id" => @target}).resp_body)
    assert body["display_name"] == "Bob"
    assert body["avatar_url"] == "https://minio/bob.png"
  end

  test "BLOCKED → account exists (name) but the avatar is REDACTED, and the block never leaks" do
    ConvStub.set_blocked(true)
    conn = UserController.profile(authed(), %{"user_id" => @target})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["display_name"] == "Bob"
    assert body["user_id"] == @target
    # Avatar hidden — indistinguishable from a user who simply has none.
    assert body["avatar_url"] == nil
    refute Map.has_key?(body, "avatar_media_id")
    # Never reveals the block, and never leaks the internal tenant id.
    refute Enum.any?(Map.keys(body), &(&1 =~ "block"))
    refute Map.has_key?(body, "app_id")
  end

  test "by-phone lookup of a BLOCKED user is redacted the same way" do
    ConvStub.set_blocked(true)
    conn = UserController.by_phone(authed(), %{"phone" => "+15551234567"})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["display_name"] == "Bob"
    assert body["avatar_url"] == nil
    refute Map.has_key?(body, "avatar_media_id")
  end

  # --- profile_photo_visibility three-way (not blocked in any of these) ---

  defp avatar_url_for(target) do
    ConvStub.set_blocked(false)

    Jason.decode!(UserController.profile(authed(), %{"user_id" => target}).resp_body)[
      "avatar_url"
    ]
  end

  test "photo 'everyone' → avatar shown even WITHOUT a shared conversation" do
    UserStub.set_photo("everyone")
    ConvStub.set_shares(false)
    assert avatar_url_for(@target) == "https://minio/bob.png"
  end

  test "photo 'contacts' → shown WITH a shared conversation, HIDDEN without" do
    UserStub.set_photo("contacts")

    ConvStub.set_shares(true)
    assert avatar_url_for(@target) == "https://minio/bob.png"

    ConvStub.set_shares(false)
    assert avatar_url_for(@target) == nil
  end

  test "photo 'nobody' → avatar HIDDEN (indistinguishable from no-avatar), name still shown" do
    UserStub.set_photo("nobody")
    ConvStub.set_shares(true)

    body = Jason.decode!(UserController.profile(authed(), %{"user_id" => @target}).resp_body)
    assert body["display_name"] == "Bob"
    assert body["avatar_url"] == nil
    refute Map.has_key?(body, "avatar_media_id")
  end
end
