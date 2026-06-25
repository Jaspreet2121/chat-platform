defmodule ApiGatewayWeb.UserAvatarUrlTest.UserWithAvatarStub do
  @moduledoc false
  @behaviour SharedInfra.UserClient

  @impl true
  def get_public_profile(attrs) do
    {:ok,
     %{
       user_id: attrs["user_id"],
       display_name: "Pic User",
       avatar_media_id: "11111111-1111-4111-8111-111111111111",
       avatar_object_key: "media/owner-1/11111111-1111-4111-8111-111111111111/avatar.png",
       bio: "has an avatar"
     }}
  end

  @impl true
  def get_current_profile(_attrs), do: {:error, :user_unavailable}

  @impl true
  def update_current_profile(_attrs), do: {:error, :user_unavailable}
end

defmodule ApiGatewayWeb.UserAvatarUrlTest.UserNoKeyStub do
  @moduledoc false
  @behaviour SharedInfra.UserClient

  # Avatar set (media_id) but the object_key wasn't persisted → not resolvable, so no avatar_url.
  @impl true
  def get_public_profile(attrs) do
    {:ok,
     %{
       user_id: attrs["user_id"],
       display_name: "No Key User",
       avatar_media_id: "22222222-2222-4222-8222-222222222222",
       avatar_object_key: nil,
       bio: nil
     }}
  end

  @impl true
  def get_current_profile(_attrs), do: {:error, :user_unavailable}

  @impl true
  def update_current_profile(_attrs), do: {:error, :user_unavailable}
end

defmodule ApiGatewayWeb.UserAvatarUrlTest.MediaStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient

  @signed_url "https://minio.local/avatar.png?signed=yes"
  def signed_url, do: @signed_url

  @impl true
  def get_download_url(_attrs), do: {:ok, %{media_id: "m", download_url: @signed_url}}

  @impl true
  def create_upload(_attrs), do: {:error, :media_unavailable}

  @impl true
  def complete_upload(_attrs), do: {:error, :media_unavailable}
end

defmodule ApiGatewayWeb.UserAvatarUrlTest do
  @moduledoc """
  Docker-free: the gateway enriches profile responses with a signed `avatar_url`, resolved from the
  stored `avatar_media_id` + `avatar_object_key` via the media client. Cross-user read works (GET
  /:id/profile presigns another user's avatar). When the object_key is absent, no avatar_url is added.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserAvatarUrlTest.MediaStub
  alias ApiGatewayWeb.UserAvatarUrlTest.UserNoKeyStub
  alias ApiGatewayWeb.UserAvatarUrlTest.UserWithAvatarStub

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      restore(:user_client_adapter, prev_user)
      restore(:media_client_adapter, prev_media)
    end)

    :ok
  end

  test "GET /:id/profile returns a signed avatar_url resolved from the stored object_key" do
    Application.put_env(:shared_infra, :user_client_adapter, UserWithAvatarStub)

    body = get_profile("user-with-avatar")

    assert body["avatar_url"] == MediaStub.signed_url()
    assert body["avatar_media_id"] == "11111111-1111-4111-8111-111111111111"
    assert body["display_name"] == "Pic User"
  end

  test "GET /:id/profile omits avatar_url when no object_key is stored" do
    Application.put_env(:shared_infra, :user_client_adapter, UserNoKeyStub)

    body = get_profile("user-no-key")

    refute Map.has_key?(body, "avatar_url")
    assert body["avatar_media_id"] == "22222222-2222-4222-8222-222222222222"
  end

  defp get_profile(user_id) do
    conn(:get, "/api/v1/users/#{user_id}/profile")
    |> put_req_header("accept", "application/json")
    |> ApiGatewayWeb.Router.call(@opts)
    |> then(fn conn ->
      assert conn.status == 200
      Jason.decode!(conn.resp_body)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)
end
