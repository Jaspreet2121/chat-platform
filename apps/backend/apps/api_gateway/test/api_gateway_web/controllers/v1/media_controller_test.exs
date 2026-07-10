defmodule ApiGatewayWeb.V1.MediaControllerTest do
  @moduledoc """
  /v1 media upload / complete / download + media_id on message send, for BOTH V1Auth actors. Stubs the
  media / conversation / auth / message clients and calls the controller actions directly with the assigns
  V1Auth would leave (:v1_app_id, :v1_actor, :v1_user_id). Asserts the actor rules: end-user needs
  membership/ownership (failures → 404, never 403, never object_key); app is tenant-scoped.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.MediaController
  alias ApiGatewayWeb.V1.MessageController

  @app "44444444-4444-4444-8444-444444444444"
  @app2 "55555555-5555-4555-8555-555555555555"
  @user "22222222-2222-4222-8222-222222222222"
  @outsider "33333333-3333-4333-8333-333333333333"
  @owner_user "66666666-6666-4666-8666-666666666666"
  @conv "11111111-1111-4111-8111-111111111111"
  @conv_b "77777777-7777-4777-8777-777777777777"

  @ready_msg "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @created_msg "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @avatar "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @others "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

  # ---- stubs (no @behaviour → no unimplemented-callback warnings; adapter dispatch is runtime) ----

  defmodule MediaStub do
    @moduledoc false
    def object_key_sentinel, do: "SECRET/should-not-leak.png"

    def create_upload(_attrs) do
      {:ok,
       %{
         media_id: "new-media-id",
         # The service still returns object_key (legacy); /v1 MUST strip it.
         object_key: object_key_sentinel(),
         upload_url: "https://minio.local/put?sig=1",
         expires_at: "2026-07-10T00:00:00Z"
       }}
    end

    def get_asset(%{"media_id" => id, "app_id" => app}) do
      case assets()[{id, app}] do
        nil -> {:error, :not_found}
        asset -> {:ok, asset}
      end
    end

    # Mirrors the service: owner must match the row (cross-tenant/unknown/foreign-owner → not_found).
    def complete_upload(%{"media_id" => id, "app_id" => app, "owner_user_id" => owner}) do
      case assets()[{id, app}] do
        %{owner_user_id: ^owner} -> {:ok, %{media_id: id, status: "ready"}}
        _ -> {:error, :not_found}
      end
    end

    def get_download_url(%{"media_id" => id}) do
      {:ok,
       %{
         media_id: id,
         download_url: "https://minio.local/get/" <> id,
         expires_at: "2026-07-10T00:00:00Z",
         mime_type: "image/png"
       }}
    end

    defp assets, do: Application.get_env(:api_gateway, :test_assets, %{})
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation_app(%{"conversation_id" => c, "app_id" => a}) do
      if Application.get_env(:api_gateway, :test_conv_app, %{})[c] == a,
        do: {:ok, %{}},
        else: {:error, :not_found}
    end

    def get_conversation(%{"conversation_id" => c, "user_id" => u}) do
      members = Application.get_env(:api_gateway, :test_members, %{})[c] || []

      if u in members do
        app = Application.get_env(:api_gateway, :test_conv_app, %{})[c]
        {:ok, %{app_id: app, participants: Enum.map(members, &%{user_id: &1})}}
      else
        {:error, :not_found}
      end
    end
  end

  defmodule AuthStub do
    @moduledoc false
    def resolve_external_user(%{"app_id" => app, "external_id" => ext}) do
      case Application.get_env(:api_gateway, :test_ext_users, %{})[{app, ext}] do
        nil -> {:error, :not_found}
        user_id -> {:ok, %{user_id: user_id}}
      end
    end
  end

  defmodule MsgStub do
    @moduledoc false
    # get_by_media_id: which conversation an asset was sent to (nil → unattached → owner-only download).
    def get_by_media_id(%{"media_id" => id}) do
      case Application.get_env(:api_gateway, :test_media_conv, %{})[id] do
        nil -> {:error, :not_found}
        conv -> {:ok, %{conversation_id: conv}}
      end
    end

    # Echo the attrs back so the test can assert the media_id/message_type the controller threaded.
    def create_message(attrs) do
      {:ok,
       %{
         "message_id" => "msg-1",
         "conversation_id" => attrs["conversation_id"],
         "sender_user_id" => attrs["sender_user_id"],
         "message_type" => attrs["message_type"],
         "media_id" => attrs["media_id"],
         "body" => attrs["body"],
         "status" => "active"
       }}
    end
  end

  setup do
    prev = %{
      media: Application.get_env(:shared_infra, :media_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      backend: System.get_env("V1_RUNTIME_BACKEND")
    }

    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    System.put_env("V1_RUNTIME_BACKEND", "ets")

    # Tenant + membership fixtures.
    Application.put_env(:api_gateway, :test_conv_app, %{@conv => @app, @conv_b => @app2})
    Application.put_env(:api_gateway, :test_members, %{@conv => [@user, @owner_user]})
    Application.put_env(:api_gateway, :test_ext_users, %{{@app, "ext-owner"} => @owner_user})

    # Asset registry, keyed by {media_id, app_id} so a cross-tenant lookup misses.
    Application.put_env(:api_gateway, :test_assets, %{
      {@ready_msg, @app} => asset(@ready_msg, "message", @user, @conv, "ready"),
      {@created_msg, @app} => asset(@created_msg, "message", @user, @conv, "created"),
      {@avatar, @app} => asset(@avatar, "user_avatar", @user, nil, "ready"),
      {@others, @app} => asset(@others, "message", @outsider, @conv, "ready")
    })

    # Which conversation each message-asset was sent to (for download authz).
    Application.put_env(:api_gateway, :test_media_conv, %{@ready_msg => @conv, @others => @conv})

    on_exit(fn ->
      restore(:media_client_adapter, prev.media)
      restore(:conversation_client_adapter, prev.conv)
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
      if prev.backend, do: System.put_env("V1_RUNTIME_BACKEND", prev.backend), else: System.delete_env("V1_RUNTIME_BACKEND")

      for k <- [:test_assets, :test_conv_app, :test_members, :test_ext_users, :test_media_conv],
          do: Application.delete_env(:api_gateway, k)
    end)

    :ok
  end

  # ================================ create_upload ================================

  test "end-user participant → 201 with upload fields and NO object_key" do
    conn = MediaController.create_upload(user_conn(@user), %{"purpose" => "message", "conversation_id" => @conv})
    body = json(conn)

    assert conn.status == 201
    assert body["media_id"] == "new-media-id"
    assert body["upload_url"] == "https://minio.local/put?sig=1"
    assert body["status"] == "created"
    refute Map.has_key?(body, "object_key")
    refute body["upload_url"] =~ MediaStub.object_key_sentinel()
  end

  test "end-user NON-participant upload → 404 (no reveal, not 403)" do
    conn = MediaController.create_upload(user_conn(@outsider), %{"purpose" => "message", "conversation_id" => @conv})
    assert conn.status == 404
    refute conn.status == 403
    assert json(conn)["error"]["code"] == "v1.not_found"
  end

  test "app actor upload to a tenant conversation → 201" do
    conn = MediaController.create_upload(app_conn(), %{"purpose" => "message", "conversation_id" => @conv, "owner" => "ext-owner"})
    assert conn.status == 201
    assert json(conn)["media_id"] == "new-media-id"
  end

  test "app actor upload to a CROSS-TENANT conversation → 404" do
    conn = MediaController.create_upload(app_conn(), %{"purpose" => "message", "conversation_id" => @conv_b, "owner" => "ext-owner"})
    assert conn.status == 404
  end

  test "app actor naming an owner that doesn't resolve in the app → 400" do
    conn = MediaController.create_upload(app_conn(), %{"purpose" => "message", "conversation_id" => @conv, "owner" => "ghost"})
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "v1.invalid_request"
  end

  test "user_avatar upload needs no conversation → 201" do
    conn = MediaController.create_upload(user_conn(@user), %{"purpose" => "user_avatar"})
    assert conn.status == 201
  end

  # ================================ complete_upload ================================

  test "end-user completing their own upload → 200 ready" do
    conn = MediaController.complete_upload(user_conn(@user), %{"media_id" => @ready_msg})
    assert conn.status == 200
    assert json(conn) == %{"media_id" => @ready_msg, "status" => "ready"}
  end

  test "end-user completing ANOTHER user's media_id → 404 (status unchanged)" do
    conn = MediaController.complete_upload(user_conn(@user), %{"media_id" => @others})
    assert conn.status == 404
  end

  test "end-user completing a CROSS-TENANT media_id → 404" do
    conn = MediaController.complete_upload(user_conn2(@user), %{"media_id" => @ready_msg})
    assert conn.status == 404
  end

  test "app actor completing a tenant upload → 200 (owner resolved from the row)" do
    conn = MediaController.complete_upload(app_conn(), %{"media_id" => @others})
    assert conn.status == 200
    assert json(conn)["status"] == "ready"
  end

  # ================================ download ================================

  test "end-user participant download of a message asset → 200 with mime_type, NO object_key" do
    conn = MediaController.download(user_conn(@user), %{"media_id" => @ready_msg})
    body = json(conn)

    assert conn.status == 200
    assert body["media_id"] == @ready_msg
    assert body["download_url"] == "https://minio.local/get/" <> @ready_msg
    assert body["mime_type"] == "image/png"
    refute Map.has_key?(body, "object_key")
  end

  test "end-user NON-participant download → 404" do
    conn = MediaController.download(user_conn(@outsider), %{"media_id" => @ready_msg})
    assert conn.status == 404
  end

  test "end-user cross-tenant download → 404" do
    conn = MediaController.download(user_conn2(@user), %{"media_id" => @ready_msg})
    assert conn.status == 404
  end

  test "app actor download is tenant-scoped → 200" do
    conn = MediaController.download(app_conn(), %{"media_id" => @ready_msg})
    assert conn.status == 200
  end

  test "a client-supplied object_key param is IGNORED (URL signs the row's key)" do
    conn = MediaController.download(user_conn(@user), %{"media_id" => @ready_msg, "object_key" => "attacker/key"})
    body = json(conn)

    assert conn.status == 200
    # The signed URL is derived from media_id (the row), never the client's object_key.
    assert body["download_url"] == "https://minio.local/get/" <> @ready_msg
    refute body["download_url"] =~ "attacker"
  end

  # ================================ message send w/ media_id ================================

  test "message send with a valid own ready message asset → 201, media_id on the message" do
    conn = MessageController.create(user_conn(@user), %{"id" => @conv, "media_id" => @ready_msg, "body" => "caption"})
    body = json(conn)

    assert conn.status == 201
    assert body["media_id"] == @ready_msg
    assert body["message_type"] == "media"
  end

  test "message send with a media_id the caller does NOT own → 422, no message" do
    conn = MessageController.create(user_conn(@user), %{"id" => @conv, "media_id" => @others})
    assert conn.status == 422
    assert json(conn)["error"]["code"] == "v1.invalid_media"
  end

  test "message send with a user_avatar asset → 422 (wrong purpose)" do
    conn = MessageController.create(user_conn(@user), %{"id" => @conv, "media_id" => @avatar})
    assert conn.status == 422
  end

  test "message send with an incomplete (status=created) asset → 422" do
    conn = MessageController.create(user_conn(@user), %{"id" => @conv, "media_id" => @created_msg})
    assert conn.status == 422
  end

  # ---- helpers ----

  defp asset(id, purpose, owner, conv, status),
    do: %{media_id: id, purpose: purpose, owner_user_id: owner, conversation_id: conv, status: status}

  defp base_conn, do: conn(:post, "/v1/media", %{})

  defp app_conn, do: base_conn() |> assign(:v1_app_id, @app) |> assign(:v1_actor, :app)

  defp user_conn(user_id),
    do: base_conn() |> assign(:v1_app_id, @app) |> assign(:v1_actor, :end_user) |> assign(:v1_user_id, user_id)

  # Same user, but the credential is scoped to a DIFFERENT app (cross-tenant probe).
  defp user_conn2(user_id),
    do: base_conn() |> assign(:v1_app_id, @app2) |> assign(:v1_actor, :end_user) |> assign(:v1_user_id, user_id)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)
end
