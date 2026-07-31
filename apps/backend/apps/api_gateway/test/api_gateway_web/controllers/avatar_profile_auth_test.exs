defmodule ApiGatewayWeb.AvatarProfileAuthTest do
  @moduledoc """
  Closes the unauthenticated cross-tenant read: /users/:id/profile and /users/:id/avatar are session-gated
  + app-scoped; the ONLY public avatar path is /api/v1/push/avatar/:token (HMAC capability token). And
  PATCH /users/me can no longer poison an avatar (avatar_media_id must be the caller's own ready
  user_avatar; avatar_object_key is ignored). All clients stubbed — no DB.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias SharedInfra.AvatarToken

  @app "44444444-4444-4444-8444-444444444444"
  @other_app "99999999-9999-4999-8999-999999999999"
  @caller "caller-1"
  @has_avatar "target-with-avatar"
  @no_avatar "target-no-avatar"
  @cross "target-cross-tenant"
  @avatar_pic "avatar-media-ok"

  # avatar_media_id validation assets (owned/ready/user_avatar → valid; others → rejected)
  @owned "owned-ready-avatar"
  @not_owned "someone-elses-avatar"
  @msg_purpose "a-message-asset"
  @incomplete "not-yet-ready-avatar"

  defmodule AuthStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    @has_avatar "target-with-avatar"
    @no_avatar "target-no-avatar"
    @avatar_pic "avatar-media-ok"

    # App-SCOPED: a profile resolves ONLY for the matching app. Cross-tenant / unknown → :profile_not_found.
    def get_public_profile(%{"user_id" => @has_avatar, "app_id" => @app}),
      do:
        {:ok,
         %{
           user_id: @has_avatar,
           display_name: "Has Avatar",
           app_id: @app,
           avatar_media_id: @avatar_pic
         }}

    # The photo-visibility rule (fail-closed: unknown -> hidden) postdates this suite; without this
    # stub every avatar assertion below fails as HIDDEN before what it tests is even reached.
    def get_privacy(_attrs),
      do: {:ok, %{profile_photo_visibility: "everyone", read_receipts_enabled: true}}

    def get_public_profile(%{"user_id" => @no_avatar, "app_id" => @app}),
      do:
        {:ok,
         %{user_id: @no_avatar, display_name: "No Avatar", app_id: @app, avatar_media_id: nil}}

    def get_public_profile(_), do: {:error, :profile_not_found}

    def get_current_profile(_), do: {:error, :user_unavailable}

    # Echo the stored avatar_media_id back (no app_id → with_avatar_url adds avatar_url: nil, no presign).
    def update_current_profile(attrs),
      do:
        {:ok,
         %{
           user_id: attrs["user_id"],
           display_name: attrs["display_name"],
           avatar_media_id: attrs["avatar_media_id"]
         }}
  end

  defmodule MediaStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    @caller "caller-1"
    @avatar_pic "avatar-media-ok"
    @owned "owned-ready-avatar"
    @not_owned "someone-elses-avatar"
    @msg_purpose "a-message-asset"
    @incomplete "not-yet-ready-avatar"

    # Presign only for the avatar pic, in the right app.
    def get_download_url(%{
          "media_id" => @avatar_pic,
          "app_id" => @app,
          "purpose" => "user_avatar"
        }),
        do: {:ok, %{download_url: "https://minio.local/get/avatar"}}

    def get_download_url(_), do: {:error, :not_found}

    # get_asset backs avatar_media_id validation (owner/purpose/status, scoped to app).
    @assets %{
      @owned => %{owner_user_id: @caller, purpose: "user_avatar", status: "ready"},
      @not_owned => %{owner_user_id: "someone-else", purpose: "user_avatar", status: "ready"},
      @msg_purpose => %{owner_user_id: @caller, purpose: "message", status: "ready"},
      @incomplete => %{owner_user_id: @caller, purpose: "user_avatar", status: "created"}
    }

    def get_asset(%{"media_id" => id, "app_id" => @app}) do
      case Map.get(@assets, id) do
        nil -> {:error, :not_found}
        a -> {:ok, Map.put(a, :media_id, id)}
      end
    end

    def get_asset(_), do: {:error, :not_found}
  end

  setup do
    prev = %{
      persist: Application.get_env(:user_service, :user_profile_persistence, false),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      secret: System.get_env("SECRET_KEY_BASE")
    }

    # DB mode → update_me takes the validating path; a fixed secret so AvatarToken is deterministic.
    Application.put_env(:user_service, :user_profile_persistence, true)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    System.put_env(
      "SECRET_KEY_BASE",
      "test_secret_key_base_deterministic_at_least_sixty_four_chars_long_x"
    )

    on_exit(fn ->
      Application.put_env(:user_service, :user_profile_persistence, prev.persist)
      restore(:auth_client_adapter, prev.auth)
      restore(:user_client_adapter, prev.user)
      restore(:media_client_adapter, prev.media)

      if prev.secret,
        do: System.put_env("SECRET_KEY_BASE", prev.secret),
        else: System.delete_env("SECRET_KEY_BASE")
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # Endpoint.call runs the full pipeline (Plug.Parsers parses the JSON body → params) then the router.
  defp call(conn), do: ApiGatewayWeb.Endpoint.call(conn, [])

  defp authed(method, path, body \\ nil) do
    base = if body, do: conn(method, path, Jason.encode!(body)), else: conn(method, path)

    base
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @caller)
    |> call()
  end

  # --- /users/:id/profile ---------------------------------------------------------------------------

  test "GET /users/:id/profile unauthenticated → 401" do
    conn = call(conn(:get, "/api/v1/users/#{@has_avatar}/profile"))
    assert conn.status == 401
  end

  test "GET /users/:id/profile authenticated, same app → 200" do
    conn = authed(:get, "/api/v1/users/#{@has_avatar}/profile")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["display_name"] == "Has Avatar"
  end

  test "GET /users/:id/profile authenticated, OTHER app → 404 revealing nothing" do
    conn = authed(:get, "/api/v1/users/#{@cross}/profile")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert Map.keys(body) == ["error"]
    refute conn.resp_body =~ "display_name"
    refute conn.resp_body =~ "Has Avatar"
  end

  # --- /users/:id/avatar ----------------------------------------------------------------------------

  test "GET /users/:id/avatar unauthenticated → 401" do
    conn = call(conn(:get, "/api/v1/users/#{@has_avatar}/avatar"))
    assert conn.status == 401
  end

  test "GET /users/:id/avatar authenticated, same app → 302" do
    conn = authed(:get, "/api/v1/users/#{@has_avatar}/avatar")
    assert conn.status == 302
  end

  test "GET /users/:id/avatar authenticated, OTHER app → 404" do
    conn = authed(:get, "/api/v1/users/#{@cross}/avatar")
    assert conn.status == 404
  end

  # --- /api/v1/push/avatar/:token -------------------------------------------------------------------

  defp push(token), do: call(conn(:get, "/api/v1/push/avatar/#{token}"))

  test "push avatar: a valid token → 302" do
    assert push(AvatarToken.sign(@has_avatar, @app)).status == 302
  end

  test "push avatar: an expired token → 404" do
    eight_days = System.os_time(:second) - 8 * 24 * 60 * 60

    expired =
      Plug.Crypto.sign(
        System.get_env("SECRET_KEY_BASE"),
        "avatar-icon-capability-v1",
        %{"u" => @has_avatar, "a" => @app, "k" => "avatar"},
        signed_at: eight_days
      )

    assert push(expired).status == 404
  end

  test "push avatar: a token minted under app X, used against a user in app Y → 404" do
    # Token bound to the WRONG app → the presign scopes to that app → the avatar asset isn't there → 404.
    assert push(AvatarToken.sign(@has_avatar, @other_app)).status == 404
  end

  test "push avatar: a token for a user with no avatar → 404" do
    assert push(AvatarToken.sign(@no_avatar, @app)).status == 404
  end

  test "push avatar: a tampered signature → 404" do
    token = AvatarToken.sign(@has_avatar, @app)
    tampered = String.slice(token, 0..-2//1) <> if String.last(token) == "x", do: "y", else: "x"
    assert push(tampered).status == 404
  end

  test "push avatar: a token with kind != avatar → 404" do
    wrong =
      Plug.Crypto.sign(System.get_env("SECRET_KEY_BASE"), "avatar-icon-capability-v1", %{
        "u" => @has_avatar,
        "a" => @app,
        "k" => "message"
      })

    assert push(wrong).status == 404
  end

  # --- PATCH /users/me avatar validation ------------------------------------------------------------

  defp patch_me(body), do: authed(:patch, "/api/v1/users/me", body)

  test "PATCH /me with the caller's own ready user_avatar → 200" do
    conn = patch_me(%{"avatar_media_id" => @owned})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["avatar_media_id"] == @owned
  end

  test "PATCH /me with an avatar_media_id the caller does NOT own → 422, profile unchanged" do
    assert patch_me(%{"avatar_media_id" => @not_owned}).status == 422
  end

  test "PATCH /me with a purpose=message asset → 422" do
    assert patch_me(%{"avatar_media_id" => @msg_purpose}).status == 422
  end

  test "PATCH /me with a status=created (incomplete) asset → 422" do
    assert patch_me(%{"avatar_media_id" => @incomplete}).status == 422
  end

  test "PATCH /me with avatar_object_key in the body → IGNORED (not persisted), request succeeds" do
    conn =
      patch_me(%{"display_name" => "New Name", "avatar_object_key" => "media/attacker/steal.png"})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["display_name"] == "New Name"
  end

  test "PATCH /me with avatar_media_id = null → avatar removed (200)" do
    assert patch_me(%{"avatar_media_id" => nil}).status == 200
  end
end
