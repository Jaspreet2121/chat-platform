defmodule ApiGatewayWeb.UserAvatarUrlTest.UserWithAvatarStub do
  @moduledoc false
  @behaviour SharedInfra.UserClient

  # The profile carries app_id (surfaced from user_profiles.app_id) — the gateway presigns scoped to it
  # (the /avatar route is unauthenticated → no caller app_id). object_key is no longer consulted.
  @impl true
  def get_public_profile(attrs) do
    {:ok,
     %{
       user_id: attrs["user_id"],
       display_name: "Pic User",
       avatar_media_id: "11111111-1111-4111-8111-111111111111",
       avatar_object_key: "media/owner-1/11111111-1111-4111-8111-111111111111/avatar.png",
       app_id: "44444444-4444-4444-8444-444444444444",
       bio: "has an avatar"
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

  # New shape: (media_id, app_id, purpose "user_avatar"). Resolves → a signed URL.
  @impl true
  def get_download_url(%{"app_id" => _app, "purpose" => "user_avatar"}),
    do: {:ok, %{media_id: "m", download_url: @signed_url}}

  def get_download_url(_), do: {:error, :not_found}

  @impl true
  def get_asset(_attrs), do: {:error, :not_used}

  @impl true
  def create_upload(_attrs), do: {:error, :media_unavailable}

  @impl true
  def complete_upload(_attrs), do: {:error, :media_unavailable}
end

defmodule ApiGatewayWeb.UserAvatarUrlTest.NotFoundMediaStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient

  # Models an unresolvable / cross-tenant / wrong-purpose asset → no avatar (fail-open).
  @impl true
  def get_download_url(_attrs), do: {:error, :not_found}
  @impl true
  def get_asset(_attrs), do: {:error, :not_found}
  @impl true
  def create_upload(_attrs), do: {:error, :media_unavailable}
  @impl true
  def complete_upload(_attrs), do: {:error, :media_unavailable}
end

defmodule ApiGatewayWeb.UserAvatarUrlTest do
  @moduledoc """
  Docker-free: the gateway enriches profile responses with a signed `avatar_url`, resolved from the stored
  `avatar_media_id` scoped to the PROFILE's app_id (object_key is resolved server-side from the row). A
  cross-user read works (GET /:id/profile presigns another user's avatar). When the asset can't be resolved
  (unknown / cross-tenant / wrong purpose), no avatar_url is added. The tenant app_id never leaks.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserAvatarUrlTest.MediaStub
  alias ApiGatewayWeb.UserAvatarUrlTest.NotFoundMediaStub
  alias ApiGatewayWeb.UserAvatarUrlTest.UserWithAvatarStub

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :user_client_adapter, UserWithAvatarStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      restore(:user_client_adapter, prev_user)
      restore(:media_client_adapter, prev_media)
    end)

    :ok
  end

  test "GET /:id/profile returns a signed avatar_url; the tenant app_id is NOT leaked" do
    body = get_profile("user-with-avatar")

    assert body["avatar_url"] == MediaStub.signed_url()
    assert body["avatar_media_id"] == "11111111-1111-4111-8111-111111111111"
    assert body["display_name"] == "Pic User"
    refute Map.has_key?(body, "app_id")
  end

  test "GET /:id/profile → avatar_url nil when the asset can't be resolved (unknown / cross-tenant / wrong purpose)" do
    Application.put_env(:shared_infra, :media_client_adapter, NotFoundMediaStub)

    body = get_profile("user-with-avatar")

    assert body["avatar_url"] == nil
    refute Map.has_key?(body, "app_id")
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
